import { Effect, Schema, Stream } from "effect";

import { SHA256, storedByteHash } from "@trigo/contracts";

import { assemblyAIStereoProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { AsrExtractionEvidence, extractMasterWave, r2MasterSource } from "./asr-master.ts";
import {
  AssemblyAIUploadWitness,
  type AssemblyAIMasterSubmission,
} from "./assemblyai-normalization.ts";
import {
  AssemblyAIJob,
  AssemblyAIJobId,
  decodeAssemblyAIJSON,
  inspectAssemblyAIResult,
} from "./assemblyai-response.ts";
import { readBoundedBody } from "./nova-3-transport.ts";
import {
  AttemptRow,
  currentAttemptFence,
  executeTranscriptionSQL,
  newTranscriptionIdentity,
  requireCurrentAttempt,
  transcriptionRows,
  TranscriptionWriterRow,
  type AttemptRow as Attempt,
  type SubmissionRow,
  type TranscriptionRow,
} from "./transcription-catalog.ts";
import {
  TranscriptionErrorCode,
  transcriptionError,
  transcriptionJSON,
  transcriptionStorage,
} from "./transcription-errors.ts";
import { decodeExtraction, loadTranscriptionMaster } from "./transcription-submissions.ts";
import {
  admitRawWriter,
  reconcileTranscriptionWriter,
  storeRawResponse,
} from "./transcription-writers.ts";
import type { TranscriptionEnvironment } from "./transcriptions.ts";
import { objectMatches } from "./upload-streams.ts";

const JobRow = Schema.Struct({
  submission_id: Schema.String,
  phase: Schema.Literals(["uploading", "uploaded", "submitting", "submitted", "rejected"]),
  upload_url: Schema.NullOr(Schema.String),
  upload_witness: Schema.NullOr(Schema.String),
  provider_id: Schema.NullOr(AssemblyAIJobId),
  failure_code: Schema.NullOr(TranscriptionErrorCode),
  failure_retry: Schema.NullOr(Schema.Literals(["never", "after_correction", "retryable"])),
  cleanup_state: Schema.Literals(["not_ready", "pending", "deleted"]),
});
const RawMetadata = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  submissionId: Schema.String,
  inputSHA256: SHA256,
  providerId: AssemblyAIJobId,
  responseBodyComplete: Schema.Boolean,
});
const readJob = Effect.fn("AssemblyAI.readJob")(function* (
  env: TranscriptionEnvironment,
  submissionId: string,
) {
  const [job] = yield* transcriptionRows(
    env.CATALOG,
    JobRow,
    "SELECT * FROM trigo_assemblyai_jobs WHERE submission_id=?",
    [submissionId],
  );
  if (!job) {
    return yield* transcriptionError("asr_submission_uncertain", "retryable", 503);
  }
  return job;
});
const provider = (env: TranscriptionEnvironment) =>
  env.ASSEMBLYAI
    ? Effect.succeed(env.ASSEMBLYAI)
    : Effect.fail(transcriptionError("asr_configuration"));

const rememberAdmission = Effect.fn("AssemblyAI.rememberAdmission")(function* (
  env: TranscriptionEnvironment,
  submissionId: string,
  providerId: string,
) {
  // Preserve a known external identity even if the owner/deletion fence changed during HTTP.
  // This records cleanup/recovery responsibility; it never publishes or admits another request.
  yield* executeTranscriptionSQL(
    env.CATALOG,
    "UPDATE trigo_assemblyai_jobs SET phase='submitted',provider_id=? WHERE submission_id=? AND phase IN ('submitting','submitted') AND (provider_id IS NULL OR provider_id=?)",
    [providerId, submissionId, providerId],
  );
  if ((yield* readJob(env, submissionId)).provider_id !== providerId) {
    return yield* transcriptionError("asr_result_invalid");
  }
});

/** Upload and paid admission have separate durable transitions. An admitted submission may
 * resume an uploaded-but-not-submitted job; submitting is never POSTed a second time. */
