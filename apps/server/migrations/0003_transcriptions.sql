-- Only opaque identity, bounded transport provenance and object references live here.
-- Provider text, normalized revisions and audio remain in private R2.
CREATE TABLE trigo_transcription_operations (
  operation_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  call_id TEXT NOT NULL REFERENCES trigo_master_uploads(call_id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  owner_generation INTEGER NOT NULL,
  command_hash TEXT NOT NULL,
  revision_id TEXT NOT NULL UNIQUE,
  requested_language TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'result_available', 'failed')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  failure_code TEXT,
  failure_retry TEXT CHECK (failure_retry IN ('never', 'after_correction', 'retryable')),
  result_key TEXT,
  result_sha256 TEXT,
  result_byte_length INTEGER,
  provenance_key TEXT,
  provenance_sha256 TEXT,
  provenance_byte_length INTEGER,
  UNIQUE (call_id, generation),
  CHECK ((state = 'result_available') = (result_key IS NOT NULL)),
  CHECK ((result_key IS NULL) = (result_sha256 IS NULL)),
  CHECK ((result_key IS NULL) = (result_byte_length IS NULL)),
  CHECK ((result_key IS NULL) = (provenance_key IS NULL)),
  CHECK ((result_key IS NULL) = (provenance_sha256 IS NULL)),
  CHECK ((result_key IS NULL) = (provenance_byte_length IS NULL))
);
CREATE UNIQUE INDEX trigo_transcription_active_call
  ON trigo_transcription_operations(call_id) WHERE state IN ('queued', 'running');

CREATE TABLE trigo_transcription_attempts (
  attempt_id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL REFERENCES trigo_transcription_operations(operation_id),
  attempt_index INTEGER NOT NULL CHECK (attempt_index IN (0, 1)),
  state TEXT NOT NULL CHECK (state IN ('admitted', 'failed', 'succeeded')),
  failure_code TEXT,
  failure_retry TEXT CHECK (failure_retry IN ('never', 'after_correction', 'retryable')),
  created_at TEXT NOT NULL,
  UNIQUE (operation_id, attempt_index)
);

CREATE TABLE trigo_asr_submissions (
  submission_id TEXT PRIMARY KEY,
  attempt_id TEXT NOT NULL REFERENCES trigo_transcription_attempts(attempt_id),
  interval_index INTEGER NOT NULL CHECK (interval_index IN (0, 1)),
  start_frame INTEGER NOT NULL,
  end_frame INTEGER NOT NULL,
  extraction TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('planned', 'admitted', 'retained')),
  execution_id TEXT,
  raw_key TEXT NOT NULL UNIQUE,
  raw_sha256 TEXT,
  raw_byte_length INTEGER,
  transport TEXT,
  provider_request_id TEXT,
  valid INTEGER NOT NULL DEFAULT 0 CHECK (valid IN (0, 1)),
  UNIQUE (attempt_id, interval_index)
);

-- A replacement reuses already validated intervals with their original provider scope.
CREATE TABLE trigo_transcription_attempt_submissions (
  attempt_id TEXT NOT NULL REFERENCES trigo_transcription_attempts(attempt_id),
  interval_index INTEGER NOT NULL CHECK (interval_index IN (0, 1)),
  submission_id TEXT NOT NULL REFERENCES trigo_asr_submissions(submission_id),
  PRIMARY KEY (attempt_id, interval_index)
);

-- A distinct row admits every external PUT, including writes whose acknowledgement is lost.
-- Never infer a drained writer from a missing object. #22 can enumerate unresolved writes.
CREATE TABLE trigo_transcription_writers (
  writer_id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL REFERENCES trigo_transcription_operations(operation_id),
  attempt_id TEXT NOT NULL REFERENCES trigo_transcription_attempts(attempt_id),
  kind TEXT NOT NULL CHECK (kind IN ('raw', 'revision', 'provenance')),
  object_key TEXT NOT NULL UNIQUE,
  sha256 TEXT,
  byte_length INTEGER,
  state TEXT NOT NULL CHECK (state IN ('admitted', 'uncertain', 'stored')),
  created_at TEXT NOT NULL,
  CHECK (kind = 'raw' OR (sha256 IS NOT NULL AND byte_length IS NOT NULL))
);
CREATE INDEX trigo_transcription_writer_scope
  ON trigo_transcription_writers(operation_id, writer_id);
