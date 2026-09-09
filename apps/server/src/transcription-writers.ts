import { Effect } from "effect";

import { storedByteHash } from "@trigo/contracts";

import { type MasterUploadEnvironment } from "./master-uploads.ts";
import {
  currentAttemptFence,
  executeTranscriptionSQL,
  newTranscriptionIdentity,
  resultAttemptFence,
  transcriptionRows,
  transcriptionTimestamp,
  TranscriptionWriterRow,
  type AttemptRow,
  type SubmissionRow,
  type TranscriptionRow,
  type TranscriptionResultRecovery,
} from "./transcription-catalog.ts";
import { transcriptionError, transcriptionStorage } from "./transcription-errors.ts";
import { objectMatches } from "./upload-streams.ts";

export const reconcileTranscriptionWriter = Effect.fn("TranscriptionWriter.reconcile")(function* (
  env: MasterUploadEnvironment,
  writer: TranscriptionWriterRow,
) {
  if (writer.sha256 === null || writer.byte_length === null) {
    return false;
  }
  const object = yield* transcriptionStorage(() => env.ARCHIVE.head(writer.object_key));
  if (
    !object ||
    !objectMatches(object, {
      object_key: writer.object_key,
      sha256: writer.sha256,
      byte_length: writer.byte_length,
    })
  ) {
    return false;
  }
  yield* executeTranscriptionSQL(
    env.CATALOG,
    "UPDATE trigo_transcription_writers SET state='stored' WHERE writer_id=?",
    [writer.writer_id],
  );
  return true;
});

export interface StoredTranscriptionArtifact {
  readonly writerId: string;
  readonly key: string;
  readonly sha256: string;
  readonly byteLength: number;
}

const putAdmittedArtifact = Effect.fn("TranscriptionWriter.putAdmitted")(function* (
  env: MasterUploadEnvironment,
  writer: TranscriptionWriterRow,
  bytes: Uint8Array,
  metadata?: Record<string, string>,
) {
  const sha256 = writer.sha256;
  const byteLength = writer.byte_length;
  if (sha256 === null || byteLength === null || bytes.byteLength !== byteLength) {
    return yield* transcriptionError("asr_catalog_invalid", "after_correction", 503);
  }
  const stored = yield* transcriptionStorage(() =>
    env.ARCHIVE.put(writer.object_key, bytes, {
      sha256,
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/json", cacheControl: "private, no-store" },
      ...(metadata === undefined ? {} : { customMetadata: metadata }),
    }),
  ).pipe(Effect.result);
  if (
    stored._tag === "Failure" ||
    stored.success === null ||
    !objectMatches(stored.success, {
      object_key: writer.object_key,
      sha256,
      byte_length: byteLength,
    })
  ) {
    yield* executeTranscriptionSQL(
      env.CATALOG,
      "UPDATE trigo_transcription_writers SET state='uncertain' WHERE writer_id=?",
      [writer.writer_id],
    );
    if (!(yield* reconcileTranscriptionWriter(env, writer))) {
      return yield* transcriptionError("asr_storage_unavailable", "retryable", 503);
    }
  }
  yield* executeTranscriptionSQL(
    env.CATALOG,
    "UPDATE trigo_transcription_writers SET state='stored' WHERE writer_id=?",
    [writer.writer_id],
  );
  return { writerId: writer.writer_id, key: writer.object_key, sha256, byteLength };
});

