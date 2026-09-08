-- A published operation is the immutable catalog pointer and its replay receipt.
-- Selecting the highest published version avoids a second mutable pointer transaction.
CREATE TABLE trigo_replica_operations (
  operation_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  call_id TEXT NOT NULL REFERENCES trigo_master_uploads(call_id),
  owner_generation INTEGER NOT NULL,
  command_hash TEXT NOT NULL,
  document_version INTEGER NOT NULL CHECK(document_version > 0),
  schema_version INTEGER NOT NULL CHECK(schema_version IN (1,2)),
  sha256 TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK(byte_length > 0),
  expected_version INTEGER CHECK(expected_version > 0),
  object_key TEXT,
  writer_id TEXT,
  state TEXT NOT NULL CHECK(state IN ('admitted','published')),
  created_at TEXT NOT NULL,
  published_at TEXT,
  CHECK(state != 'published' OR (object_key IS NOT NULL AND writer_id IS NOT NULL AND published_at IS NOT NULL))
);
-- statement-breakpoint
CREATE UNIQUE INDEX trigo_replica_published_versions ON trigo_replica_operations(call_id,document_version) WHERE state='published';
-- statement-breakpoint
CREATE INDEX trigo_replica_current ON trigo_replica_operations(archive_id,call_id,state,document_version DESC);
-- statement-breakpoint
CREATE TABLE trigo_replica_writers (
  writer_id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL REFERENCES trigo_replica_operations(operation_id),
  object_key TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK(byte_length > 0),
  state TEXT NOT NULL CHECK(state IN ('admitted','uncertain','stored')),
  created_at TEXT NOT NULL
);
-- statement-breakpoint
CREATE INDEX trigo_replica_writer_operation ON trigo_replica_writers(operation_id,writer_id);
-- statement-breakpoint
CREATE TABLE trigo_replica_groups (
  operation_id TEXT NOT NULL REFERENCES trigo_replica_operations(operation_id),
  group_id TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  PRIMARY KEY(operation_id,group_id)
);
-- statement-breakpoint
CREATE TABLE trigo_sync_epoch (singleton INTEGER PRIMARY KEY CHECK(singleton=1), epoch TEXT NOT NULL);
-- statement-breakpoint
INSERT INTO trigo_sync_epoch VALUES (1,lower(hex(randomblob(16))));
-- statement-breakpoint
CREATE TABLE trigo_call_deletion_markers (
  call_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  marked_at TEXT NOT NULL,
  phase TEXT NOT NULL CHECK(phase IN ('requested','draining','deleting','complete'))
);
-- statement-breakpoint
CREATE TABLE trigo_call_changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  archive_id TEXT NOT NULL,
  call_id TEXT NOT NULL
);
-- statement-breakpoint
CREATE INDEX trigo_call_changes_archive ON trigo_call_changes(archive_id,sequence);
-- statement-breakpoint
CREATE TRIGGER trigo_sync_registered AFTER INSERT ON trigo_master_uploads BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) VALUES(NEW.archive_id,NEW.call_id);
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_audio_stored AFTER INSERT ON trigo_master_finalizations BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) SELECT archive_id,call_id FROM trigo_master_uploads WHERE upload_id=NEW.upload_id;
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_transcription_created AFTER INSERT ON trigo_transcription_operations BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) VALUES(NEW.archive_id,NEW.call_id);
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_transcription_changed AFTER UPDATE OF state,failure_code,result_sha256 ON trigo_transcription_operations
WHEN OLD.state IS NOT NEW.state OR OLD.failure_code IS NOT NEW.failure_code OR OLD.result_sha256 IS NOT NEW.result_sha256 BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) VALUES(NEW.archive_id,NEW.call_id);
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_transcription_attempt AFTER INSERT ON trigo_transcription_attempts BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) SELECT archive_id,call_id FROM trigo_transcription_operations WHERE operation_id=NEW.operation_id;
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_replica_published AFTER UPDATE OF state ON trigo_replica_operations WHEN NEW.state='published' AND OLD.state!='published' BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) VALUES(NEW.archive_id,NEW.call_id);
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_delete_fenced AFTER UPDATE OF deletion_state ON trigo_master_uploads WHEN NEW.deletion_state='fenced' BEGIN
  INSERT OR IGNORE INTO trigo_call_deletion_markers VALUES(NEW.call_id,NEW.archive_id,strftime('%Y-%m-%dT%H:%M:%fZ','now'),'draining');
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_marker_created AFTER INSERT ON trigo_call_deletion_markers BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) VALUES(NEW.archive_id,NEW.call_id);
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_marker_changed AFTER UPDATE OF phase ON trigo_call_deletion_markers WHEN NEW.phase IS NOT OLD.phase BEGIN
  INSERT INTO trigo_call_changes(archive_id,call_id) VALUES(NEW.archive_id,NEW.call_id);
END;
-- statement-breakpoint
CREATE TRIGGER trigo_sync_no_resurrection BEFORE INSERT ON trigo_master_uploads WHEN EXISTS(SELECT 1 FROM trigo_call_deletion_markers WHERE call_id=NEW.call_id) BEGIN
  SELECT RAISE(ABORT,'call_deleted');
END;
-- statement-breakpoint
INSERT INTO trigo_call_deletion_markers SELECT call_id,archive_id,strftime('%Y-%m-%dT%H:%M:%fZ','now'),'draining' FROM trigo_master_uploads WHERE deletion_state='fenced';
-- statement-breakpoint
INSERT INTO trigo_call_changes(archive_id,call_id) SELECT archive_id,call_id FROM trigo_master_uploads;
