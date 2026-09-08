import { type WorkflowStep } from "cloudflare:workers";
import { Effect } from "effect";

import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "./transcription-attempts.ts";
import { readTranscription } from "./transcription-catalog.ts";
import { transcriptionError } from "./transcription-errors.ts";
import { type TranscriptionExecutionEnvironment } from "./transcription-submissions.ts";

const storageStep = {
  retries: { limit: 3, delay: "2 seconds", backoff: "exponential" },
  timeout: "15 minutes",
} satisfies Parameters<WorkflowStep["do"]>[1];
const providerStep = {
  retries: { limit: 0, delay: "1 second", backoff: "constant" },
  timeout: "15 minutes",
} satisfies Parameters<WorkflowStep["do"]>[1];

const workflowProgram = Effect.fn("Transcription.workflow")(function* (
  env: TranscriptionExecutionEnvironment,
  operationId: string,
  step: WorkflowStep,
) {
  const run = Effect.runPromiseWith(yield* Effect.context<never>());
  for (const index of [0, 1] as const) {
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
  step: WorkflowStep,
) {
  return Effect.runPromise(workflowProgram(env, operationId, step));
}
