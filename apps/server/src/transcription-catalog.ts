import { DateTime, Effect, Schema } from "effect";

import {
  AsrProbeLanguage,
  ExchangeUUID,
  SHA256,
  UTCDateTime,
  type TranscriptionOperation,
} from "@trigo/contracts";

import { TranscriptionProfileId } from "../../../packages/contracts/src/asr-profile.ts";
import { ArchiveId, type OwnerContext } from "./owner-state.ts";
import {
  TranscriptionErrorCode,
  transcriptionError,
  transcriptionFailure,
  transcriptionStorage,
} from "./transcription-errors.ts";
import { type UploadDatabase, requireUploadOwner } from "./upload-catalog.ts";

export type TranscriptionDatabase = UploadDatabase;
type Parameter = string | number | null;
const FailureRetry = Schema.NullOr(Schema.Literals(["never", "after_correction", "retryable"]));

export const TranscriptionRow = Schema.Struct({
  operation_id: ExchangeUUID,
  archive_id: ExchangeUUID,
  call_id: ExchangeUUID,
  generation: Schema.Int,
  owner_generation: Schema.Int,
  command_hash: SHA256,
  revision_id: ExchangeUUID,
  requested_language: AsrProbeLanguage,
  profile_id: TranscriptionProfileId,
  state: Schema.Literals(["queued", "running", "result_available", "failed"]),
  created_at: UTCDateTime,
  updated_at: UTCDateTime,
  failure_code: Schema.NullOr(TranscriptionErrorCode),
  failure_retry: FailureRetry,
  result_key: Schema.NullOr(Schema.String),
  result_sha256: Schema.NullOr(SHA256),
  result_byte_length: Schema.NullOr(Schema.Int),
  provenance_key: Schema.NullOr(Schema.String),
  provenance_sha256: Schema.NullOr(SHA256),
  provenance_byte_length: Schema.NullOr(Schema.Int),
});
export interface TranscriptionRow extends Schema.Schema.Type<typeof TranscriptionRow> {}

export const AttemptRow = Schema.Struct({
  attempt_id: ExchangeUUID,
  operation_id: ExchangeUUID,
  attempt_index: Schema.Literals([0, 1]),
  state: Schema.Literals(["admitted", "failed", "succeeded"]),
  failure_code: Schema.NullOr(TranscriptionErrorCode),
  failure_retry: FailureRetry,
  created_at: UTCDateTime,
});
export interface AttemptRow extends Schema.Schema.Type<typeof AttemptRow> {}

export const SubmissionRow = Schema.Struct({
  submission_id: ExchangeUUID,
  attempt_id: ExchangeUUID,
  interval_index: Schema.Literals([0, 1]),
  start_frame: Schema.Int,
  end_frame: Schema.Int,
  extraction: Schema.String,
  state: Schema.Literals(["planned", "admitted", "retained"]),
  execution_id: Schema.NullOr(ExchangeUUID),
  raw_key: Schema.NonEmptyString,
  raw_sha256: Schema.NullOr(SHA256),
  raw_byte_length: Schema.NullOr(Schema.Int),
  transport: Schema.NullOr(Schema.String),
  provider_request_id: Schema.NullOr(Schema.String),
  valid: Schema.Literals([0, 1]),
});
export interface SubmissionRow extends Schema.Schema.Type<typeof SubmissionRow> {}

export const TranscriptionWriterRow = Schema.Struct({
  writer_id: ExchangeUUID,
  operation_id: ExchangeUUID,
  attempt_id: ExchangeUUID,
  kind: Schema.Literals(["raw", "revision", "provenance"]),
  object_key: Schema.NonEmptyString,
  sha256: Schema.NullOr(SHA256),
  byte_length: Schema.NullOr(Schema.Int),
  state: Schema.Literals(["admitted", "uncertain", "stored"]),
  created_at: UTCDateTime,
});
export interface TranscriptionWriterRow extends Schema.Schema.Type<typeof TranscriptionWriterRow> {}

