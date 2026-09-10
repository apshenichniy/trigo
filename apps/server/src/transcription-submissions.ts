// oxlint-disable-next-line effecttsgo/node-builtin-import -- Deterministic evidence IDs make normalization replay byte-identical without storing transcript contents in D1.
import { createHash } from "node:crypto";

import { Effect, Schema, Stream } from "effect";

import { ExchangeUUID, SHA256, storedByteHash } from "@trigo/contracts";

import {
  assemblyAIStereoProfile,
  nova3StreamProfile,
} from "../../../packages/contracts/src/asr-profile.ts";
import {
  AsrExtractionEvidence,
  AsrMaster,
  extractMasterWave,
  planMasterSubmissions,
  r2MasterSource,
} from "./asr-master.ts";
import { type Nova3Runner } from "./asr-probe.ts";
import { type AssemblyAIMasterSubmission } from "./assemblyai-normalization.ts";
import {
  recoverAssemblyAISubmission,
  submitAssemblyAISubmission,
} from "./assemblyai-submissions.ts";
import {
  inspectNova3IntervalMetadata,
  Nova3SubmissionTransport,
  type Nova3MasterSubmission,
} from "./nova-3-master.ts";
import { readBoundedBody, submitNova3Stream } from "./nova-3-transport.ts";
import { normalizeNova3 } from "./nova-3.ts";
import {
  currentAttemptFence,
  executeTranscriptionSQL,
  newTranscriptionIdentity,
  requireCurrentAttempt,
  SubmissionRow,
  transcriptionRows,
  TranscriptionWriterRow,
  type AttemptRow,
  type TranscriptionRow,
} from "./transcription-catalog.ts";
import {
  transcriptionError,
  transcriptionJSON,
  transcriptionStorage,
} from "./transcription-errors.ts";
import {
  admitRawWriter,
  reconcileTranscriptionWriter,
  storeRawResponse,
} from "./transcription-writers.ts";
import { requireStoredMaster, type TranscriptionEnvironment } from "./transcriptions.ts";
import { objectMatches } from "./upload-streams.ts";

export interface TranscriptionExecutionEnvironment extends TranscriptionEnvironment {
  readonly AI: Nova3Runner;
  readonly TRANSCRIPTION_MODE: "hosted" | "fake";
}

