import Foundation

/// Immutable preparation rows are content-addressed. Only the small calls/evidence/history
/// publication tables make prepared data visible. A crash may retain unreachable preparation;
/// it never exposes a half-imported revision or a partially assembled call snapshot.
let repositorySchemaVersion = 3

let repositorySchemaV2 = [
  "CREATE TABLE repository_identity(archive_id TEXT NOT NULL, root TEXT NOT NULL) STRICT",
  "CREATE TABLE documents(hash TEXT PRIMARY KEY, byte_count INTEGER NOT NULL CHECK(byte_count>=0), complete INTEGER NOT NULL CHECK(complete IN (0,1))) STRICT",
  "CREATE TABLE document_chunks(hash TEXT NOT NULL REFERENCES documents(hash), part INTEGER NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY(hash,part)) STRICT",
  """
  CREATE TABLE call_values(
    hash TEXT PRIMARY KEY REFERENCES documents(hash), call_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version>0),
    started_at TEXT NOT NULL, ended_at TEXT, duration_ms INTEGER CHECK(duration_ms>=0),
    capture_state TEXT NOT NULL CHECK(capture_state IN ('recording','stopped','interrupted')), reason TEXT,
    application_name TEXT NOT NULL, bundle_id TEXT NOT NULL, process_id INTEGER NOT NULL,
    window_id INTEGER, window_title TEXT, audio_id TEXT, audio_hash TEXT, active_revision_id TEXT
  ) STRICT
  """,
  "CREATE TABLE call_tracks(hash TEXT NOT NULL REFERENCES call_values(hash), ordinal INTEGER NOT NULL, track_id TEXT NOT NULL, role TEXT NOT NULL, device_id TEXT, device_name TEXT, profile TEXT NOT NULL, PRIMARY KEY(hash,ordinal), UNIQUE(hash,track_id)) STRICT",
  "CREATE TABLE track_intervals(hash TEXT NOT NULL, track_ordinal INTEGER NOT NULL, ordinal INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, state TEXT NOT NULL, reason TEXT, PRIMARY KEY(hash,track_ordinal,ordinal), FOREIGN KEY(hash,track_ordinal) REFERENCES call_tracks(hash,ordinal)) STRICT",
  "CREATE TABLE call_revisions(hash TEXT NOT NULL REFERENCES call_values(hash), ordinal INTEGER NOT NULL, revision_id TEXT NOT NULL, created_at TEXT NOT NULL, revision_hash TEXT NOT NULL, PRIMARY KEY(hash,ordinal), UNIQUE(hash,revision_id)) STRICT",
  "CREATE TABLE speaker_names(hash TEXT NOT NULL REFERENCES call_values(hash), revision_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(hash,revision_id,speaker_id)) STRICT",
  "CREATE TABLE calls(call_id TEXT PRIMARY KEY, hash TEXT NOT NULL REFERENCES call_values(hash)) STRICT",
  "CREATE TABLE snapshot_history(call_id TEXT NOT NULL REFERENCES calls(call_id), version INTEGER NOT NULL, hash TEXT NOT NULL REFERENCES call_values(hash), PRIMARY KEY(call_id,version)) STRICT",
  "CREATE TABLE evidence_values(hash TEXT PRIMARY KEY REFERENCES documents(hash), kind TEXT NOT NULL CHECK(kind IN ('audio','revision')), call_id TEXT NOT NULL, identity TEXT NOT NULL, UNIQUE(hash,kind,call_id,identity)) STRICT",
  "CREATE TABLE evidence(identity TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('audio','revision')), call_id TEXT NOT NULL REFERENCES calls(call_id), hash TEXT NOT NULL, FOREIGN KEY(hash,kind,call_id,identity) REFERENCES evidence_values(hash,kind,call_id,identity)) STRICT",
  "CREATE INDEX evidence_call ON evidence(call_id,kind,identity)",
  "CREATE TABLE revision_speakers(hash TEXT NOT NULL REFERENCES documents(hash), speaker_id TEXT NOT NULL, PRIMARY KEY(hash,speaker_id)) STRICT",
  "CREATE TABLE revision_turns(hash TEXT NOT NULL REFERENCES documents(hash), ordinal INTEGER NOT NULL, turn_id TEXT NOT NULL, track_id TEXT NOT NULL, speaker_id TEXT, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(hash,ordinal), UNIQUE(hash,turn_id)) STRICT",
  "CREATE TABLE revision_words(hash TEXT NOT NULL, turn_ordinal INTEGER NOT NULL, ordinal INTEGER NOT NULL, text TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, confidence REAL, PRIMARY KEY(hash,turn_ordinal,ordinal), FOREIGN KEY(hash,turn_ordinal) REFERENCES revision_turns(hash,ordinal)) STRICT",
  """
  CREATE TABLE lifecycle(
    call_id TEXT PRIMARY KEY REFERENCES calls(call_id), state_version INTEGER NOT NULL CHECK(state_version>0),
    upload TEXT NOT NULL CHECK(upload IN ('pending','uploading','stored','failed')), upload_failure TEXT, upload_retry TEXT,
    transcription TEXT NOT NULL CHECK(transcription IN ('waiting_for_audio','queued','running','result_available','failed')), transcription_failure TEXT, transcription_retry TEXT,
    import_state TEXT NOT NULL CHECK(import_state IN ('not_available','pending','imported','failed')), import_failure TEXT, import_retry TEXT,
    replica TEXT NOT NULL CHECK(replica IN ('pending','confirmed','conflict')), replica_failure TEXT, replica_retry TEXT,
    deletion TEXT NOT NULL CHECK(deletion IN ('active','requested','draining','deleting','complete')), deletion_failure TEXT, deletion_retry TEXT
  ) STRICT
  """,
  """
  CREATE TABLE operations(
    operation_id TEXT PRIMARY KEY, call_id TEXT NOT NULL REFERENCES calls(call_id), kind TEXT NOT NULL,
    payload_hash TEXT NOT NULL REFERENCES documents(hash), phase TEXT NOT NULL CHECK(phase IN ('pending','running','blocked','failed')),
    created_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL CHECK(updated_ms>=created_ms), attempt INTEGER NOT NULL CHECK(attempt>=0),
    failure TEXT, retry TEXT, acknowledged INTEGER NOT NULL DEFAULT 0 CHECK(acknowledged IN (0,1))
  ) STRICT
  """,
  "CREATE INDEX operations_pending ON operations(acknowledged,created_ms,operation_id)",
  "CREATE TABLE semantic_work(identity TEXT PRIMARY KEY, operation_id TEXT REFERENCES operations(operation_id)) STRICT",
  "CREATE TABLE sessions(call_id TEXT PRIMARY KEY REFERENCES calls(call_id), microphone_track_id TEXT NOT NULL, application_track_id TEXT NOT NULL, audio_manifest_id TEXT NOT NULL UNIQUE, master_id TEXT NOT NULL UNIQUE, started_reference REAL NOT NULL, process_launch_reference REAL NOT NULL, stop_requested INTEGER NOT NULL DEFAULT 0 CHECK(stop_requested IN (0,1)), stop_reason TEXT, media_failure TEXT, final_work_id TEXT, final_work_kind TEXT, final_work_payload_hash TEXT REFERENCES documents(hash), final_work_prepared INTEGER NOT NULL DEFAULT 0 CHECK(final_work_prepared IN (0,1))) STRICT",
  """
  CREATE TABLE media_commits(
    call_id TEXT NOT NULL REFERENCES sessions(call_id), sequence INTEGER NOT NULL CHECK(sequence>0),
    start_frame INTEGER NOT NULL, frames INTEGER NOT NULL, stable_bytes INTEGER NOT NULL,
    integrity_hash TEXT NOT NULL, pcm_hash TEXT NOT NULL,
    PRIMARY KEY(call_id,sequence), UNIQUE(call_id,frames)
  ) STRICT
  """,
  "CREATE TABLE media_intervals(call_id TEXT NOT NULL, sequence INTEGER NOT NULL, channel INTEGER NOT NULL, ordinal INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, state TEXT NOT NULL, PRIMARY KEY(call_id,sequence,channel,ordinal), FOREIGN KEY(call_id,sequence) REFERENCES media_commits(call_id,sequence)) STRICT",
  "CREATE TABLE capture_progress(call_id TEXT PRIMARY KEY REFERENCES sessions(call_id), sequence INTEGER CHECK(sequence>0), finalized_hash TEXT, CHECK(sequence IS NOT NULL OR finalized_hash IS NOT NULL), FOREIGN KEY(call_id,sequence) REFERENCES media_commits(call_id,sequence)) STRICT",
]

