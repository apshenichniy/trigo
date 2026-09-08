import { Effect } from "effect";

import {
  AttemptRow,
  currentTranscriptionFence,
  executeTranscriptionSQL,
  newTranscriptionIdentity,
  readTranscription,
  transcriptionRows,
  transcriptionTimestamp,
} from "./transcription-catalog.ts";
import { type TranscriptionError, transcriptionError } from "./transcription-errors.ts";
import { recoverAndPublishTranscription } from "./transcription-results.ts";
import {
  attemptSubmissions,
  prepareAttemptSubmissions,
  recoverSubmission,
  submitAdmittedInterval,
  type TranscriptionExecutionEnvironment,
} from "./transcription-submissions.ts";
import { isCurrentTranscription } from "./transcriptions.ts";

export const admitTranscriptionAttempt = Effect.fn("Transcription.admitAttempt")(function* (
  env: TranscriptionExecutionEnvironment,
  operationId: string,
  index: 0 | 1,
) {
  const current = yield* isCurrentTranscription(env, operationId).pipe(Effect.result);
  if (current._tag === "Failure") {
    const failure = current.failure;
    if (!["asr_owner_changed", "asr_superseded", "call_deleted"].includes(failure.code)) {
      return yield* failure;
    }
    yield* executeTranscriptionSQL(
      env.CATALOG,
      `UPDATE trigo_transcription_operations SET state='failed',updated_at=?,failure_code=?,failure_retry=?
       WHERE operation_id=? AND state IN ('queued','running')`,
      [yield* transcriptionTimestamp(), failure.code, failure.retry, operationId],
    );
    return null;
  }
  const operation = current.success;
  if (operation.state === "result_available" || operation.state === "failed") {
    return null;
  }
  const attemptId = yield* newTranscriptionIdentity();
  const now = yield* transcriptionTimestamp();
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_transcription_attempts
     (attempt_id,operation_id,attempt_index,state,created_at)
     SELECT ?,?,?,'admitted',? FROM trigo_transcription_operations o WHERE o.operation_id=?
     AND o.state IN ('queued','running') AND ${currentTranscriptionFence}
     AND (?=0 OR EXISTS (SELECT 1 FROM trigo_transcription_attempts previous
       WHERE previous.operation_id=o.operation_id AND previous.attempt_index=0
       AND previous.state='failed' AND previous.failure_retry='retryable'))`,
    [attemptId, operationId, index, now, operationId, index],
  );
  const [attempt] = yield* transcriptionRows(
    env.CATALOG,
    AttemptRow,
    "SELECT * FROM trigo_transcription_attempts WHERE operation_id=? AND attempt_index=?",
    [operationId, index],
  );
  if (!attempt) {
    return yield* transcriptionError("asr_attempt_limit", "after_correction", 409);
  }
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_transcription_operations AS o SET state='running',updated_at=?
     WHERE operation_id=? AND state IN ('queued','running') AND ${currentTranscriptionFence}`,
    [now, operationId],
  );
  return attempt;
});

export const readAttempt = Effect.fn("Transcription.readAttempt")(function* (
  env: TranscriptionExecutionEnvironment,
  attemptId: string,
) {
  const [attempt] = yield* transcriptionRows(
    env.CATALOG,
    AttemptRow,
    "SELECT * FROM trigo_transcription_attempts WHERE attempt_id=?",
    [attemptId],
  );
  if (!attempt) {
    return yield* transcriptionError("asr_not_found", "after_correction", 404);
  }
  return attempt;
});

/** Safe to replay: every provider call needs a distinct planned -> admitted transition. */
export const executeTranscriptionAttempt = Effect.fn("Transcription.executeAttempt")(function* (
  env: TranscriptionExecutionEnvironment,
  attemptId: string,
) {
  const attempt = yield* readAttempt(env, attemptId);
  const operation = yield* readTranscription(env.CATALOG, attempt.operation_id);
  if (
    attempt.state !== "admitted" ||
    operation.state === "result_available" ||
    operation.state === "failed"
  ) {
    return;
  }
  const execution = yield* Effect.gen(function* () {
    yield* prepareAttemptSubmissions(env, operation, attempt);
    for (const submission of yield* attemptSubmissions(env, attemptId)) {
      yield* submitAdmittedInterval(env, operation, attempt, submission);
      // Validate a complete response before starting another provider operation.
      yield* recoverSubmission(env, operation, submission);
    }
  }).pipe(Effect.result);
  if (execution._tag === "Failure") {
    yield* executeTranscriptionSQL(
      env.CATALOG,
      "UPDATE trigo_transcription_attempts SET failure_code=?,failure_retry=? WHERE attempt_id=? AND state='admitted'",
      [execution.failure.code, execution.failure.retry, attemptId],
    );
  }
});

export const recoverTranscriptionAttempt = Effect.fn("Transcription.recoverAttempt")(function* (
  env: TranscriptionExecutionEnvironment,
  attemptId: string,
) {
  const attempt = yield* readAttempt(env, attemptId);
  const recovered = yield* recoverAndPublishTranscription(env, attempt.operation_id, attempt).pipe(
    Effect.result,
  );
  if (recovered._tag === "Success") {
    return { state: "result_available" as const };
  }
  const failure = recovered.failure;
  if (failure.code === "asr_storage_unavailable") {
    return yield* failure;
  }
  if (
    failure.code === "asr_submission_uncertain" &&
    attempt.failure_code !== null &&
    attempt.failure_retry !== null
  ) {
    return { state: "failed" as const, code: attempt.failure_code, retry: attempt.failure_retry };
  }
  return { state: "failed" as const, code: failure.code, retry: failure.retry };
});

export const failTranscriptionAttempt = Effect.fn("Transcription.failAttempt")(function* (
  env: TranscriptionExecutionEnvironment,
  attemptId: string,
  failure: Pick<TranscriptionError, "code" | "retry">,
  terminal: boolean,
) {
  const attempt = yield* readAttempt(env, attemptId);
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_transcription_attempts SET state='failed',failure_code=?,failure_retry=?
     WHERE attempt_id=? AND state!='succeeded'`,
    [failure.code, failure.retry, attemptId],
  );
  if (!terminal) {
    return;
  }
  const now = yield* transcriptionTimestamp();
  const exhausted = attempt.attempt_index === 1 && failure.retry === "retryable";
  // Failure can be recorded after credentials change or deletion. It releases the active
  // request without publishing evidence or granting any new external side effect.
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `UPDATE trigo_transcription_operations SET state='failed',updated_at=?,failure_code=?,failure_retry=?
     WHERE operation_id=? AND state IN ('queued','running') AND NOT EXISTS (
       SELECT 1 FROM trigo_transcription_attempts newer WHERE newer.operation_id=? AND newer.attempt_index>?)`,
    [
      now,
      exhausted ? "asr_attempt_limit" : failure.code,
      exhausted ? "after_correction" : failure.retry,
      attempt.operation_id,
      attempt.operation_id,
      attempt.attempt_index,
    ],
  );
});