export function deterministicTranscriptionIDs(seed: string) {
  let ordinal = 0;
  return () => {
    const bytes = createHash("sha256")
      .update(`trigo/normalization/v1/${seed}/${ordinal++}`)
      .digest();
    bytes[6] = ((bytes[6] ?? 0) & 15) | 64;
    bytes[8] = ((bytes[8] ?? 0) & 63) | 128;
    const hex = Array.from(bytes.subarray(0, 16), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  };
}

export const loadTranscriptionMaster = Effect.fn("Transcription.loadMaster")(function* (
  env: TranscriptionEnvironment,
  operation: TranscriptionRow,
) {
  const stored = yield* requireStoredMaster(env, operation.archive_id, operation.call_id);
  const manifestHash = yield* Effect.promise(() =>
    storedByteHash(new TextEncoder().encode(stored.audioManifest)),
  );
  if (manifestHash !== stored.receipt.audioManifest.sha256) {
    return yield* transcriptionError("asr_catalog_invalid", "after_correction", 503);
  }
  if (stored.receipt.durationMs === 0) {
    return { ...stored, master: null };
  }
  const master = yield* Schema.decodeUnknownEffect(AsrMaster)({
    callId: stored.receipt.callId,
    masterId: stored.receipt.masterId,
    manifestId: stored.receipt.audioManifest.manifestId,
    manifestSha256: stored.receipt.audioManifest.sha256,
    sha256: stored.receipt.masterSHA256,
    frameCount: stored.receipt.durationMs * 16,
    byteLength: stored.receipt.byteLength,
    mediaProfileId: stored.receipt.mediaProfileId,
    microphoneTrackId: stored.receipt.channelMap.find((channel) => channel.channelIndex === 0)
      ?.trackId,
    applicationTrackId: stored.receipt.channelMap.find((channel) => channel.channelIndex === 1)
      ?.trackId,
  }).pipe(Effect.mapError(() => transcriptionError("asr_input_rejected")));
  return { ...stored, master };
});

export const attemptSubmissions = (env: TranscriptionEnvironment, attemptId: string) =>
  transcriptionRows(
    env.CATALOG,
    SubmissionRow,
    `SELECT s.* FROM trigo_asr_submissions s JOIN trigo_transcription_attempt_submissions p USING (submission_id)
     WHERE p.attempt_id=? ORDER BY p.interval_index`,
    [attemptId],
  );

const linkSubmission = (
  env: TranscriptionEnvironment,
  attempt: AttemptRow,
  submission: SubmissionRow,
) =>
  executeTranscriptionSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_transcription_attempt_submissions (attempt_id,interval_index,submission_id)
     SELECT ?,?,? FROM trigo_transcription_attempts a WHERE a.attempt_id=? AND ${currentAttemptFence}`,
    [attempt.attempt_id, submission.interval_index, submission.submission_id, attempt.attempt_id],
  );

export const prepareAttemptSubmissions = Effect.fn("Transcription.prepareSubmissions")(function* (
  env: TranscriptionEnvironment,
  operation: TranscriptionRow,
  attempt: AttemptRow,
) {
  yield* requireCurrentAttempt(env.CATALOG, attempt.attempt_id);
  const context = yield* loadTranscriptionMaster(env, operation);
  if (context.master === null) {
    return;
  }
  const ids = [yield* newTranscriptionIdentity(), yield* newTranscriptionIdentity()];
  let identityIndex = 0;
  const plan = yield* planMasterSubmissions(
    context.master,
    nova3StreamProfile.maxSubmissionDurationMs,
    () => ids[identityIndex++] ?? "invalid",
  ).pipe(Effect.mapError(() => transcriptionError("asr_input_rejected")));
  for (const interval of plan) {
    const current = yield* attemptSubmissions(env, attempt.attempt_id);
    if (current.some((submission) => submission.interval_index === interval.index)) {
      continue;
    }
    if (attempt.attempt_index === 1) {
      const [retained] = yield* transcriptionRows(
        env.CATALOG,
        SubmissionRow,
        `SELECT s.* FROM trigo_asr_submissions s JOIN trigo_transcription_attempts a USING (attempt_id)
         WHERE a.operation_id=? AND a.attempt_index=0 AND s.interval_index=? AND s.valid=1`,
        [operation.operation_id, interval.index],
      );
      if (retained) {
        yield* linkSubmission(env, attempt, retained);
        continue;
      }
    }
    let [submission] = yield* transcriptionRows(
      env.CATALOG,
      SubmissionRow,
      "SELECT * FROM trigo_asr_submissions WHERE attempt_id=? AND interval_index=?",
      [attempt.attempt_id, interval.index],
    );
    if (!submission) {
      const source = r2MasterSource(env.ARCHIVE, context.objectKey, context.master);
      const extraction = yield* extractMasterWave(source, context.master, interval).pipe(
        Effect.mapError(() => transcriptionError("asr_input_rejected")),
      );
      yield* Stream.runDrain(extraction.stream).pipe(
        Effect.mapError(() => transcriptionError("asr_storage_unavailable", "retryable", 503)),
      );
      const evidence = yield* extraction
        .evidence()
        .pipe(Effect.mapError(() => transcriptionError("asr_input_rejected")));
      const encoded = yield* transcriptionJSON(evidence);
      const key = `archives/${operation.archive_id}/calls/${operation.call_id}/transcriptions/${operation.revision_id}/raw/${interval.submissionId}.json`;
      yield* executeTranscriptionSQL(
        env.CATALOG,
        `INSERT OR IGNORE INTO trigo_asr_submissions
         (submission_id,attempt_id,interval_index,start_frame,end_frame,extraction,state,raw_key)
         SELECT ?,?,?,?,?,?,'planned',? FROM trigo_transcription_attempts a
         WHERE a.attempt_id=? AND ${currentAttemptFence}`,
        [
          interval.submissionId,
          attempt.attempt_id,
          interval.index,
          interval.startFrame,
          interval.endFrame,
          encoded,
          key,
          attempt.attempt_id,
        ],
      );
      [submission] = yield* transcriptionRows(
        env.CATALOG,
        SubmissionRow,
        "SELECT * FROM trigo_asr_submissions WHERE attempt_id=? AND interval_index=?",
        [attempt.attempt_id, interval.index],
      );
    }
    if (!submission) {
      return yield* transcriptionError("asr_superseded", "never", 409);
    }
    yield* linkSubmission(env, attempt, submission);
  }
});

const RawMetadata = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  submissionId: ExchangeUUID,
  inputSHA256: SHA256,
  fullyConsumed: Schema.Boolean,
  responseBodyComplete: Schema.Boolean,
  responseTruncated: Schema.Boolean,
  httpStatus: Schema.Int,
  deliveredByteLength: Schema.Int,
  providerRequestId: Schema.NullOr(Schema.String.check(Schema.isMaxLength(512))),
});

export const decodeExtraction = (submission: SubmissionRow) =>
  Schema.decodeEffect(Schema.fromJsonString(AsrExtractionEvidence))(submission.extraction).pipe(
    Effect.mapError(() => transcriptionError("asr_catalog_invalid", "after_correction", 503)),
  );

export const submitAdmittedInterval = Effect.fn("Transcription.submitInterval")(function* (
  env: TranscriptionExecutionEnvironment,
  operation: TranscriptionRow,
  attempt: AttemptRow,
  submission: SubmissionRow,
) {
  if (env.TRANSCRIPTION_MODE === "hosted" && operation.profile_id === assemblyAIStereoProfile.id) {
    return yield* submitAssemblyAISubmission(env, operation, attempt, submission);
  }
  yield* requireCurrentAttempt(env.CATALOG, attempt.attempt_id);
  if (submission.state !== "planned" || submission.attempt_id !== attempt.attempt_id) {
    return;
  }
  const context = yield* loadTranscriptionMaster(env, operation);
  if (context.master === null) {
    return yield* transcriptionError("asr_input_rejected");
  }
  const extraction = yield* decodeExtraction(submission);
  const rawWriter = yield* admitRawWriter(env, operation, attempt, submission);
  const executionId = yield* newTranscriptionIdentity();
  const claimed = yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_asr_submissions SET state='admitted',execution_id=?
     WHERE submission_id=? AND state='planned' AND EXISTS (
       SELECT 1 FROM trigo_transcription_attempts a WHERE a.attempt_id=trigo_asr_submissions.attempt_id
       AND a.state='admitted' AND ${currentAttemptFence})`,
    [executionId, submission.submission_id],
  );
  if (claimed.meta.changes !== 1) {
    return;
  }
  // This durable state transition is the only authority for the paid side effect. No retry
  // wrapper surrounds AI.run. A replay can only inspect this submission's retained raw key.
  const actual = yield* extractMasterWave(
    r2MasterSource(env.ARCHIVE, context.objectKey, context.master),
    context.master,
    extraction.interval,
  ).pipe(Effect.mapError(() => transcriptionError("asr_input_rejected")));
  const body = yield* Stream.toReadableStreamEffect(actual.stream, {
    strategy: { highWaterMark: 0 },
  });
  const response = yield* submitNova3Stream(
    env.AI,
    body,
    "audio/wav",
    operation.requested_language,
    actual.byteLength,
  ).pipe(Effect.mapError(() => transcriptionError("asr_submission_uncertain", "retryable", 503)));
  const produced = yield* actual.evidence().pipe(Effect.result);
  if (response.requestId.length > 512) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const metadata = yield* transcriptionJSON(
    RawMetadata.make({
      schemaVersion: 1,
      submissionId: submission.submission_id,
      inputSHA256: extraction.sha256,
      fullyConsumed:
        response.requestBody.complete &&
        produced._tag === "Success" &&
        Schema.toEquivalence(AsrExtractionEvidence)(produced.success, extraction),
      responseBodyComplete: response.responseBodyComplete,
      responseTruncated:
        !response.responseBodyComplete &&
        response.bytes.byteLength === nova3StreamProfile.maxRawResponseBytes,
      httpStatus: response.status,
      deliveredByteLength: response.requestBody.byteLength,
      providerRequestId: response.requestId || null,
    }),
  );
  yield* storeRawResponse(env, rawWriter, response.bytes, { trigo: metadata });
});