export const submitAssemblyAISubmission = Effect.fn("AssemblyAI.submitInterval")(function* (
  env: TranscriptionEnvironment,
  operation: TranscriptionRow,
  attempt: Attempt,
  submission: SubmissionRow,
) {
  yield* requireCurrentAttempt(env.CATALOG, attempt.attempt_id);
  if (submission.attempt_id !== attempt.attempt_id || submission.state === "retained") {
    return;
  }
  const client = yield* provider(env);
  const extraction = yield* decodeExtraction(submission);
  const executionId = yield* newTranscriptionIdentity();
  if (submission.state === "planned") {
    yield* admitRawWriter(env, operation, attempt, submission);
    yield* executeTranscriptionSQL(
      env.CATALOG,
      "INSERT OR IGNORE INTO trigo_assemblyai_jobs(submission_id,phase) VALUES (?,'uploading')",
      [submission.submission_id],
    );
  }
  let job = yield* readJob(env, submission.submission_id);
  if (job.phase === "uploading") {
    // Upload has no transcription admission. A crash may lose its URL, so a replay can
    // upload again. Only the latest upload claim may attach a URL to the paid-admission row.
    const claim = yield* executeTranscriptionSQL(
      env.CATALOG,
      `UPDATE trigo_asr_submissions SET state='admitted',execution_id=? WHERE submission_id=? AND state IN ('planned','admitted')
       AND EXISTS (SELECT 1 FROM trigo_assemblyai_jobs j WHERE j.submission_id=trigo_asr_submissions.submission_id AND j.phase='uploading')
       AND EXISTS (SELECT 1 FROM trigo_transcription_attempts a WHERE a.attempt_id=trigo_asr_submissions.attempt_id AND a.state='admitted' AND ${currentAttemptFence})`,
      [executionId, submission.submission_id],
    );
    if (claim.meta.changes !== 1) {
      return;
    }
    const context = yield* loadTranscriptionMaster(env, operation);
    if (context.master === null) {
      return yield* transcriptionError("asr_input_rejected");
    }
    const actual = yield* extractMasterWave(
      r2MasterSource(env.ARCHIVE, context.objectKey, context.master),
      context.master,
      extraction.interval,
    ).pipe(Effect.mapError(() => transcriptionError("asr_input_rejected")));
    const body = yield* Stream.toReadableStreamEffect(actual.stream, {
      strategy: { highWaterMark: 0 },
    });
    const uploadURL = yield* client.upload(body, actual.byteLength);
    const produced = yield* actual
      .evidence()
      .pipe(Effect.mapError(() => transcriptionError("asr_input_rejected")));
    if (!Schema.toEquivalence(AsrExtractionEvidence)(produced, extraction)) {
      return yield* transcriptionError("asr_input_rejected");
    }
    const witness = AssemblyAIUploadWitness.make({
      deliveryWitness: "http-upload-ack-v1",
      uploadURL,
      uploadedByteLength: produced.byteLength,
      inputSHA256: produced.sha256,
      uploadHttpStatus: 200,
    });
    const attached = yield* executeTranscriptionSQL(
      env.CATALOG,
      `UPDATE trigo_assemblyai_jobs SET phase='uploaded',upload_url=?,upload_witness=? WHERE submission_id=? AND phase='uploading'
       AND EXISTS (SELECT 1 FROM trigo_asr_submissions s WHERE s.submission_id=trigo_assemblyai_jobs.submission_id AND s.execution_id=?)`,
      [uploadURL, yield* transcriptionJSON(witness), submission.submission_id, executionId],
    );
    if (attached.meta.changes !== 1) {
      return;
    }
    job = yield* readJob(env, submission.submission_id);
  }
  if (job.phase !== "uploaded" || job.upload_url === null) {
    return;
  }
  const admitted = yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_assemblyai_jobs SET phase='submitting' WHERE submission_id=? AND phase='uploaded'
     AND EXISTS (SELECT 1 FROM trigo_transcription_attempts a WHERE a.attempt_id=? AND a.state='admitted' AND ${currentAttemptFence})`,
    [submission.submission_id, attempt.attempt_id],
  );
  if (admitted.meta.changes !== 1) {
    return;
  }
  const submitted = yield* client
    .submit(job.upload_url, operation.requested_language)
    .pipe(Effect.result);
  if (submitted._tag === "Failure") {
    const failure = submitted.failure;
    if (failure.code !== "asr_admission_uncertain" && failure.code !== "asr_result_invalid") {
      yield* executeTranscriptionSQL(
        env.CATALOG,
        "UPDATE trigo_assemblyai_jobs SET phase='rejected',failure_code=?,failure_retry=? WHERE submission_id=? AND phase='submitting'",
        [
          failure.code === "asr_provider_unavailable" ? "asr_provider_failed" : failure.code,
          failure.retry,
          submission.submission_id,
        ],
      );
    }
    return yield* failure;
  }
  yield* rememberAdmission(env, submission.submission_id, submitted.success.id);
});

/** Retained bytes are authoritative. Polling can recover a provider ID or result, but has
 * no paid POST capability. Failed-normalization recovery passes allowProvider=false. */
export const recoverAssemblyAISubmission = Effect.fn("AssemblyAI.recoverInterval")(function* (
  env: TranscriptionEnvironment,
  operation: TranscriptionRow,
  submission: SubmissionRow,
  allowProvider: boolean,
): Effect.fn.Return<
  AssemblyAIMasterSubmission,
  import("./transcription-errors.ts").TranscriptionError
> {
  if (submission.state === "planned" && allowProvider) {
    const [attempt] = yield* transcriptionRows(
      env.CATALOG,
      AttemptRow,
      "SELECT * FROM trigo_transcription_attempts WHERE attempt_id=?",
      [submission.attempt_id],
    );
    if (
      attempt?.failure_code &&
      !["asr_provider_processing", "asr_provider_unavailable"].includes(attempt.failure_code)
    ) {
      return yield* transcriptionError(
        attempt.failure_code,
        attempt.failure_retry ?? "after_correction",
      );
    }
    return yield* transcriptionError("asr_provider_processing", "retryable", 503);
  }
  const extraction = yield* decodeExtraction(submission);
  let job = yield* readJob(env, submission.submission_id);
  const [writer] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE object_key=? AND attempt_id=? AND kind='raw'",
    [submission.raw_key, submission.attempt_id],
  );
  if (!writer) {
    return yield* transcriptionError("asr_submission_uncertain", "retryable", 503);
  }
  let raw = yield* transcriptionStorage(() => env.ARCHIVE.get(submission.raw_key));
  if (!raw || !("body" in raw)) {
    if (writer.sha256 !== null) {
      return yield* transcriptionError("asr_storage_unavailable", "retryable", 503);
    }
    if (!allowProvider) {
      return yield* transcriptionError("asr_result_invalid");
    }
    if (job.phase === "rejected") {
      return yield* transcriptionError(
        job.failure_code ?? "asr_provider_failed",
        job.failure_retry ?? "after_correction",
      );
    }
    if (job.phase === "uploading") {
      const [attempt] = yield* transcriptionRows(
        env.CATALOG,
        AttemptRow,
        "SELECT * FROM trigo_transcription_attempts WHERE attempt_id=?",
        [submission.attempt_id],
      );
      if (attempt?.failure_code) {
        return yield* transcriptionError(
          attempt.failure_code === "asr_provider_unavailable"
            ? "asr_provider_failed"
            : attempt.failure_code,
          attempt.failure_retry ?? "after_correction",
        );
      }
      return yield* transcriptionError("asr_provider_processing", "retryable", 503);
    }
    if (job.upload_url === null || job.upload_witness === null) {
      return yield* transcriptionError("asr_catalog_invalid");
    }
    if (job.phase === "uploaded") {
      return yield* transcriptionError("asr_provider_processing", "retryable", 503);
    }
    yield* requireCurrentAttempt(env.CATALOG, submission.attempt_id);
    const client = yield* provider(env);
    if (job.provider_id === null) {
      const recoveredId = yield* client.find(job.upload_url);
      if (recoveredId === null) {
        return yield* transcriptionError("asr_provider_processing", "retryable", 503);
      }
      yield* rememberAdmission(env, submission.submission_id, recoveredId);
      job = yield* readJob(env, submission.submission_id);
    }
    if (job.provider_id === null) {
      return yield* transcriptionError("asr_admission_uncertain");
    }
    const response = yield* client.get(job.provider_id);
    const status = yield* decodeAssemblyAIJSON(response.bytes).pipe(
      Effect.flatMap(Schema.decodeUnknownEffect(AssemblyAIJob)),
      Effect.result,
    );
    if (
      response.complete &&
      status._tag === "Success" &&
      status.success.id === job.provider_id &&
      status.success.audio_url === job.upload_url &&
      status.success.is_deleted !== true &&
      (status.success.status === "queued" || status.success.status === "processing")
    ) {
      return yield* transcriptionError("asr_provider_processing", "retryable", 503);
    }
    yield* storeRawResponse(env, writer, response.bytes, {
      trigo: yield* transcriptionJSON({
        schemaVersion: 1,
        submissionId: submission.submission_id,
        inputSHA256: extraction.sha256,
        providerId: job.provider_id,
        responseBodyComplete: response.complete,
      }),
    });
    yield* executeTranscriptionSQL(
      env.CATALOG,
      "UPDATE trigo_assemblyai_jobs SET cleanup_state='pending' WHERE submission_id=? AND cleanup_state='not_ready'",
      [submission.submission_id],
    );
    raw = yield* transcriptionStorage(() => env.ARCHIVE.get(submission.raw_key));
  }
  const [retainedWriter] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE writer_id=?",
    [writer.writer_id],
  );
  if (
    !raw ||
    !("body" in raw) ||
    !retainedWriter ||
    retainedWriter.sha256 === null ||
    retainedWriter.byte_length === null
  ) {
    return yield* transcriptionError("asr_storage_unavailable", "retryable", 503);
  }
  if (
    !objectMatches(raw, {
      object_key: submission.raw_key,
      sha256: retainedWriter.sha256,
      byte_length: retainedWriter.byte_length,
    }) ||
    raw.size > assemblyAIStereoProfile.maxRawResponseBytes
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const bytes = yield* readBoundedBody(raw.body, assemblyAIStereoProfile.maxRawResponseBytes).pipe(
    Effect.mapError(() => transcriptionError("asr_storage_unavailable", "retryable", 503)),
  );
  if ((yield* Effect.promise(() => storedByteHash(bytes))) !== retainedWriter.sha256) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const metadata = yield* Schema.decodeUnknownEffect(Schema.fromJsonString(RawMetadata))(
    raw.customMetadata?.trigo,
  ).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid")));
  if (!metadata.responseBodyComplete) {
    return yield* transcriptionError(
      bytes.byteLength === assemblyAIStereoProfile.maxRawResponseBytes
        ? "asr_result_too_large"
        : "asr_result_invalid",
    );
  }
  if (
    metadata.submissionId !== submission.submission_id ||
    metadata.inputSHA256 !== extraction.sha256 ||
    metadata.providerId !== job.provider_id ||
    job.upload_witness === null ||
    job.upload_url === null
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const transport = yield* Schema.decodeEffect(Schema.fromJsonString(AssemblyAIUploadWitness))(
    job.upload_witness,
  ).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid")));
  if (
    transport.uploadURL !== job.upload_url ||
    transport.inputSHA256 !== extraction.sha256 ||
    transport.uploadedByteLength !== extraction.byteLength
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const response = yield* decodeAssemblyAIJSON(bytes);
  const status = yield* Schema.decodeUnknownEffect(AssemblyAIJob)(response).pipe(
    Effect.mapError(() => transcriptionError("asr_result_invalid")),
  );
  if (
    status.id !== job.provider_id ||
    status.audio_url !== job.upload_url ||
    status.is_deleted === true
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  if (status.status === "error") {
    return yield* transcriptionError("asr_provider_failed", "retryable", 503);
  }
  yield* inspectAssemblyAIResult(bytes, extraction, {
    providerId: metadata.providerId,
    uploadURL: job.upload_url,
    language: operation.requested_language,
  });
  yield* reconcileTranscriptionWriter(env, retainedWriter);
  yield* executeTranscriptionSQL(
    env.CATALOG,
    "UPDATE trigo_asr_submissions SET state='retained',raw_sha256=?,raw_byte_length=?,transport=?,provider_request_id=?,valid=1 WHERE submission_id=? AND state IN ('admitted','retained')",
    [
      retainedWriter.sha256,
      bytes.byteLength,
      yield* transcriptionJSON(transport),
      metadata.providerId,
      submission.submission_id,
    ],
  );
  return {
    extraction,
    rawArtifactKey: submission.raw_key,
    rawBytes: bytes,
    providerRequestId: metadata.providerId,
    transport,
  };
});

/** Delete this operation's known jobs after retaining the complete/diagnostic response, or
 * after its owner/deletion fence cancels processing. Failed DELETE remains safe to retry. */
export const cleanupAssemblyAIResults = Effect.fn("AssemblyAI.cleanupResults")(function* (
  env: TranscriptionEnvironment,
  operationId: string,
) {
  const jobs = yield* transcriptionRows(
    env.CATALOG,
    JobRow,
    `SELECT j.* FROM trigo_assemblyai_jobs j JOIN trigo_asr_submissions s USING (submission_id)
     JOIN trigo_transcription_attempts a USING (attempt_id)
     WHERE a.operation_id=? AND j.provider_id IS NOT NULL AND j.cleanup_state!='deleted'
     AND (EXISTS (SELECT 1 FROM trigo_transcription_writers w WHERE w.object_key=s.raw_key AND w.state='stored')
       OR EXISTS (SELECT 1 FROM trigo_transcription_operations o WHERE o.operation_id=a.operation_id AND o.state='failed'
         AND o.failure_code IN ('asr_owner_changed','asr_superseded','call_deleted')))`,
    [operationId],
  );
  if (jobs.length === 0) {
    return;
  }
  const client = yield* provider(env);
  for (const job of jobs) {
    if (job.provider_id === null) {
      continue;
    }
    yield* client.delete(job.provider_id);
    yield* executeTranscriptionSQL(
      env.CATALOG,
      "UPDATE trigo_assemblyai_jobs SET cleanup_state='deleted' WHERE submission_id=? AND provider_id=?",
      [job.submission_id, job.provider_id],
    );
  }
});
