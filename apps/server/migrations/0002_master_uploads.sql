CREATE TABLE trigo_master_uploads (
  call_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  upload_id TEXT NOT NULL UNIQUE,
  master_id TEXT NOT NULL UNIQUE,
  registration_hash TEXT NOT NULL,
  microphone_track_id TEXT NOT NULL,
  application_track_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  source_hash TEXT NOT NULL,
  deletion_state TEXT NOT NULL DEFAULT 'active' CHECK (deletion_state IN ('active', 'fenced'))
);

CREATE TABLE trigo_upload_parts (
  upload_id TEXT NOT NULL REFERENCES trigo_master_uploads(upload_id),
  part_index INTEGER NOT NULL CHECK (part_index >= 0 AND part_index < 83),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0 AND byte_length <= 8388608),
  sha256 TEXT NOT NULL,
  receipt_id TEXT NOT NULL UNIQUE,
  writer_id TEXT,
  PRIMARY KEY (upload_id, part_index)
);

CREATE TABLE trigo_master_finalizations (
  upload_id TEXT PRIMARY KEY REFERENCES trigo_master_uploads(upload_id),
  operation_id TEXT NOT NULL UNIQUE,
  request_hash TEXT NOT NULL,
  audio_manifest TEXT NOT NULL,
  receipt TEXT NOT NULL,
  writer_id TEXT
);

-- Each row grants exactly one external PUT to a fresh immutable key. Never reissue it.
-- An absent object or expired request cannot resolve a writer with an unknown outcome.
CREATE TABLE trigo_upload_writers (
  writer_id TEXT PRIMARY KEY,
  upload_id TEXT NOT NULL REFERENCES trigo_master_uploads(upload_id),
  kind TEXT NOT NULL CHECK (kind IN ('part', 'master')),
  part_index INTEGER,
  object_key TEXT NOT NULL UNIQUE,
  byte_length INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('admitted', 'uncertain', 'stored')),
  admitted_at TEXT NOT NULL,
  CHECK ((kind = 'part' AND part_index IS NOT NULL) OR (kind = 'master' AND part_index IS NULL))
);
CREATE INDEX trigo_upload_writers_scope ON trigo_upload_writers(upload_id, kind, part_index);