export const transcriptionRows = Effect.fn("TranscriptionCatalog.read")(function* <
  S extends Schema.ConstraintDecoder<unknown>,
>(db: TranscriptionDatabase, schema: S, sql: string, parameters: readonly Parameter[] = []) {
  const response = yield* transcriptionStorage(() =>
    db
      .prepare(sql)
      .bind(...parameters)
      .all(),
  );
  const rows: unknown = response.results;
  return yield* Schema.decodeUnknownEffect(Schema.Array(schema))(rows).pipe(
    Effect.mapError(() => transcriptionError("asr_catalog_invalid", "after_correction", 503)),
  );
});
export const executeTranscriptionSQL = Effect.fn("TranscriptionCatalog.execute")(
  (db: TranscriptionDatabase, sql: string, parameters: readonly Parameter[] = []) =>
    transcriptionStorage(() =>
      db
        .prepare(sql)
        .bind(...parameters)
        .run(),
    ),
);

/** The alias o always denotes the operation being admitted or published by this statement. */
export const currentTranscriptionFence = `EXISTS (
  SELECT 1 FROM trigo_master_uploads u WHERE u.call_id=o.call_id
  AND u.archive_id=o.archive_id AND u.deletion_state='active'
) AND EXISTS (
  SELECT 1 FROM trigo_archive_identity i JOIN trigo_owner_credential_state s USING (singleton)
  WHERE i.singleton=1 AND i.archive_id=o.archive_id AND s.generation=o.owner_generation AND s.revoked=0
) AND NOT EXISTS (
  SELECT 1 FROM trigo_transcription_operations newer
  WHERE newer.call_id=o.call_id AND newer.generation>o.generation
)`;

export const currentAttemptFence = `EXISTS (
  SELECT 1 FROM trigo_transcription_operations o
  WHERE o.operation_id=a.operation_id AND o.state IN ('queued','running') AND ${currentTranscriptionFence}
) AND NOT EXISTS (
  SELECT 1 FROM trigo_transcription_attempts newer
  WHERE newer.operation_id=a.operation_id AND newer.attempt_index>a.attempt_index
)`;

export type TranscriptionResultRecovery = "active" | "retained-normalization";

/** Retained normalization grants artifact publication only. It never reopens the operation
 * or authorizes provider admission, even while an old Workflow is replaying concurrently. */
export function resultOperationStateFence(mode: TranscriptionResultRecovery): string {
  return mode === "active"
    ? "o.state IN ('queued','running')"
    : "o.state='failed' AND o.failure_code='asr_result_invalid'";
}

export function resultAttemptFence(mode: TranscriptionResultRecovery): string {
  if (mode === "active") {
    return currentAttemptFence;
  }
  return `a.state='failed' AND a.failure_code='asr_result_invalid' AND EXISTS (
    SELECT 1 FROM trigo_transcription_operations o
    WHERE o.operation_id=a.operation_id AND ${resultOperationStateFence(mode)} AND ${currentTranscriptionFence}
  ) AND NOT EXISTS (
    SELECT 1 FROM trigo_transcription_attempts newer
    WHERE newer.operation_id=a.operation_id AND newer.attempt_index>a.attempt_index
  )`;
}

export const transcriptionTimestamp = Effect.fn("Transcription.timestamp")(function* () {
  return DateTime.formatIso(yield* DateTime.now);
});
export const newTranscriptionIdentity = Effect.fn("Transcription.newIdentity")(() =>
  // oxlint-disable-next-line effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Cryptographically independent durable identities are allocated at the service boundary.
  Effect.sync(() => crypto.randomUUID()),
);

export const readTranscription = Effect.fn("TranscriptionCatalog.operation")(function* (
  db: TranscriptionDatabase,
  operationId: string,
) {
  const [row] = yield* transcriptionRows(
    db,
    TranscriptionRow,
    "SELECT * FROM trigo_transcription_operations WHERE operation_id=?",
    [operationId],
  );
  if (!row) {
    return yield* transcriptionError("asr_not_found", "after_correction", 404);
  }
  return row;
});

