CREATE TABLE trigo_assemblyai_jobs (
  submission_id TEXT PRIMARY KEY REFERENCES trigo_asr_submissions(submission_id),
  phase TEXT NOT NULL CHECK (phase IN ('uploading','uploaded','submitting','submitted','rejected')),
  upload_url TEXT,
  upload_witness TEXT,
  provider_id TEXT UNIQUE,
  failure_code TEXT,
  failure_retry TEXT CHECK (failure_retry IN ('never','after_correction','retryable')),
  cleanup_state TEXT NOT NULL DEFAULT 'not_ready' CHECK (cleanup_state IN ('not_ready','pending','deleted'))
) STRICT;
