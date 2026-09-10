import { Effect } from "effect";

import { assemblyAIStereoProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { assemblyAIWorkflow } from "./assemblyai-workflow.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "./transcription-attempts.ts";
import { AttemptRow, readTranscription, transcriptionRows } from "./transcription-catalog.ts";
import { transcriptionError } from "./transcription-errors.ts";
import { type TranscriptionExecutionEnvironment } from "./transcription-submissions.ts";
import {
  transcriptionStorageStep as storageStep,
  transcriptionProviderStep as providerStep,
  type TranscriptionWorkflowStep,
} from "./transcription-workflow-steps.ts";

const workflowProgram = Effect.fn("Transcription.workflow")(function* (
  env: TranscriptionExecutionEnvironment,
  operationId: string,
  step: TranscriptionWorkflowStep,
) {
  const selected = yield* readTranscription(env.CATALOG, operationId);
  if (env.TRANSCRIPTION_MODE === "hosted" && selected.profile_id === assemblyAIStereoProfile.id) {
    return yield* assemblyAIWorkflow(env, operationId, step);
  }
  const run = Effect.runPromiseWith(yield* Effect.context<never>());
  // restart() clears Workflow history. The latest D1 attempt remains authoritative;
  // revisiting a superseded original would stop before its admitted replacement.
  const resumeIndex = yield* Effect.tryPromise({
    try: () =>
      step.do("resolve-durable-attempt", storageStep, () =>
        run(
          transcriptionRows(
            env.CATALOG,
            AttemptRow,
            "SELECT * FROM trigo_transcription_attempts WHERE operation_id=? ORDER BY attempt_index DESC LIMIT 1",
            [operationId],
          ).pipe(Effect.map((attempts) => attempts[0]?.attempt_index ?? 0)),
        ),
      ),
    catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
  });
  for (const index of [0, 1] as const) {
    if (index < resumeIndex) {
      continue;
    }
    const attemptId = yield* Effect.tryPromise({
      try: () =>
        step.do(`admit-attempt-${index}`, storageStep, () =>
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
    // A platform interruption may lose this step's acknowledgement. Recovery runs in a
    // separate durable step and never repeats an admitted provider submission.
    yield* Effect.tryPromise({
      try: () =>
        step.do(`submit-attempt-${index}`, providerStep, () =>
          run(executeTranscriptionAttempt(env, attemptId).pipe(Effect.as(null))),
        ),
      catch: () => transcriptionError("asr_submission_uncertain", "retryable", 503),
    }).pipe(Effect.ignore);
    const recovered = yield* Effect.tryPromise({
      try: () =>
        step.do(`recover-attempt-${index}`, storageStep, () =>
          run(recoverTranscriptionAttempt(env, attemptId)),
        ),
      catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
    });
    if (recovered.state === "result_available") {
      break;
    }
    if (recovered.state === "pending") {
      return yield* transcriptionError("asr_provider_processing", "retryable", 503);
    }
    const terminal = index === 1 || recovered.retry !== "retryable";
    yield* Effect.tryPromise({
      try: () =>
        step.do(`resolve-attempt-${index}`, storageStep, () =>
          run(failTranscriptionAttempt(env, attemptId, recovered, terminal).pipe(Effect.as(null))),
        ),
      catch: () => transcriptionError("asr_storage_unavailable", "retryable", 503),
    });
    if (terminal) {
      break;
    }
  }
  const operation = yield* readTranscription(env.CATALOG, operationId);
  return { operationId: operation.operation_id, state: operation.state };
});

/** Only IDs and short state/error records cross the Workflow serialization boundary. */
export function runTranscriptionWorkflow(
  env: TranscriptionExecutionEnvironment,
  operationId: string,
  step: TranscriptionWorkflowStep,
) {
  return Effect.runPromise(workflowProgram(env, operationId, step));
}