/** Admission precedes AI.run, including the eventual response PUT whose checksum is not known yet. */
export const admitRawWriter = Effect.fn("TranscriptionWriter.admitRaw")(function* (
  env: MasterUploadEnvironment,
  operation: TranscriptionRow,
  attempt: AttemptRow,
  submission: SubmissionRow,
) {
  const writerId = yield* newTranscriptionIdentity();
  const now = yield* transcriptionTimestamp();
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_transcription_writers
     (writer_id,operation_id,attempt_id,kind,object_key,state,created_at)
     SELECT ?,?,?,'raw',?,'admitted',? FROM trigo_transcription_attempts a
     WHERE a.attempt_id=? AND ${currentAttemptFence}`,
    [
      writerId,
      operation.operation_id,
      attempt.attempt_id,
      submission.raw_key,
      now,
      attempt.attempt_id,
    ],
  );
  const [writer] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE object_key=? AND attempt_id=? AND kind='raw'",
    [submission.raw_key, attempt.attempt_id],
  );
  if (!writer) {
    return yield* transcriptionError("asr_superseded", "never", 409);
  }
  return writer;
});

/** Only the one-time provider executor owns this response. A replay reads its retained artifact. */
export const storeRawResponse = Effect.fn("TranscriptionWriter.storeRawResponse")(function* (
  env: MasterUploadEnvironment,
  writer: TranscriptionWriterRow,
  bytes: Uint8Array,
  metadata: Record<string, string>,
) {
  const sha256 = yield* Effect.promise(() => storedByteHash(bytes));
  const updated = yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_transcription_writers SET sha256=?,byte_length=?
     WHERE writer_id=? AND sha256 IS NULL AND state='admitted'`,
    [sha256, bytes.byteLength, writer.writer_id],
  );
  const [current] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE writer_id=?",
    [writer.writer_id],
  );
  if (!current || current.sha256 !== sha256 || current.byte_length !== bytes.byteLength) {
    return yield* transcriptionError("asr_result_invalid", "after_correction", 503);
  }
  if (updated.meta.changes !== 1) {
    if (yield* reconcileTranscriptionWriter(env, current)) {
      return {
        writerId: current.writer_id,
        key: current.object_key,
        sha256,
        byteLength: bytes.byteLength,
      };
    }
    return yield* transcriptionError("asr_storage_unavailable", "retryable", 503);
  }
  return yield* putAdmittedArtifact(env, current, bytes, metadata);
});

/** Resolved keys are private server identities. An uncertain PUT is never issued twice. */
export const storeTranscriptionArtifact = Effect.fn("TranscriptionWriter.store")(function* (
  env: MasterUploadEnvironment,
  operation: TranscriptionRow,
  attempt: AttemptRow,
  kind: "revision" | "provenance",
  bytes: Uint8Array,
  recovery: TranscriptionResultRecovery = "active",
) {
  const sha256 = yield* Effect.promise(() => storedByteHash(bytes));
  const retained = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    `SELECT * FROM trigo_transcription_writers WHERE attempt_id=? AND kind=? AND sha256=? AND byte_length=?
     ORDER BY writer_id LIMIT 16`,
    [attempt.attempt_id, kind, sha256, bytes.byteLength],
  );
  for (const writer of retained) {
    if (yield* reconcileTranscriptionWriter(env, writer)) {
      return {
        writerId: writer.writer_id,
        key: writer.object_key,
        sha256,
        byteLength: bytes.byteLength,
      };
    }
  }
  const writerId = yield* newTranscriptionIdentity();
  const key = `archives/${operation.archive_id}/calls/${operation.call_id}/transcriptions/${operation.revision_id}/${kind}/${writerId}.json`;
  const now = yield* transcriptionTimestamp();
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_transcription_writers
     (writer_id,operation_id,attempt_id,kind,object_key,sha256,byte_length,state,created_at)
     SELECT ?,?,?,?,?,?,?,'admitted',? FROM trigo_transcription_attempts a
     WHERE a.attempt_id=? AND ${resultAttemptFence(recovery)}`,
    [
      writerId,
      operation.operation_id,
      attempt.attempt_id,
      kind,
      key,
      sha256,
      bytes.byteLength,
      now,
      attempt.attempt_id,
    ],
  );
  const [writer] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE writer_id=?",
    [writerId],
  );
  if (!writer) {
    return yield* transcriptionError("asr_superseded", "never", 409);
  }
  return yield* putAdmittedArtifact(env, writer, bytes);
});

/** Deferred deletion can enumerate every admitted writer, including a lost acknowledgement. */
export const inspectTranscriptionWriters = (
  env: MasterUploadEnvironment,
  operationId: string,
  after = "",
) =>
  transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE operation_id=? AND writer_id>? ORDER BY writer_id LIMIT 128",
    [operationId, after],
  );
