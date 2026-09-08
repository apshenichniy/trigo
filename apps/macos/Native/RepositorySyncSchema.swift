import Foundation

/// Additive v4 migration: old immutable snapshot/evidence bytes keep their hashes.
let repositorySyncSchema = [
  "CREATE TABLE speaker_details(hash TEXT NOT NULL, speaker_id TEXT NOT NULL, ordinal INTEGER NOT NULL, track_id TEXT NOT NULL, scope_id TEXT NOT NULL, provider_label TEXT, PRIMARY KEY(hash,speaker_id), UNIQUE(hash,ordinal), FOREIGN KEY(hash,speaker_id) REFERENCES revision_speakers(hash,speaker_id)) STRICT",
  "CREATE TABLE call_speaker_groups(hash TEXT NOT NULL REFERENCES call_values(hash), revision_id TEXT NOT NULL, group_id TEXT NOT NULL, ordinal INTEGER NOT NULL, display_name TEXT NOT NULL, PRIMARY KEY(hash,group_id), UNIQUE(hash,revision_id,ordinal)) STRICT",
  "CREATE TABLE call_group_members(hash TEXT NOT NULL, group_id TEXT NOT NULL, revision_id TEXT NOT NULL, ordinal INTEGER NOT NULL, speaker_id TEXT NOT NULL, PRIMARY KEY(hash,group_id,ordinal), UNIQUE(hash,revision_id,speaker_id), FOREIGN KEY(hash,group_id) REFERENCES call_speaker_groups(hash,group_id)) STRICT",
  "CREATE TABLE speaker_group_history(call_id TEXT NOT NULL REFERENCES calls(call_id), group_id TEXT NOT NULL, revision_id TEXT NOT NULL, PRIMARY KEY(call_id,group_id)) STRICT",
  "CREATE TABLE annotation_edits(operation_id TEXT PRIMARY KEY REFERENCES operations(operation_id), command_hash TEXT NOT NULL REFERENCES documents(hash), result_hash TEXT NOT NULL REFERENCES call_values(hash)) STRICT",
  """
  CREATE TABLE canonical_replica_work(
    operation_id TEXT PRIMARY KEY REFERENCES operations(operation_id),
    call_id TEXT NOT NULL REFERENCES calls(call_id),
    snapshot_hash TEXT NOT NULL REFERENCES call_values(hash),
    document_version INTEGER NOT NULL CHECK(document_version>0),
    request_bound INTEGER NOT NULL DEFAULT 0 CHECK(request_bound IN (0,1)),
    expected_server_version INTEGER CHECK(expected_server_version>0),
    receipt_hash TEXT REFERENCES documents(hash),
    conflict_remote_hash TEXT REFERENCES call_values(hash),
    superseded INTEGER NOT NULL DEFAULT 0 CHECK(superseded IN (0,1)),
    UNIQUE(call_id,document_version)
  ) STRICT
  """,
  "CREATE TABLE replica_annotation_revisions(operation_id TEXT NOT NULL REFERENCES canonical_replica_work(operation_id), revision_id TEXT NOT NULL, PRIMARY KEY(operation_id,revision_id)) STRICT",
  "CREATE TABLE replica_observations(call_id TEXT PRIMARY KEY REFERENCES calls(call_id), document_version INTEGER NOT NULL CHECK(document_version>0), snapshot_hash TEXT NOT NULL) STRICT",
  "CREATE TABLE replica_conflict_revisions(call_id TEXT NOT NULL REFERENCES calls(call_id), remote_hash TEXT NOT NULL REFERENCES call_values(hash), revision_id TEXT NOT NULL, PRIMARY KEY(call_id,remote_hash,revision_id)) STRICT",
  "CREATE TABLE replica_conflict_choices(call_id TEXT NOT NULL, remote_hash TEXT NOT NULL, revision_id TEXT NOT NULL, choice TEXT NOT NULL CHECK(choice IN ('keepThisMac','useServer')), PRIMARY KEY(call_id,remote_hash,revision_id), FOREIGN KEY(call_id,remote_hash,revision_id) REFERENCES replica_conflict_revisions(call_id,remote_hash,revision_id)) STRICT",
  "CREATE TABLE transcript_provenance(revision_id TEXT PRIMARY KEY REFERENCES evidence(identity), hash TEXT NOT NULL REFERENCES documents(hash)) STRICT",
  "CREATE TABLE server_storage_receipts(call_id TEXT PRIMARY KEY REFERENCES calls(call_id), hash TEXT NOT NULL REFERENCES documents(hash)) STRICT",
  "CREATE TABLE archive_sync_cursor(singleton INTEGER PRIMARY KEY CHECK(singleton=1), cursor TEXT NOT NULL) STRICT",
  "CREATE TABLE archive_sync_status(singleton INTEGER PRIMARY KEY CHECK(singleton=1), failure TEXT, retry TEXT, state_version INTEGER NOT NULL CHECK(state_version>0)) STRICT",
  "CREATE TABLE server_catalog_entries(call_id TEXT PRIMARY KEY, hash TEXT NOT NULL REFERENCES documents(hash), refresh_operation INTEGER NOT NULL DEFAULT 1 CHECK(refresh_operation IN (0,1))) STRICT",
  "CREATE TABLE server_transcription_observations(call_id TEXT PRIMARY KEY REFERENCES calls(call_id), hash TEXT NOT NULL REFERENCES documents(hash)) STRICT",
  "CREATE TABLE local_deletion_markers(call_id TEXT PRIMARY KEY, marked_at TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('requested','draining','deleting','complete'))) STRICT",
  "CREATE TABLE automatic_transcriptions(call_id TEXT PRIMARY KEY REFERENCES calls(call_id), operation_id TEXT NOT NULL UNIQUE REFERENCES operations(operation_id), revision_id TEXT NOT NULL UNIQUE, request_hash TEXT NOT NULL REFERENCES documents(hash), remote_hash TEXT REFERENCES documents(hash), recovery_attempted INTEGER NOT NULL DEFAULT 0 CHECK(recovery_attempted IN (0,1)), recovery_pending INTEGER NOT NULL DEFAULT 0 CHECK(recovery_pending IN (0,1))) STRICT",
  "CREATE TABLE imported_server_results(revision_id TEXT PRIMARY KEY REFERENCES evidence(identity), operation_id TEXT NOT NULL UNIQUE REFERENCES operations(operation_id), server_operation_id TEXT NOT NULL, generation INTEGER NOT NULL CHECK(generation>0)) STRICT",
]
