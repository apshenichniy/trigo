#!/usr/bin/env python3
"""Read-only selected-call capture evidence for an explicitly admitted local Dev namespace."""
import argparse
import hashlib
import json
import math
import re
import os
from pathlib import Path
import sqlite3
import stat
import struct
import sys
import time
import uuid
from datetime import datetime, timezone

PROFILE = "caf-lpcm-s16le-16000-stereo-v1"
HEADER = (b"caff" + struct.pack(">HH", 1, 0) + b"desc" + struct.pack(">qd", 32, 16000)
          + b"lpcm" + struct.pack(">IIIII", 2, 4, 1, 2, 16) + b"data"
          + struct.pack(">qI", -1, 0))
STATES = {"recorded": 1, "muted": 2, "unavailable": 3}
TONE = [(math.cos(2 * math.pi * 440 * frame / 16000), math.sin(2 * math.pi * 440 * frame / 16000)) for frame in range(400)]


def need(condition, message):
    if not condition:
        raise ValueError(message)


def utc():
    return datetime.now(timezone.utc).isoformat()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(root, relative, exists=True):
    path = root / relative
    need(path.is_relative_to(root), "path outside admitted namespace")
    for part in [path, *path.parents]:
        if part == root.parent:
            break
        need(not part.is_symlink(), "symlink in admitted path")
    if exists:
        need(path.exists(), "required admitted path is missing")
    return path


def open_read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(descriptor)
        raise ValueError("expected one regular unlinked input file")
    return os.fdopen(descriptor, "rb")


def bounded_json(path, maximum=65536):
    with open_read(path) as handle:
        data = handle.read(maximum + 1)
    need(len(data) <= maximum, "JSON input exceeds observation bound")
    return json.loads(data)


def rows(db, sql, arguments=(), maximum=100000):
    result = [dict(row) for row in db.execute(sql, arguments).fetchmany(maximum + 1)]
    need(len(result) <= maximum, "short synthetic SQL observation bound exceeded")
    return result


def controlled_selection(value):
    need(isinstance(value, list) and 1 <= len(value) <= 20,
         "controlledCalls must be an explicit nonempty allowlist of at most 20 calls")
    selected = {}
    for item in value:
        need(isinstance(item, dict) and set(item) == {"callId", "expectedApplicationProcessId"},
             "each controlled call requires exactly callId and expectedApplicationProcessId")
        call_id, pid = item["callId"], item["expectedApplicationProcessId"]
        need(isinstance(call_id, str) and str(uuid.UUID(call_id)) == call_id,
             "controlled call ID is not canonical")
        need(type(pid) is int and 1 <= pid <= 2147483647, "expected application PID must be a positive signed 32-bit integer")
        need(call_id not in selected, "duplicate controlled call selection")
        selected[call_id] = pid
    return selected


def selection_records(selected):
    return [{"callId": call_id, "expectedApplicationProcessId": selected[call_id]} for call_id in sorted(selected)]