const validateProviderInterval = Effect.fn("Transcription.validateInterval")(function* (
  operation: TranscriptionRow,
  extraction: AsrExtractionEvidence,
  raw: Uint8Array,
  providerRequestId: string | null,
) {
  const text = yield* Effect.try({
    try: () => new TextDecoder("utf-8", { fatal: true }).decode(raw),
    catch: () => transcriptionError("asr_result_invalid"),
  });
  const response = yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(text).pipe(
    Effect.mapError(() => transcriptionError("asr_result_invalid")),
  );
  yield* inspectNova3IntervalMetadata(
    response,
    extraction.interval.endFrame - extraction.interval.startFrame,
  ).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid")));
  // Validate timing and both channels in this interval's own clock before paying to replace
  // another interval. The final normalization preserves the full master time offsets.
  yield* normalizeNova3({
    callId: operation.call_id,
    revisionId: operation.revision_id,
    createdAt: operation.created_at,
    audioManifest: {
      manifestId: extraction.master.manifestId,
      sha256: extraction.master.manifestSha256,
    },
    requestedLanguage: operation.requested_language,
    detectedLanguages: [],
    tracks: [
      { trackId: extraction.master.microphoneTrackId, role: "microphone" },
      { trackId: extraction.master.applicationTrackId, role: "application" },
    ],
    objects: [
      {
        objectId: extraction.interval.submissionId,
        index: 0,
        startMs: 0,
        endMs: extraction.endMs - extraction.startMs,
        channelMap: [
          { channelIndex: 0, trackId: extraction.master.microphoneTrackId },
          { channelIndex: 1, trackId: extraction.master.applicationTrackId },
        ],
        providerRequestId,
        response,
      },
    ],
    makeId: deterministicTranscriptionIDs(
      `${operation.revision_id}/validate/${extraction.interval.submissionId}`,
    ),
  }).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid")));
});