let repositoryUploadSchema = [
  """
  CREATE TABLE master_uploads(
    call_id TEXT PRIMARY KEY REFERENCES sessions(call_id),
    upload_id TEXT NOT NULL UNIQUE,
    operation_id TEXT NOT NULL UNIQUE REFERENCES operations(operation_id),
    finalize_operation_id TEXT NOT NULL UNIQUE,
    source_states_hash TEXT,
    registration_receipt_hash TEXT REFERENCES documents(hash),
    storage_receipt_hash TEXT REFERENCES documents(hash),
    cleanup_complete INTEGER NOT NULL DEFAULT 0 CHECK(cleanup_complete IN (0,1)),
    CHECK(cleanup_complete=0 OR storage_receipt_hash IS NOT NULL)
  ) STRICT
  """,
  """
  CREATE TABLE master_upload_parts(
    call_id TEXT NOT NULL REFERENCES master_uploads(call_id),
    part_index INTEGER NOT NULL CHECK(part_index>=0 AND part_index<83),
    byte_length INTEGER NOT NULL CHECK(byte_length>0 AND byte_length<=8388608),
    sha256 TEXT NOT NULL,
    receipt_hash TEXT REFERENCES documents(hash),
    PRIMARY KEY(call_id,part_index)
  ) STRICT
  """,
]

let repositorySchema = repositorySchemaV2 + repositoryUploadSchema
