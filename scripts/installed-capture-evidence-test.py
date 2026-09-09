#!/usr/bin/env python3
"""Disposable fabricated inputs verify the collector only, never the installed app."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sqlite3
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).parent
REPO = HERE.parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("installed_capture_evidence", HERE / "installed-capture-evidence.py")
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="trigo-capture-evidence-test-")
        self.directory = Path(self.temporary.name).resolve()
        self.archive_id = str(uuid.uuid4())
        self.root = self.directory / ("io.github.apshenichniy.trigo.dev.test.local." + self.archive_id)
        self.archive = self.root / "Archive"
        self.archive.mkdir(parents=True)
        self.call_id, self.master_id, self.mic_id, self.app_id, self.audio_id, self.account_id = [str(uuid.uuid4()) for _ in range(6)]
        self.media = self.archive / self.call_id / "media"
        self.media.mkdir(parents=True)
        self.database = self.archive / "archive.sqlite3"
        self.manifest = self.directory / "manifest.json"
        self.manifest.write_text(json.dumps({"synthetic": True, "namespacePath": str(self.root), "archiveId": self.archive_id, "sourceCommit": "synthetic-only", "controlledCalls": [{"callId": self.call_id, "expectedApplicationProcessId": 123}]}))
        self.db = sqlite3.connect(self.database)
        schema = (REPO / "apps/macos/Native/RepositorySchema.swift").read_text().split("let repositorySchemaV2 = [", 1)[1].split("\n]", 1)[0]
        for match in re.finditer(r'"""(.*?)"""|"([^"\n]*)"', schema, re.S):
            statement = match.group(1) or match.group(2)
            self.db.execute(statement)
        self.db.execute("PRAGMA user_version=2")
        self.db.execute("INSERT INTO repository_identity VALUES (?,?)", (self.archive_id, str(self.archive)))
        self.db.execute("INSERT INTO lifecycle VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (self.call_id, 1, "pending", None, None, "waiting_for_audio", None, None, "not_available", None, None, "pending", None, None, "active", None, None))
        self.db.execute("INSERT INTO sessions(call_id,microphone_track_id,application_track_id,audio_manifest_id,master_id,started_reference,process_launch_reference) VALUES (?,?,?,?,?,?,?)", (self.call_id, self.mic_id, self.app_id, self.audio_id, self.master_id, 0, 0))
        self.index_header = b"TRGIDX01" + b"".join(uuid.UUID(value).bytes for value in (self.master_id, self.call_id, self.mic_id, self.app_id)) + bytes(24)
        self.index_header += hashlib.sha256(self.index_header).digest()
        self.chain = self.index_header[-32:]
        (self.media / "master.caf").write_bytes(collector.HEADER)
        (self.media / "master.index").write_bytes(self.index_header)
        self.all_states = [[], []]
        self.frames = 0
        self.commits = 0
        self.publish(False)
        self.db.commit()
        (self.root / "connection.json").write_text(json.dumps({"formatVersion": 1, "committed": {"serverURL": "http://127.0.0.1:12345", "archiveId": self.archive_id, "stage": "dev", "credentialAccount": self.account_id, "token": "SECRET-NEVER-EXPORT"}, "pending": None, "retiredCredentialAccounts": []}))

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def document(self, data):
        raw = json.dumps(data, separators=(",", ":")).encode()
        digest = collector.sha(raw)
        self.db.execute("INSERT OR IGNORE INTO documents VALUES (?,?,1)", (digest, len(raw)))
        self.db.execute("INSERT OR IGNORE INTO document_chunks VALUES (?,0,?)", (digest, raw))
        return digest

    def publish(self, final):
        audio_hash = None
        if final:
            media_hash = collector.sha((self.media / "master.caf").read_bytes())
            audio = {"schemaVersion": 1, "callId": self.call_id, "manifestId": self.audio_id, "durationMs": self.frames // 16, "mediaProfileId": collector.PROFILE, "objects": [{"objectId": self.master_id, "index": 0, "contentType": "audio/x-caf", "byteLength": 68 + 4 * self.frames, "sha256": media_hash, "startMs": 0, "endMs": self.frames // 16, "channelMap": [{"channelIndex": 0, "trackId": self.mic_id}, {"channelIndex": 1, "trackId": self.app_id}]}] if self.frames else []}
            audio_hash = self.document(audio)
        version = 2 if final else 1
        digest = self.document({"fixture": "collector-only", "callId": self.call_id, "version": version})
        self.db.execute("INSERT INTO call_values VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (digest, self.call_id, version, "2026-09-07T00:00:00.000Z", "2026-09-07T00:00:03.000Z" if final else None, self.frames // 16 if final else None, "interrupted" if final else "recording", "process_terminated" if final else None, "Synthetic fixture", "test.synthetic", 123, 7, None, self.audio_id if final else None, audio_hash, None))
        self.db.execute("INSERT INTO calls VALUES (?,?) ON CONFLICT(call_id) DO UPDATE SET hash=excluded.hash", (self.call_id, digest))
        self.db.execute("INSERT INTO snapshot_history VALUES (?,?,?)", (self.call_id, version, digest))
        for channel, (track, role) in enumerate(zip((self.mic_id, self.app_id), ("microphone", "application"))):
            self.db.execute("INSERT INTO call_tracks VALUES (?,?,?,?,?,?,?)", (digest, channel, track, role, "synthetic" if channel == 0 else None, "synthetic" if channel == 0 else None, collector.PROFILE))
            if final:
                for ordinal, state in enumerate(self.all_states[channel]):
                    self.db.execute("INSERT INTO track_intervals VALUES (?,?,?,?,?,?,?)", (digest, channel, ordinal, ordinal * 1000, (ordinal + 1) * 1000, state, None))

    def append(self, mic="recorded", app="recorded", nonzero_muted=False):
        self.commits += 1
        start = self.frames
        self.frames += 16000
        pcm = b"".join(struct.pack("<hh", 1200 if mic == "recorded" or nonzero_muted else 0, -2000 if app == "recorded" else 0) for _ in range(16000))
        pcm_hash = collector.sha(pcm)
        record = b"AUDIO001" + struct.pack(">qq", self.frames, 68 + 4 * self.frames) + bytes.fromhex(pcm_hash) + self.chain + bytes((collector.STATES[mic], collector.STATES[app])) * 1000
        self.chain = hashlib.sha256(record).digest()
        with (self.media / "master.caf").open("ab") as output:
            output.write(pcm)
        with (self.media / "master.index").open("ab") as output:
            output.write(record + self.chain)
        self.db.execute("INSERT INTO media_commits VALUES (?,?,?,?,?,?,?)", (self.call_id, self.commits, start, self.frames, 68 + self.frames * 4, self.chain.hex(), pcm_hash))
        for channel, state in enumerate((mic, app)):
            self.all_states[channel].append(state)
            self.db.execute("INSERT INTO media_intervals VALUES (?,?,?,?,?,?,?)", (self.call_id, self.commits, channel, 0, start // 16, self.frames // 16, state))
        self.db.execute("INSERT INTO capture_progress VALUES (?,?,NULL) ON CONFLICT(call_id) DO UPDATE SET sequence=excluded.sequence", (self.call_id, self.commits))
        self.db.commit()

    def finalize(self):
        digest = collector.sha((self.media / "master.caf").read_bytes())
        record = b"FINAL001" + struct.pack(">qq", self.frames, 68 + self.frames * 4) + bytes.fromhex(digest) + self.chain + bytes(2000)
        with (self.media / "master.index").open("ab") as output:
            output.write(record + hashlib.sha256(record).digest())
        self.db.execute("INSERT INTO capture_progress VALUES (?,?,?) ON CONFLICT(call_id) DO UPDATE SET finalized_hash=excluded.finalized_hash", (self.call_id, self.commits or None, digest))
        self.db.execute("UPDATE sessions SET stop_requested=1,stop_reason='process_terminated'")
        self.publish(True)
        self.db.commit()

    def collect(self, previous=None, cursor_only=False):
        return collector.collect(self.manifest, "synthetic-collector-test", previous, cursor_only)

    def select(self, value):
        manifest = json.loads(self.manifest.read_text())
        if value is None:
            manifest.pop("controlledCalls", None)
        else:
            manifest["controlledCalls"] = value
        self.manifest.write_text(json.dumps(manifest))

    def add_inventory_call(self, admissible=False):
        call_id = str(uuid.uuid4())
        digest = self.document({"fixture": "admitted-empty-call"}) if admissible else "f" * 64
        self.db.execute("INSERT INTO call_values VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (digest, call_id, 1, "2026-09-07T00:00:04.000Z", None, None, "recording", None, "Synthetic second source", "test.second", 456, 8, None, None, None, None))
        self.db.execute("INSERT INTO calls VALUES (?,?)", (call_id, digest))
        self.db.execute("INSERT INTO lifecycle VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (call_id, 1, "pending", None, None, "waiting_for_audio", None, None, "not_available", None, None, "pending", None, None, "active", None, None))
        if admissible:
            self.db.execute("INSERT INTO sessions(call_id,microphone_track_id,application_track_id,audio_manifest_id,master_id,started_reference,process_launch_reference) VALUES (?,?,?,?,?,?,?)", (call_id, *[str(uuid.uuid4()) for _ in range(4)], 0, 0))
            self.db.execute("INSERT INTO snapshot_history VALUES (?,1,?)", (call_id, digest))
        self.db.commit()
        return call_id

    def reject_before_media(self, pattern, previous=None, cursor_only=False):
        real_open = collector.open_read
        media_attempts = []

        def guarded_open(path):
            if "media" in path.parts:
                media_attempts.append(path)
                raise AssertionError("media was opened before admission completed")
            return real_open(path)

        with patch.object(collector, "open_read", side_effect=guarded_open):
            with self.assertRaisesRegex(ValueError, pattern):
                self.collect(previous, cursor_only)
        self.assertEqual(media_attempts, [])

    def test_mixed_namespace_excluded_missing_or_unreadable_media_is_never_opened(self):
        self.append()
        excluded = self.add_inventory_call()
        excluded_directory = self.archive / excluded
        real_open = collector.open_read
        media_paths = []

        def guarded_open(path):
            self.assertFalse(path.is_relative_to(excluded_directory), "excluded call input was opened")
            if "media" in path.parts:
                media_paths.append(path)
            return real_open(path)

        for condition in ("missing", "unreadable"):
            if condition == "unreadable":
                directory = excluded_directory / "media"
                directory.mkdir(parents=True)
                (directory / "master.caf").write_bytes(b"EXCLUDED-DO-NOT-READ")
                (directory / "master.caf").chmod(0)
            for cursor_only in (False, True):
                with self.subTest(condition=condition, cursor_only=cursor_only):
                    with patch.object(collector, "open_read", side_effect=guarded_open):
                        observed = self.collect(cursor_only=cursor_only)
                    self.assertEqual([call["call_id"] for call in observed["calls"]], [self.call_id])
                    self.assertEqual(observed["mediaInspectedCallIds"], [self.call_id])
                    self.assertEqual(observed["controlledCalls"], [{"callId": self.call_id, "expectedApplicationProcessId": 123}])
                    self.assertEqual(observed["inspectionMode"], "cursor-only" if cursor_only else "full")
                    self.assertNotIn(excluded, json.dumps(observed))
        self.assertEqual(set(media_paths), {self.media / "master.caf", self.media / "master.index"})

    def test_wrong_pid_of_later_selection_fails_before_any_media_read(self):
        self.append()
        other = self.add_inventory_call()
        self.select([{"callId": self.call_id, "expectedApplicationProcessId": 123}, {"callId": other, "expectedApplicationProcessId": 999}])
        for cursor_only in (False, True):
            with self.subTest(cursor_only=cursor_only):
                self.reject_before_media("PID does not match", cursor_only=cursor_only)

    def test_invalid_or_unexpected_selection_fails_before_media(self):
        self.append()
        selected = {"callId": self.call_id, "expectedApplicationProcessId": 123}
        cases = [None, [], [selected, selected], [{"callId": self.call_id}],
                 [{**selected, "unexpected": True}], [{**selected, "callId": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}],
                 [{**selected, "callId": str(uuid.uuid4())}]]
        cases.extend([[{**selected, "expectedApplicationProcessId": value}] for value in (None, True, 0, -1, 2147483648, "123")])
        cases.append([{**selected, "callId": str(uuid.uuid4())} for _ in range(21)])
        for selection in cases:
            with self.subTest(selection=selection):
                self.select(selection)
                self.reject_before_media(".+")

    def test_previous_selection_cannot_drop_change_pid_or_silently_widen(self):
        self.append()
        first = {"callId": self.call_id, "expectedApplicationProcessId": 123}
        baseline = self.directory / "previous.json"
        baseline.write_text(json.dumps(self.collect(cursor_only=True)))
        self.select([{**first, "expectedApplicationProcessId": 999}])
        self.reject_before_media("previous expected application PID changed", baseline)
        other = self.add_inventory_call(admissible=True)
        second = {"callId": other, "expectedApplicationProcessId": 456}
        self.select([first, second])
        expanded = self.collect(baseline)
        self.assertEqual(expanded["newlyAdmittedCalls"], [second])
        self.assertTrue(expanded["calls"][0]["previousPrefix"]["preserved"])
        expanded_path = self.directory / "expanded.json"
        expanded_path.write_text(json.dumps(expanded))
        self.select([first])
        self.reject_before_media("previous controlled call admission was dropped", expanded_path)
        self.select([first, second])
        self.db.execute("UPDATE call_values SET bundle_id='changed.source' WHERE call_id=?", (self.call_id,))
        self.db.commit()
        self.reject_before_media("previous recorded source identity changed", expanded_path)

    def test_previous_unscoped_or_duplicate_evidence_is_rejected_before_media(self):
        self.append()
        previous = self.collect(cursor_only=True)
        previous_path = self.directory / "previous.json"
        previous_path.write_text(json.dumps({**previous, "collectorVersion": 1}))
        self.reject_before_media("version-3 controlled-call admission", previous_path)
        previous_path.write_text(json.dumps({**previous, "calls": previous["calls"] * 2}))
        self.reject_before_media("duplicate previously inspected call", previous_path)
        previous_path.write_text(json.dumps({**previous, "archiveId": str(uuid.uuid4())}))
        self.reject_before_media("another namespace/archive", previous_path)

    def test_previous_confirmed_cursor_cannot_disappear(self):
        self.append()
        previous = self.directory / "previous.json"
        previous.write_text(json.dumps(self.collect(cursor_only=True)))
        self.db.execute("DELETE FROM capture_progress")
        self.db.commit()
        self.reject_before_media("previous confirmed media progress disappeared", previous)

    def test_active_prefix_then_final_plus_later_commit_and_read_only(self):
        self.append()
        previous = self.directory / "previous.json"
        previous.write_text(json.dumps(self.collect(cursor_only=True)))
        self.append(mic="muted")
        self.append(mic="unavailable", app="unavailable")
        self.finalize()
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        observed = self.collect(previous)
        after = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        self.assertEqual(before, after)
        call = observed["calls"][0]
        self.assertEqual(call["previousPrefix"]["additionalConfirmedFrames"], 32000)
        self.assertEqual(call["media"]["channelStateStats"][0]["muted"]["nonzeroSamples"], 0)
        self.assertEqual(call["media"]["channelStateStats"][0]["recorded"]["nonzeroSamples"], 16000)
        self.assertEqual(call["media"]["channelStateStats"][1]["recorded"]["nonzeroSamples"], 32000)
        self.assertNotIn("SECRET-NEVER-EXPORT", json.dumps(observed))
        self.assertNotIn("serverURL", json.dumps(observed))

    def test_unconfirmed_tail_is_observed_without_recovery(self):
        self.append()
        path = self.media / "master.caf"
        with path.open("ab") as output:
            output.write(b"unconfirmed")
        observed = self.collect()
        self.assertEqual(observed["calls"][0]["media"]["unconfirmedTailBytesAtReadStart"], 11)
        self.assertTrue(path.read_bytes().endswith(b"unconfirmed"))

    def test_corrupt_confirmed_pcm_is_rejected(self):
        self.append()
        path = self.media / "master.caf"
        data = bytearray(path.read_bytes())
        data[70] ^= 1
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "PCM hash"):
            self.collect()

    def test_suppressed_nonzero_even_with_matching_hash_is_rejected(self):
        self.append(mic="muted", nonzero_muted=True)
        with self.assertRaisesRegex(ValueError, "nonzero suppressed"):
            self.collect()

    def test_sql_interval_disagrees_with_index_is_rejected(self):
        self.append()
        self.db.execute("UPDATE media_intervals SET state='muted' WHERE channel=0")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "integrity or source-state"):
            self.collect()

    def test_final_projection_mismatch_is_rejected(self):
        self.append()
        self.finalize()
        self.db.execute("UPDATE track_intervals SET state='muted' WHERE track_ordinal=0")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "final track projection"):
            self.collect()

    def test_final_whole_hash_mismatch_is_rejected(self):
        self.append()
        self.finalize()
        self.db.execute("UPDATE capture_progress SET finalized_hash=?", ("0" * 64,))
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "whole-master hash"):
            self.collect()

    def test_missing_old_call_is_rejected(self):
        self.append()
        previous = self.directory / "previous.json"
        previous.write_text(json.dumps(self.collect()))
        self.db.execute("DELETE FROM calls")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "selected call identity is missing"):
            self.collect(previous)

    def test_wrong_archive_and_symlink_are_rejected(self):
        manifest = json.loads(self.manifest.read_text())
        manifest["archiveId"] = str(uuid.uuid4())
        self.manifest.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "archive ID disagree"):
            self.collect()
        manifest["archiveId"] = self.archive_id
        self.manifest.write_text(json.dumps(manifest))
        self.append()
        path = self.media / "master.caf"
        target = self.directory / "external.caf"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.collect()

    def test_zero_frame_final_header_witness(self):
        self.finalize()
        call = self.collect()["calls"][0]
        self.assertEqual(call["media"]["confirmedBytes"], 68)
        self.assertEqual(call["audioManifest"]["objects"], [])

    def test_admitted_call_without_progress_reads_no_media(self):
        call = self.collect()["calls"][0]
        self.assertNotIn("media", call)

    def test_measured_mute_requires_positive_sources_and_long_enough_muting(self):
        self.append()
        for _ in range(5):
            self.append(mic="muted")
        self.finalize()
        result = collector.collect(self.manifest, "measured", require_measured_mute=True)
        self.assertTrue(result["measuredMutePassed"])
        self.assertEqual(result["calls"][0]["media"]["applicationDuringMicrophoneMute"]["frames"], 80000)
        with self.assertRaisesRegex(ValueError, "full sample inspection"):
            collector.collect(self.manifest, "measured", cursor_only=True, require_measured_mute=True)

    def test_silence_cannot_satisfy_positive_microphone_evidence(self):
        for _ in range(5):
            self.append(mic="muted")
        self.finalize()
        with self.assertRaisesRegex(ValueError, "positive recorded microphone"):
            collector.collect(self.manifest, "silent", require_measured_mute=True)

    def test_additive_schema_versions_and_unknown_version_rejection(self):
        self.append()
        for version in (2, 3, 4):
            self.db.execute(f"PRAGMA user_version={version}")
            self.db.commit()
            self.assertTrue(self.collect()["checksPassed"])
        self.db.execute("PRAGMA user_version=99")
        self.db.commit()
        self.reject_before_media("unsupported repository schema")

    def test_installed_personal_path_cannot_be_admitted(self):
        manifest = json.loads(self.manifest.read_text())
        personal = self.directory / "io.github.apshenichniy.trigo"
        personal.mkdir()
        manifest["namespacePath"] = str(personal)
        self.manifest.write_text(json.dumps(manifest))
        self.reject_before_media("only an explicit local Dev namespace")

    def test_malformed_previous_cursors_fail_before_media_access(self):
        self.append()
        baseline = self.collect(cursor_only=True)
        previous = self.directory / "previous.json"
        for field, value in (
            ("confirmedBytes", -1), ("confirmedBytes", True),
            ("confirmedBytes", 68 + 4 * 16000 * 601),
            ("confirmedFrames", -1), ("confirmedFrames", 1.5),
            ("confirmedFrames", 16001), ("confirmedPrefixSHA256", "invalid"),
        ):
            with self.subTest(field=field, value=value):
                modified = json.loads(json.dumps(baseline))
                modified["calls"][0]["media"][field] = value
                previous.write_text(json.dumps(modified))
                self.reject_before_media("previous confirmed", previous)
        class RejectReads(io.BytesIO):
            def read(self, size=-1):
                raise AssertionError("an invalid bound reached the media reader")
        for byte_count in (-1, True, 0, 2**64):
            with self.assertRaisesRegex(ValueError, "outside the observation bound"):
                collector.stream_hash(RejectReads(), byte_count)


if __name__ == "__main__":
    unittest.main(verbosity=2)
