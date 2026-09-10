import { Effect, Schema } from "effect";

import { cleanupAssemblyAIResults } from "./assemblyai-submissions.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "./transcription-attempts.ts";
import {
  AttemptRow,
  currentTranscriptionFence,
  executeTranscriptionSQL,
  readTranscription,
  transcriptionRows,
} from "./transcription-catalog.ts";
import { transcriptionError } from "./transcription-errors.ts";
import type { TranscriptionExecutionEnvironment } from "./transcription-submissions.ts";
import {
  transcriptionProviderStep,
  transcriptionStorageStep,
  type TranscriptionWorkflowStep,
} from "./transcription-workflow-steps.ts";

const maximumPolls = 360;

/** API job waiting sleeps durably between short provider/storage steps. Replaying a step or
 * restarting this Workflow still goes through the persisted upload/paid-admission ledger. */
export const assemblyAIWorkflow = Effect.fn("AssemblyAI.workflow")(function* (
  env: TranscriptionExecutionEnvironment,
  operationId: string,
  step: TranscriptionWorkflowStep,
) {
  const run = Effect.runPromiseWith(yield* Effect.context<never>());
  const resumeIndex = yield* Effect.tryPromise({
    try: () =>
      step.do("assemblyai-resolve-attempt", transcriptionStorageStep, () =>
        run(
          Effect.gen(function* () {
            yield* executeTranscriptionSQL(
              env.CATALOG,
              `UPDATE trigo_transcription_operations AS o SET failure_code=NULL,failure_retry=NULL
         WHERE operation_id=? AND state='running' AND failure_code IN ('asr_processing_timeout','asr_admission_uncertain') AND ${currentTranscriptionFence}`,
              [operationId],
            );
            const attempts = yield* transcriptionRows(
              env.CATALOG,
              AttemptRow,
              "SELECT * FROM trigo_transcription_attempts WHERE operation_id=? ORDER BY attempt_index DESC LIMIT 1",
              [operationId],
            );
            return attempts[0]?.attempt_index ?? 0;
          }),
        ),
      ),
    catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
  });
  let waitingExpired = false;
  for (const index of [0, 1] as const) {
    if (index < resumeIndex) {
      continue;
    }
    const attemptId = yield* Effect.tryPromise({
      try: () =>
        step.do(`assemblyai-admit-${index}`, transcriptionStorageStep, () =>
          run(
            admitTranscriptionAttempt(env, operationId, index).pipe(
              Effect.map((attempt) => attempt?.attempt_id ?? null),
            ),
          ),
        ),
      catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
    });
    if (attemptId === null) {
      break;
    }
    let terminal = false;
    for (let round = 0; round < maximumPolls; round++) {
      // Retry is disabled around uploads/POSTs. A later round can resume a durable uploaded
      // phase, but the submitting phase only permits provider lookup/GET.
      yield* Effect.tryPromise({
        try: () =>
          step.do(`assemblyai-submit-${index}-${round}`, transcriptionProviderStep, () =>
            run(executeTranscriptionAttempt(env, attemptId).pipe(Effect.as(null))),
          ),
        catch: () => transcriptionError("asr_submission_uncertain", "retryable", 503),
      }).pipe(Effect.ignore);
      const recovered = yield* Effect.tryPromise({
        try: () =>
          step.do(`assemblyai-recover-${index}-${round}`, transcriptionStorageStep, () =>
            run(recoverTranscriptionAttempt(env, attemptId)),
          ),
        catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
      });
      if (recovered.state === "result_available") {
        terminal = true;
        break;
      }
      if (recovered.state === "failed") {
        terminal = index === 1 || recovered.retry !== "retryable";
        yield* Effect.tryPromise({
          try: () =>
            step.do(`assemblyai-fail-${index}`, transcriptionStorageStep, () =>
              run(
                failTranscriptionAttempt(env, attemptId, recovered, terminal).pipe(Effect.as(null)),
              ),
            ),
          catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
        });
        break;
      }
      if (round + 1 === maximumPolls) {
        waitingExpired = true;
        // Keep the active attempt. A same-command resume can continue waiting without
        // acquiring another paid attempt, including an admission whose ACK was lost.
        yield* Effect.tryPromise({
          try: () =>
            step.do(`assemblyai-wait-expired-${index}`, transcriptionStorageStep, () =>
              run(
                Effect.gen(function* () {
                  const uncertain = yield* transcriptionRows(
                    env.CATALOG,
                    Schema.Struct({ submission_id: Schema.String }),
                    `SELECT j.submission_id FROM trigo_assemblyai_jobs j JOIN trigo_asr_submissions s USING (submission_id)
               WHERE s.attempt_id=? AND j.phase='submitting' AND j.provider_id IS NULL LIMIT 1`,
                    [attemptId],
                  );
                  yield* executeTranscriptionSQL(
                    env.CATALOG,
                    `UPDATE trigo_transcription_operations AS o SET failure_code=?,failure_retry=? WHERE operation_id=? AND state='running' AND ${currentTranscriptionFence}`,
                    [
                      uncertain.length ? "asr_admission_uncertain" : "asr_processing_timeout",
                      uncertain.length ? "after_correction" : "retryable",
                      operationId,
                    ],
                  );
                  return null;
                }),
              ),
            ),
          catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
        });
        break;
      }
      yield* Effect.tryPromise({
        try: () => step.sleep(`assemblyai-wait-${index}-${round}`, "30 seconds"),
        catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
      });
    }
    if (terminal || waitingExpired) {
      break;
    }
  }
  const operation = yield* readTranscription(env.CATALOG, operationId);
  if (operation.state === "result_available" || operation.state === "failed") {
    // Cleanup is separate from result availability. Failed cleanup leaves its durable job
    // marker and an errored Workflow that can be restarted without replaying paid admission.
    yield* Effect.tryPromise({
      try: () =>
        step.do(
          "assemblyai-cleanup",
          {
            retries: { limit: 10, delay: "1 minute", backoff: "exponential" },
            timeout: "5 minutes",
          },
          () => run(cleanupAssemblyAIResults(env, operationId).pipe(Effect.as(null))),
        ),
      catch: () => transcriptionError("asr_cleanup_pending", "retryable", 503),
    });
  }
  return { operationId, state: operation.state, waitingExpired };
});
