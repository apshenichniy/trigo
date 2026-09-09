-- Short-lived capabilities contain only opaque IDs and expiration metadata.
-- Signatures are derived from the live owner verifier and are never stored here.
CREATE TABLE trigo_playback_grants (
  operation_id TEXT PRIMARY KEY,
  grant_id TEXT NOT NULL UNIQUE,
  archive_id TEXT NOT NULL,
  call_id TEXT NOT NULL REFERENCES trigo_master_uploads(call_id),
  owner_generation INTEGER NOT NULL CHECK (owner_generation > 0),
  expires_at_ms INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL
);
CREATE INDEX trigo_playback_grants_call ON trigo_playback_grants(call_id, grant_id);