def metadata(root, archive_id, selected):
    archive = safe_path(root, "Archive")
    database = safe_path(root, "Archive/archive.sqlite3")
    for suffix in ("", "-wal", "-shm", "-journal"):
        path = safe_path(root, "Archive/archive.sqlite3" + suffix, exists=False)
        if path.exists():
            with open_read(path):
                pass
    started = time.monotonic()
    db = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2)
    db.row_factory = sqlite3.Row
    try:
        db.execute("PRAGMA query_only=ON")
        db.execute("BEGIN")
        need(db.execute("PRAGMA user_version").fetchone()[0] in (2, 3, 4), "unsupported repository schema")
        identity = rows(db, "SELECT archive_id,root FROM repository_identity", maximum=1)
        need(len(identity) == 1 and identity[0]["archive_id"] == archive_id
             and identity[0]["root"] == str(archive), "archive identity/root mismatch")
        # Query only admitted IDs; unrelated call metadata is never collected.
        placeholders = ",".join("?" for _ in selected)
        calls = rows(db, """SELECT v.hash,v.call_id,v.version,v.started_at,v.ended_at,
            v.duration_ms,v.capture_state,v.reason,v.application_name,v.bundle_id,
            v.process_id,v.window_id,v.audio_id,v.audio_hash
            FROM calls c JOIN call_values v ON v.hash=c.hash WHERE c.call_id IN (""" + placeholders + ") ORDER BY v.started_at,v.call_id",
                     tuple(selected), maximum=20)
        need(len(calls) == len(selected) and {call["call_id"] for call in calls} == set(selected), "selected call identity is missing from the admitted archive")
        for call in calls:
            need(call["process_id"] == selected[call["call_id"]], "selected application PID does not match recorded source")
            call["expectedApplicationProcessId"] = selected[call["call_id"]]
        document_budget = 32 * 1024 * 1024
        for call in calls:
            call_id = call["call_id"]
            need(str(uuid.UUID(call_id)) == call_id, "noncanonical call ID")
            session = rows(db, "SELECT * FROM sessions WHERE call_id=?", (call_id,), 1)
            need(len(session) == 1, "expected one admitted capture session")
            call["session"] = session[0]
            progress = rows(db, "SELECT * FROM capture_progress WHERE call_id=?", (call_id,), 1)
            call["progress"] = progress[0] if progress else None
            sequence = (call["progress"] or {}).get("sequence") or 0
            call["commits"] = rows(db, "SELECT * FROM media_commits WHERE call_id=? AND sequence<=? ORDER BY sequence", (call_id, sequence), 600)
            call["media_intervals"] = rows(db, "SELECT * FROM media_intervals WHERE call_id=? AND sequence<=? ORDER BY sequence,channel,ordinal", (call_id, sequence))
            call["tracks"] = rows(db, "SELECT ordinal,track_id,role,device_id,device_name,profile FROM call_tracks WHERE hash=? ORDER BY ordinal", (call["hash"],), 2)
            call["track_intervals"] = rows(db, "SELECT track_ordinal,ordinal,start_ms,end_ms,state,reason FROM track_intervals WHERE hash=? ORDER BY track_ordinal,ordinal", (call["hash"],))
            call["lifecycle"] = rows(db, "SELECT * FROM lifecycle WHERE call_id=?", (call_id,), 1)
            call["operations"] = rows(db, "SELECT operation_id,kind,phase,attempt,failure,retry,acknowledged FROM operations WHERE call_id=? ORDER BY operation_id", (call_id,), 100)
            call["history"] = rows(db, "SELECT version,hash FROM snapshot_history WHERE call_id=? ORDER BY version", (call_id,), 20)
            call["documents"] = []
            for digest in {h["hash"] for h in call["history"]} | ({call["audio_hash"]} if call["audio_hash"] else set()):
                document = rows(db, "SELECT byte_count,complete FROM documents WHERE hash=?", (digest,), 1)
                need(len(document) == 1 and document[0]["complete"] == 1
                     and document[0]["byte_count"] <= 8 * 1024 * 1024, "invalid or oversized short-fixture document")
                document_budget -= document[0]["byte_count"]
                need(document_budget >= 0, "aggregate document observation bound exceeded")
                chunk_sizes = rows(db, "SELECT part,length(bytes) AS byte_count FROM document_chunks WHERE hash=? ORDER BY part", (digest,), 33)
                need(all(0 <= c["byte_count"] <= 262144 for c in chunk_sizes), "document chunk exceeds observation bound")
                chunks = rows(db, "SELECT part,bytes FROM document_chunks WHERE hash=? ORDER BY part", (digest,), 33)
                need([c["part"] for c in chunks] == list(range(len(chunks))), "nonconsecutive document parts")
                call["documents"].append({"hash": digest, "byteCount": document[0]["byte_count"], "raw": b"".join(c["bytes"] for c in chunks)})
        db.execute("COMMIT")
    finally:
        db.close()
    return calls, round((time.monotonic() - started) * 1000, 3)


def state_bytes(spans, start_ms, end_ms, channel):
    data = bytearray()
    cursor = start_ms
    for span in spans:
        need(span["start_ms"] == cursor and cursor < span["end_ms"] <= end_ms, "source intervals do not cover their committed range")
        value = STATES[span["state"]]
        need(channel == 0 or value != 2, "application channel cannot be muted")
        data.extend([value] * (span["end_ms"] - cursor))
        cursor = span["end_ms"]
    need(cursor == end_ms, "source intervals end before their committed range")
    return data