export const recoverSubmission = Effect.fn("Transcription.recoverSubmission")(function* (
  env: TranscriptionEnvironment,
  operation: TranscriptionRow,
  submission: SubmissionRow,
  allowProvider = true,
): Effect.fn.Return<
  Nova3MasterSubmission | AssemblyAIMasterSubmission,
  import("./transcription-errors.ts").TranscriptionError
> {
  if (env.TRANSCRIPTION_MODE === "hosted" && operation.profile_id === assemblyAIStereoProfile.id) {
    return yield* recoverAssemblyAISubmission(env, operation, submission, allowProvider);
  }
  const extraction = yield* decodeExtraction(submission);
  const [writer] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionWriterRow,
    "SELECT * FROM trigo_transcription_writers WHERE object_key=? AND kind='raw' AND attempt_id=?",
    [submission.raw_key, submission.attempt_id],
  );
  const raw = yield* transcriptionStorage(() => env.ARCHIVE.get(submission.raw_key));
  if (
    !raw ||
    !("body" in raw) ||
    !writer ||
    writer.sha256 === null ||
    writer.byte_length === null
  ) {
    return yield* transcriptionError("asr_submission_uncertain", "retryable", 503);
  }
  if (
    !objectMatches(raw, {
      object_key: writer.object_key,
      sha256: writer.sha256,
      byte_length: writer.byte_length,
    }) ||
    raw.size > nova3StreamProfile.maxRawResponseBytes
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const bytes = yield* readBoundedBody(raw.body, nova3StreamProfile.maxRawResponseBytes).pipe(
    Effect.mapError(() => transcriptionError("asr_storage_unavailable", "retryable", 503)),
  );
  if ((yield* Effect.promise(() => storedByteHash(bytes))) !== writer.sha256) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const metadata = yield* Schema.decodeUnknownEffect(Schema.fromJsonString(RawMetadata))(
    raw.customMetadata?.trigo,
  ).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid")));
  if (
    metadata.submissionId !== submission.submission_id ||
    metadata.inputSHA256 !== extraction.sha256
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  yield* reconcileTranscriptionWriter(env, writer);
  if (metadata.httpStatus === 401 || metadata.httpStatus === 403) {
    return yield* transcriptionError("asr_configuration");
  }
  if (metadata.httpStatus === 402) {
    return yield* transcriptionError("asr_funds");
  }
  if ([400, 413, 415, 422].includes(metadata.httpStatus)) {
    return yield* transcriptionError("asr_input_rejected");
  }
  if (metadata.responseTruncated) {
    return yield* transcriptionError("asr_result_too_large");
  }
  if (
    metadata.httpStatus !== 200 ||
    !metadata.responseBodyComplete ||
    !metadata.fullyConsumed ||
    metadata.deliveredByteLength !== extraction.byteLength
  ) {
    return yield* transcriptionError("asr_submission_uncertain", "retryable", 503);
  }
  yield* validateProviderInterval(operation, extraction, bytes, metadata.providerRequestId);
  const transport = Nova3SubmissionTransport.make({
    deliveryWitness: "consumer-eof-v1",
    deliveredByteLength: metadata.deliveredByteLength,
    responseBodyComplete: metadata.responseBodyComplete,
    providerHttpStatus: metadata.httpStatus,
  });
  const encodedTransport = yield* transcriptionJSON(transport);
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_asr_submissions SET state='retained',raw_sha256=?,raw_byte_length=?,transport=?,provider_request_id=?,valid=1
     WHERE submission_id=? AND state IN ('admitted','retained')`,
    [
      writer.sha256,
      bytes.byteLength,
      encodedTransport,
      metadata.providerRequestId,
      submission.submission_id,
    ],
  );
  return {
    extraction,
    rawArtifactKey: submission.raw_key,
    rawBytes: bytes,
    providerRequestId: metadata.providerRequestId,
    transport,
  };
});