export const requireTranscriptionOwner = (db: TranscriptionDatabase, owner: OwnerContext) =>
  requireUploadOwner(db, owner).pipe(
    Effect.mapError((error) =>
      error.status === 401
        ? transcriptionError("asr_owner_changed", "after_correction", 401)
        : transcriptionError("asr_storage_unavailable", "retryable", 503),
    ),
  );

export const explainTranscriptionFence = Effect.fn("TranscriptionCatalog.fenceFailure")(function* (
  db: TranscriptionDatabase,
  operation: TranscriptionRow,
) {
  yield* requireTranscriptionOwner(db, {
    archiveId: ArchiveId.make(operation.archive_id),
    credentialGeneration: operation.owner_generation,
  });
  const [call] = yield* transcriptionRows(
    db,
    Schema.Struct({ deletion_state: Schema.String }),
    "SELECT deletion_state FROM trigo_master_uploads WHERE archive_id=? AND call_id=?",
    [operation.archive_id, operation.call_id],
  );
  if (call?.deletion_state === "fenced") {
    return yield* transcriptionError("call_deleted", "never", 410);
  }
  return yield* transcriptionError("asr_superseded", "never", 409);
});

export const requireCurrentAttempt = Effect.fn("TranscriptionCatalog.currentAttempt")(function* (
  db: TranscriptionDatabase,
  attemptId: string,
  mode: TranscriptionResultRecovery = "active",
) {
  const [attempt] = yield* transcriptionRows(
    db,
    AttemptRow,
    `SELECT a.* FROM trigo_transcription_attempts a WHERE a.attempt_id=? AND ${resultAttemptFence(mode)}`,
    [attemptId],
  );
  if (!attempt) {
    const [operation] = yield* transcriptionRows(
      db,
      TranscriptionRow,
      "SELECT o.* FROM trigo_transcription_operations o JOIN trigo_transcription_attempts a USING(operation_id) WHERE a.attempt_id=?",
      [attemptId],
    );
    if (operation) {
      return yield* explainTranscriptionFence(db, operation);
    }
    return yield* transcriptionError("asr_superseded", "never", 409);
  }
  return attempt;
});

export const operationDocument = Effect.fn("TranscriptionCatalog.document")(function* (
  db: TranscriptionDatabase,
  row: TranscriptionRow,
): Effect.fn.Return<
  TranscriptionOperation,
  import("./transcription-errors.ts").TranscriptionError
> {
  const attempts = yield* transcriptionRows(
    db,
    AttemptRow,
    "SELECT * FROM trigo_transcription_attempts WHERE operation_id=? ORDER BY attempt_index",
    [row.operation_id],
  );
  const result =
    row.result_key !== null &&
    row.result_sha256 !== null &&
    row.result_byte_length !== null &&
    row.provenance_key !== null &&
    row.provenance_sha256 !== null &&
    row.provenance_byte_length !== null
      ? {
          revisionId: row.revision_id,
          createdAt: row.created_at,
          sha256: row.result_sha256,
          byteLength: row.result_byte_length,
          provenanceSHA256: row.provenance_sha256,
          provenanceByteLength: row.provenance_byte_length,
        }
      : null;
  if ((row.state === "result_available") !== (result !== null) || attempts.length > 2) {
    return yield* transcriptionError("asr_catalog_invalid", "after_correction", 503);
  }
  return {
    schemaVersion: 1,
    operationId: row.operation_id,
    archiveId: row.archive_id,
    callId: row.call_id,
    revisionId: row.revision_id,
    state: row.state,
    attemptCount: attempts.length,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    result,
    failure:
      row.failure_code !== null && row.failure_retry !== null
        ? transcriptionFailure(row.failure_code, row.failure_retry)
        : null,
  };
});
