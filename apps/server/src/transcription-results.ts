import { Effect } from "effect";

import { TranscriptRevision, validateDocument, type VerifiedMasterReceipt } from "@trigo/contracts";

import {
  assemblyAIStereoProfile,
  nova3StreamProfile,
} from "../../../packages/contracts/src/asr-profile.ts";
import {
  normalizeAssemblyAIMaster,
  type AssemblyAIMasterSubmission,
} from "./assemblyai-normalization.ts";
import { normalizeNova3Master, type Nova3MasterSubmission } from "./nova-3-master.ts";
import {
  AttemptRow,
  currentTranscriptionFence,
  executeTranscriptionSQL,
  readTranscription,
  requireCurrentAttempt,
  resultAttemptFence,
  resultOperationStateFence,
  transcriptionRows,
  transcriptionTimestamp,
  type TranscriptionRow,
  type TranscriptionResultRecovery,
} from "./transcription-catalog.ts";
import { transcriptionError, transcriptionJSON } from "./transcription-errors.ts";
import {
  attemptSubmissions,
  deterministicTranscriptionIDs,
  loadTranscriptionMaster,
  recoverSubmission,
} from "./transcription-submissions.ts";
import { storeTranscriptionArtifact } from "./transcription-writers.ts";
import {
  maximumProvenanceBytes,
  maximumRevisionBytes,
  type TranscriptionEnvironment,
} from "./transcriptions.ts";

function emptyMasterResult(operation: TranscriptionRow, receipt: VerifiedMasterReceipt) {
  return {
    revision: TranscriptRevision.make({
      schemaVersion: 1,
      callId: operation.call_id,
      revisionId: operation.revision_id,
      createdAt: operation.created_at,
      audioManifest: receipt.audioManifest,
      normalizationVersion: 1,
      asr: {
        adapter: "none",
        model: "no-audio",
        profileId: operation.profile_id,
        requestedLanguage: operation.requested_language,
        detectedLanguages: [],
        effectiveOptions: { reason: "zero-duration-master" },
        returnedModelVersion: null,
        providerRequestIds: [],
      },
      speakers: [],
      turns: [],
    }),
    provenance: {
      schemaVersion: 1,
      callId: operation.call_id,
      revisionId: operation.revision_id,
      profileId: operation.profile_id,
      evidenceKind: "zero-duration-master",
      providerInvoked: false,
      verifiedMaster: receipt,
      submissions: [],
    },
  };
}

const normalizeAttempt = Effect.fn("Transcription.normalizeAttempt")(function* (
  env: TranscriptionEnvironment,
  operation: TranscriptionRow,
  attempt: AttemptRow,
  recovery: TranscriptionResultRecovery,
) {
  const context = yield* loadTranscriptionMaster(env, operation);
  if (context.master === null) {
    return emptyMasterResult(operation, context.receipt);
  }
  const planned = yield* attemptSubmissions(env, attempt.attempt_id);
  const expected = Math.ceil(
    context.receipt.durationMs / nova3StreamProfile.maxSubmissionDurationMs,
  );
  if (planned.length !== expected) {
    return yield* transcriptionError("asr_submission_uncertain", "retryable", 503);
  }
  const retained: (Nova3MasterSubmission | AssemblyAIMasterSubmission)[] = [];
  let rawBytes = 0;
  // Recovery visits every interval before considering a replacement; successful intervals
  // retain their independent scope even when a sibling has an uncertain outcome.
  const failures = [];
  for (const submission of planned) {
    const recovered = yield* recoverSubmission(
      env,
      operation,
      submission,
      recovery === "active",
    ).pipe(Effect.result);
    if (recovered._tag === "Failure") {
      failures.push(recovered.failure);
      continue;
    }
    rawBytes += recovered.success.rawBytes.byteLength;
    if (rawBytes > 2 * nova3StreamProfile.maxRawResponseBytes) {
      return yield* transcriptionError("asr_result_too_large");
    }
    retained.push(recovered.success);
  }
  const failure = failures.find((error) => error.retry !== "retryable") ?? failures[0];
  if (failure !== undefined) {
    return yield* failure;
  }
  const normalizationInput = {
    master: context.master,
    revisionId: operation.revision_id,
    createdAt: operation.created_at,
    requestedLanguage: operation.requested_language,
    submissions: retained,
    makeId: deterministicTranscriptionIDs(operation.revision_id),
  };
  const normalized = yield* env.TRANSCRIPTION_MODE === "hosted" &&
  operation.profile_id === assemblyAIStereoProfile.id
    ? normalizeAssemblyAIMaster(normalizationInput)
    : normalizeNova3Master(normalizationInput).pipe(
        Effect.mapError(() => transcriptionError("asr_result_invalid")),
      );
  const revision =
    env.TRANSCRIPTION_MODE === "fake"
      ? {
          ...normalized.revision,
          asr: {
            ...normalized.revision.asr,
            adapter: "fake",
            model: "no-speech",
            profileId: operation.profile_id,
            effectiveOptions: { fixture: "offline-product-workflow" },
          },
        }
      : normalized.revision;
  return {
    revision,
    provenance: {
      ...normalized.provenance,
      profileId: operation.profile_id,
      providerInvoked: env.TRANSCRIPTION_MODE === "hosted",
      sourceStatesSHA256: context.receipt.sourceStatesSHA256,
      masterReceiptId: context.receipt.receiptId,
    },
  };
});

