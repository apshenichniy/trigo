CREATE TABLE trigo_archive_identity (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  archive_id TEXT NOT NULL UNIQUE CHECK (length(archive_id) = 36),
  created_at TEXT NOT NULL
) STRICT;

CREATE TABLE trigo_owner_credential_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  generation INTEGER NOT NULL CHECK (generation >= 1),
  verifier_sha256 TEXT,
  revoked INTEGER NOT NULL CHECK (revoked IN (0, 1)),
  current_operation_id TEXT NOT NULL CHECK (length(current_operation_id) = 36),
  updated_at TEXT NOT NULL,
  CHECK (
    (revoked = 0 AND verifier_sha256 IS NOT NULL AND length(verifier_sha256) = 64) OR
    (revoked = 1 AND verifier_sha256 IS NULL)
  )
) STRICT;

CREATE TABLE trigo_owner_credential_operations (
  operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
  kind TEXT NOT NULL CHECK (kind IN ('initialize', 'rotate', 'revoke')),
  archive_id TEXT NOT NULL CHECK (length(archive_id) = 36),
  generation INTEGER NOT NULL CHECK (generation >= 1),
  verifier_sha256 TEXT,
  created_at TEXT NOT NULL,
  CHECK (
    (kind = 'revoke' AND verifier_sha256 IS NULL) OR
    (kind IN ('initialize', 'rotate') AND verifier_sha256 IS NOT NULL AND length(verifier_sha256) = 64)
  )
) STRICT;
