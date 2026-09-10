import type { WorkflowStep, WorkflowStepConfig } from "cloudflare:workers";

/** The orchestration uses only durable do/sleep. This is the same contract in workerd and
 * deterministic orchestration tests; no provider payload crosses its return boundary. */
export interface TranscriptionWorkflowStep {
  readonly do: <A extends Rpc.Serializable<A>>(
    name: string,
    config: WorkflowStepConfig,
    callback: () => Promise<A>,
  ) => Promise<A>;
  readonly sleep: WorkflowStep["sleep"];
}

export const transcriptionStorageStep = {
  retries: { limit: 3, delay: "2 seconds", backoff: "exponential" },
  timeout: "15 minutes",
} satisfies WorkflowStepConfig;
export const transcriptionProviderStep = {
  retries: { limit: 0, delay: "1 second", backoff: "constant" },
  timeout: "15 minutes",
} satisfies WorkflowStepConfig;