/** Artifact durability precedes the one atomic available-result publication. It never changes
 * a canonical manifest, imports a local revision, or acknowledges replica synchronization. */
export const recoverAndPublishTranscription = Effect.fn("Transcription.recoverAndPublish")(
  function* (
    env: TranscriptionEnvironment,
    operationId: string,
    attempt: AttemptRow,
    recovery: TranscriptionResultRecovery = "active",
  ) {
    const operation = yield* readTranscription(env.CATALOG, operationId);
    yield* loadTranscriptionMaster(env, operation);
    if (operation.state === "result_available") {
      return operation;
    }
    yield* requireCurrentAttempt(env.CATALOG, attempt.attempt_id, recovery);
    const normalized = yield* normalizeAttempt(env, operation, attempt, recovery);
    const revision = yield* Effect.try({
      try: () => validateDocument("TranscriptRevision", normalized.revision),
      catch: () => transcriptionError("asr_result_invalid"),
    });
    const revisionBytes = new TextEncoder().encode(yield* transcriptionJSON(revision));
    const provenanceBytes = new TextEncoder().encode(
      yield* transcriptionJSON({
        ...normalized.provenance,
        archiveId: operation.archive_id,
        operationId: operation.operation_id,
        attemptId: attempt.attempt_id,
      }),
    );
    if (
      revisionBytes.byteLength > maximumRevisionBytes ||
      provenanceBytes.byteLength > maximumProvenanceBytes
    ) {
      return yield* transcriptionError("asr_result_too_large");
    }
    const provenance = yield* storeTranscriptionArtifact(
      env,
      operation,
      attempt,
      "provenance",
      provenanceBytes,
      recovery,
    );
    const result = yield* storeTranscriptionArtifact(
      env,
      operation,
      attempt,
      "revision",
      revisionBytes,
      recovery,
    );
    const now = yield* transcriptionTimestamp();
    yield* executeTranscriptionSQL(
      env.CATALOG,
      `UPDATE trigo_transcription_operations AS o SET state='result_available',updated_at=?,
     result_key=?,result_sha256=?,result_byte_length=?,provenance_key=?,provenance_sha256=?,provenance_byte_length=?,
     failure_code=NULL,failure_retry=NULL
     WHERE o.operation_id=? AND ${resultOperationStateFence(recovery)} AND ${currentTranscriptionFence}
     AND EXISTS (SELECT 1 FROM trigo_transcription_attempts a WHERE a.attempt_id=? AND a.operation_id=o.operation_id AND ${resultAttemptFence(recovery)})
     AND EXISTS (SELECT 1 FROM trigo_transcription_writers w WHERE w.writer_id=? AND w.operation_id=o.operation_id AND w.attempt_id=? AND w.kind='revision' AND w.state='stored')
     AND EXISTS (SELECT 1 FROM trigo_transcription_writers w WHERE w.writer_id=? AND w.operation_id=o.operation_id AND w.attempt_id=? AND w.kind='provenance' AND w.state='stored')`,
      [
        now,
        result.key,
        result.sha256,
        result.byteLength,
        provenance.key,
        provenance.sha256,
        provenance.byteLength,
        operationId,
        attempt.attempt_id,
        result.writerId,
        attempt.attempt_id,
        provenance.writerId,
        attempt.attempt_id,
      ],
    );
    const published = yield* readTranscription(env.CATALOG, operationId);
    if (
      published.state !== "result_available" ||
      published.result_sha256 !== result.sha256 ||
      published.provenance_sha256 !== provenance.sha256
    ) {
      return yield* transcriptionError("asr_superseded", "never", 409);
    }
    yield* executeTranscriptionSQL(
      env.CATALOG,
      "UPDATE trigo_transcription_attempts SET state='succeeded',failure_code=NULL,failure_retry=NULL WHERE attempt_id=?",
      [attempt.attempt_id],
    );
    return published;
  },
);

/** An explicit replay of the same failed initial command can repair normalization from
 * retained complete responses. This boundary has no provider runner capability. */
export const recoverFailedNormalization = Effect.fn("Transcription.recoverFailedNormalization")(
  function* (env: TranscriptionEnvironment, operationId: string) {
    const [attempt] = yield* transcriptionRows(
      env.CATALOG,
      AttemptRow,
      "SELECT * FROM trigo_transcription_attempts WHERE operation_id=? ORDER BY attempt_index DESC LIMIT 1",
      [operationId],
    );
    if (!attempt) {
      return yield* transcriptionError("asr_result_invalid");
    }
    return yield* recoverAndPublishTranscription(
      env,
      operationId,
      attempt,
      "retained-normalization",
    );
  },
);