def stream_hash(handle, byte_count):
    need(type(byte_count) is int and 68 <= byte_count <= 68 + 4 * 16000 * 600,
         "previous confirmed byte count is outside the observation bound")
    digest = hashlib.sha256()
    remaining = byte_count
    while remaining:
        chunk = handle.read(min(262144, remaining))
        need(chunk, "media shorter than observed confirmed prefix")
        digest.update(chunk)
        remaining -= len(chunk)
    return digest.hexdigest()


def inspect_call(root, call, previous, cursor_only=False):
    session = call["session"]
    commits = call.pop("commits")
    intervals = call.pop("media_intervals")
    projection = call.pop("track_intervals")
    documents = call.pop("documents")
    audio_document = None
    for document in documents:
        raw = document.pop("raw")
        need(len(raw) == document["byteCount"] and sha(raw) == document["hash"], "retained document hash/length mismatch")
        if document["hash"] == call["audio_hash"]:
            audio_document = json.loads(raw)
    call["documents"] = sorted(documents, key=lambda d: d["hash"])
    progress = call["progress"]
    if progress is None:
        need(not previous or "media" not in previous, "previous confirmed media progress disappeared")
        call["mediaObservation"] = "No repository-confirmed cursor; no media bytes treated as verified."
        need(not commits, "commits without progress")
        return call
    frames = commits[-1]["frames"] if commits else 0
    stable_bytes = 68 + 4 * frames
    sequence = progress["sequence"] or 0
    need(sequence == len(commits), "nonconsecutive committed sequence")
    need(frames <= 16000 * 600, "collector only admits calls up to ten minutes")
    identity = [session["master_id"], call["call_id"], session["microphone_track_id"], session["application_track_id"]]
    expected_index = b"TRGIDX01" + b"".join(uuid.UUID(value).bytes for value in identity) + bytes(24)
    expected_index += hashlib.sha256(expected_index).digest()
    directory = safe_path(root, Path("Archive") / call["call_id"] / "media")
    files = sorted(path.name for path in directory.iterdir())
    need(files == ["master.caf", "master.index"], "expected one master and its index only")
    all_states = [bytearray(), bytearray()]
    bins = []
    application_during_mute = {"frames": 0, "nonzeroSamples": 0}
    by_state = [{name: {"frames": 0, "nonzeroSamples": 0, "peak": 0} for name in STATES} for _ in range(2)]
    index_path = safe_path(root, directory.relative_to(root) / "master.index")
    media_path = safe_path(root, directory.relative_to(root) / "master.caf")
    with open_read(index_path) as index, open_read(media_path) as media:
        media_initial = os.fstat(media.fileno())
        index_initial = os.fstat(index.fileno())
        need(index.read(128) == expected_index, "master index identity/header mismatch")
        need(media.read(68) == HEADER, "CAF immutable header/profile mismatch")
        chain = expected_index[-32:]
        digest = hashlib.sha256(HEADER)
        prior_frames = 0
        for number, commit in enumerate(commits, 1):
            end = commit["frames"]
            need(commit["sequence"] == number and commit["start_frame"] == prior_frames
                 and 0 < end - prior_frames <= 16000 and end % 16 == 0
                 and commit["stable_bytes"] == 68 + end * 4, "invalid SQL media cursor")
            count_ms = (end - prior_frames) // 16
            states = [state_bytes([s for s in intervals if s["sequence"] == number and s["channel"] == channel], prior_frames // 16, end // 16, channel) for channel in range(2)]
            for channel in range(2):
                all_states[channel].extend(states[channel])
            encoded_states = bytes(value for pair in zip(*states) for value in pair)
            expected_record = b"AUDIO001" + struct.pack(">qq", end, commit["stable_bytes"]) + bytes.fromhex(commit["pcm_hash"]) + chain + encoded_states + bytes(2000 - count_ms * 2)
            chain = hashlib.sha256(expected_record).digest()
            expected_record += chain
            need(chain.hex() == commit["integrity_hash"] and index.read(2120) == expected_record, "SQL/index integrity or source-state mismatch")
            pcm = media.read((end - prior_frames) * 4)
            need(len(pcm) == (end - prior_frames) * 4 and sha(pcm) == commit["pcm_hash"], "committed PCM hash/length mismatch")
            digest.update(pcm)
            # Energy is descriptive. Physical microphone provenance requires independent evidence.
            for frame_offset, samples in (() if cursor_only else enumerate(struct.iter_unpack("<hh", pcm))):
                if states[0][frame_offset // 16] == 2 and states[1][frame_offset // 16] == 1:
                    application_during_mute["frames"] += 1
                    application_during_mute["nonzeroSamples"] += samples[1] != 0
                absolute_frame = prior_frames + frame_offset
                bin_number = absolute_frame // 16000
                while len(bins) <= bin_number:
                    bins.append({"startMs": len(bins) * 1000, "channels": [{"frames": 0, "sumSquares": 0, "peak": 0, "nonzeroSamples": 0, "toneReal": 0, "toneImaginary": 0} for _ in range(2)]})
                for channel, sample in enumerate(samples):
                    state = states[channel][frame_offset // 16]
                    need(state == 1 or sample == 0, "nonzero suppressed/unavailable source sample")
                    state_name = next(name for name, code in STATES.items() if code == state)
                    summary = by_state[channel][state_name]
                    summary["frames"] += 1
                    summary["nonzeroSamples"] += sample != 0
                    summary["peak"] = max(summary["peak"], abs(sample))
                    bucket = bins[bin_number]["channels"][channel]
                    bucket["frames"] += 1
                    bucket["sumSquares"] += sample * sample
                    bucket["peak"] = max(bucket["peak"], abs(sample))
                    bucket["nonzeroSamples"] += sample != 0
                    cosine, sine = TONE[absolute_frame % 400]
                    bucket["toneReal"] += sample * cosine
                    bucket["toneImaginary"] += sample * sine
            prior_frames = end
        whole_hash = digest.hexdigest()
        if progress["finalized_hash"]:
            need(whole_hash == progress["finalized_hash"], "finalized whole-master hash mismatch")
            expected_final = b"FINAL001" + struct.pack(">qq", frames, stable_bytes) + bytes.fromhex(whole_hash) + chain + bytes(2000)
            expected_final += hashlib.sha256(expected_final).digest()
            need(index.read(2120) == expected_final, "final index record mismatch")
            need(media_initial.st_size == stable_bytes and index_initial.st_size == 128 + (sequence + 1) * 2120, "final files retain unexpected tail")
        if previous:
            previous_media = previous.get("media")
            if previous_media:
                need(stable_bytes >= previous_media["confirmedBytes"], "confirmed prefix regressed")
                media.seek(0)
                need(stream_hash(media, previous_media["confirmedBytes"]) == previous_media["confirmedPrefixSHA256"], "previous confirmed prefix bytes changed")
                call["previousPrefix"] = {"preserved": True, "bytes": previous_media["confirmedBytes"], "frames": previous_media["confirmedFrames"], "additionalConfirmedFrames": frames - previous_media["confirmedFrames"]}
        media_after = os.fstat(media.fileno())
        need((media_initial.st_dev, media_initial.st_ino) == (media_after.st_dev, media_after.st_ino), "media inode changed during read")
    finalized = progress["finalized_hash"] is not None
    if finalized:
        need(call["capture_state"] in ("stopped", "interrupted") and call["duration_ms"] == frames // 16, "final capture metadata mismatch")
        need(len(call["tracks"]) == 2, "missing stereo source tracks")
        for channel, (track_id, role) in enumerate(zip(identity[2:], ("microphone", "application"))):
            track = call["tracks"][channel]
            need(track["track_id"] == track_id and track["role"] == role and track["profile"] == PROFILE, "final source track identity/profile mismatch")
            states = state_bytes([span for span in projection if span["track_ordinal"] == channel], 0, frames // 16, channel)
            need(states == all_states[channel], "final track projection disagrees with committed states")
        need(audio_document is not None and audio_document["callId"] == call["call_id"]
             and audio_document["manifestId"] == session["audio_manifest_id"]
             and audio_document["durationMs"] == frames // 16 and audio_document["mediaProfileId"] == PROFILE, "final audio manifest identity/profile mismatch")
        objects = audio_document["objects"]
        need(len(objects) == (1 if frames else 0), "final audio object count mismatch")
        if objects:
            obj = objects[0]
            need(obj["objectId"] == identity[0] and obj["index"] == 0 and obj["contentType"] == "audio/x-caf"
                 and obj["sha256"] == whole_hash and obj["byteLength"] == stable_bytes
                 and obj["startMs"] == 0 and obj["endMs"] == frames // 16
                 and obj["channelMap"] == [{"channelIndex": c, "trackId": identity[c + 2]} for c in range(2)], "final master object mapping/hash mismatch")
        call["audioManifest"] = audio_document
    for bucket in bins:
        for channel in bucket["channels"]:
            channel["rms"] = round(math.sqrt(channel.pop("sumSquares") / max(channel["frames"], 1)), 4)
            channel["tone440Amplitude"] = round(2 * math.hypot(channel.pop("toneReal"), channel.pop("toneImaginary")) / max(channel["frames"], 1), 4)
    call["media"] = {"profile": PROFILE, "confirmedFrames": frames, "confirmedBytes": stable_bytes,
                     "confirmedPrefixSHA256": whole_hash, "commitsVerified": sequence,
                     "finalized": finalized, "integritySHA256": chain.hex(), "files": files,
                     "fileLengthAtReadStart": media_initial.st_size,
                     "unconfirmedTailBytesAtReadStart": media_initial.st_size - stable_bytes,
                     "indexLengthAtReadStart": index_initial.st_size,
                     "channelStateStats": by_state, "oneSecondEnergyBins": bins,
                     "applicationDuringMicrophoneMute": application_during_mute,
                     "channelSamplesChecked": not cursor_only,
                     "sourceStateBytesSHA256": [sha(bytes(value)) for value in all_states],
                     "finalProjectionMatchesCommittedStates": True if finalized else None}
    return call


def collect(manifest_path, label, previous_path=None, cursor_only=False, require_measured_mute=False):
    need(not (cursor_only and require_measured_mute), "measured mute requires full sample inspection")
    manifest = bounded_json(manifest_path)
    need(manifest.get("synthetic") is True, "manifest must explicitly admit synthetic data")
    selected = controlled_selection(manifest.get("controlledCalls"))
    root = Path(manifest["namespacePath"])
    need(root.is_absolute() and root == root.resolve() and root.is_dir(), "namespace must be an existing canonical absolute directory")
    need(re.fullmatch(r"io\.github\.apshenichniy\.trigo\.dev\.[A-Za-z0-9_-]+\.local\.[a-f0-9-]{36}", root.name),
         "only an explicit local Dev namespace is admitted")
    archive_id = manifest["archiveId"]
    need(str(uuid.UUID(archive_id)) == archive_id, "archive ID is not canonical")
    need(root.name.endswith(".local." + archive_id), "local namespace and archive ID disagree")
    prior = bounded_json(previous_path, 16 * 1024 * 1024) if previous_path else None
    previous_calls = {}
    previous_selected = {}
    if prior:
        need(prior["namespacePath"] == str(root) and prior["archiveId"] == archive_id, "previous evidence belongs to another namespace/archive")
        need(prior.get("collectorVersion") == 3, "previous evidence lacks version-3 controlled-call admission")
        previous_selected = controlled_selection(prior.get("controlledCalls"))
        need(set(previous_selected) <= set(selected), "previous controlled call admission was dropped")
        need(all(selected[call_id] == pid for call_id, pid in previous_selected.items()), "previous expected application PID changed")
        for call in prior["calls"]:
            call_id = call["call_id"]
            need(call_id in previous_selected and call_id not in previous_calls, "unexpected or duplicate previously inspected call")
            need(call["process_id"] == previous_selected[call_id]
                 and call.get("expectedApplicationProcessId") == previous_selected[call_id], "previous observed source disagrees with its admission")
            media = call.get("media")
            if media is not None:
                need(isinstance(media, dict), "previous media cursor is invalid")
                frames, byte_count = media.get("confirmedFrames"), media.get("confirmedBytes")
                need(type(frames) is int and 0 <= frames <= 16000 * 600 and frames % 16 == 0,
                     "previous confirmed frame count is invalid")
                need(type(byte_count) is int and byte_count == 68 + 4 * frames,
                     "previous confirmed byte count disagrees with frames")
                digest = media.get("confirmedPrefixSHA256")
                need(isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest),
                     "previous confirmed prefix hash is invalid")
            previous_calls[call_id] = call
        need(set(previous_calls) == set(previous_selected), "previous inspection does not match its controlled-call admission")
    observed_at = utc()
    calls, sql_ms = metadata(root, archive_id, selected)
    sql_released = utc()
    for call in calls:
        previous = previous_calls.get(call["call_id"])
        if previous:
            need(all(call[key] == previous[key] for key in ("process_id", "bundle_id", "window_id")), "previous recorded source identity changed")
            need(all(call["session"][key] == previous["session"][key] for key in ("master_id", "microphone_track_id", "application_track_id")), "previous master/track identity changed")
            need(call["progress"] is not None or "media" not in previous, "previous confirmed media progress disappeared")
    result = {"collectorVersion": 3, "observedAtUTC": observed_at, "sqlReleasedAtUTC": sql_released,
              "sqlSnapshotMs": sql_ms, "label": label, "synthetic": True,
              "sourceCommit": manifest.get("sourceCommit"), "namespacePath": str(root), "archiveId": archive_id,
              "controlledCalls": selection_records(selected),
              "newlyAdmittedCalls": selection_records({call_id: pid for call_id, pid in selected.items() if call_id not in previous_selected}),
              "inspectionMode": "cursor-only" if cursor_only else "full",
              "checksScope": "Only admitted call IDs are queried; unrelated call metadata, documents and media are not read.",
              "boundary": "Explicit call/PID admission; SQLite mode=ro/query_only; SQL closed before media read; no recovery/Keychain/network; energy does not establish physical provenance.",
              "calls": [inspect_call(root, call, previous_calls.get(call["call_id"]), cursor_only) for call in calls]}
    result["mediaInspectedCallIds"] = [call["call_id"] for call in result["calls"] if "media" in call]
    if require_measured_mute:
        for call in result["calls"]:
            media = call.get("media")
            need(media and media["finalized"], "measured mute requires finalized retained media")
            microphone, application = media["channelStateStats"]
            need(microphone["recorded"]["nonzeroSamples"] > 0,
                 "no positive recorded microphone samples")
            need(application["recorded"]["nonzeroSamples"] > 0,
                 "no positive recorded application samples")
            need(microphone["muted"]["frames"] >= 5 * 16000,
                 "less than five seconds of acknowledged microphone mute")
            need(media["applicationDuringMicrophoneMute"]["nonzeroSamples"] > 0,
                 "no application signal during acknowledged microphone mute")
        result["measuredMutePassed"] = True
    connection_path = safe_path(root, "connection.json", exists=False)
    if connection_path.exists():
        connection = bounded_json(connection_path)
        result["connectionMetadataObservedAtUTC"] = utc()
        result["connection"] = {"formatVersion": connection.get("formatVersion"), "retiredCredentialAccounts": connection.get("retiredCredentialAccounts", [])}
        for phase in ("committed", "pending"):
            value = connection.get(phase)
            if value:
                need(value["archiveId"] == archive_id, "connection belongs to another archive")
            result["connection"][phase] = {key: value.get(key) for key in ("archiveId", "stage", "credentialAccount")} if value else None
    result["completedAtUTC"] = utc()
    result["checksPassed"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--cursor-only", action="store_true", help="Fast confirmed-byte/index observation; defer sample energy and suppression checks to a full observation.")
    parser.add_argument("--require-measured-mute", action="store_true", help="Require finalized media with positive microphone/application samples, at least five seconds of acknowledged mute and continuing application signal.")
    args = parser.parse_args()
    try:
        observation = collect(args.manifest, args.label, args.previous, args.cursor_only, args.require_measured_mute)
        # Never overwrite evidence, and never write inside the observed namespace.
        need(not args.output.resolve().is_relative_to(Path(observation["namespacePath"])), "output must be outside observed namespace")
        with args.output.open("x") as output:
            json.dump(observation, output, indent=2, sort_keys=True)
            output.write("\n")
        print(json.dumps({"output": str(args.output), "calls": len(observation["calls"]), "checksPassed": True, "sqlSnapshotMs": observation["sqlSnapshotMs"]}))
    except Exception as error:
        # Do not print arbitrary input values or exception text that might contain secrets.
        print(json.dumps({"checksPassed": False, "errorType": type(error).__name__, "reason": str(error) if isinstance(error, ValueError) else "collector could not complete; inspect synthetic input locally"}), file=sys.stderr)
        sys.exit(1)
