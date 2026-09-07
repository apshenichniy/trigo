import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { sourceState } from "./check-inputs.ts";
import { run } from "./process.ts";

type TimingContext = {
  invocationId: string;
  runId: string;
  rootSpanId: string;
  source: ReturnType<typeof sourceState>;
  selection: Record<string, string | boolean>;
};
let context: TimingContext | undefined;
let activeSpan: string | undefined;

function timingContext(): TimingContext {
  if (!context) {
    const invocationId = randomUUID();
    context = {
      invocationId,
      runId: process.env.TRIGO_CHECK_RUN_ID ?? invocationId,
      rootSpanId: randomUUID(),
      source: sourceState(),
      selection: {},
    };
  }
  return context;
}

function startSpan(phase: string, configuration: string | null, root = false) {
  const identity = timingContext();
  const id = root ? identity.rootSpanId : randomUUID();
  const parentId = root
    ? (process.env.TRIGO_CHECK_PARENT_SPAN_ID ?? null)
    : (activeSpan ?? identity.rootSpanId);
  const start = performance.now();
  const startedAtMs = performance.timeOrigin + start;
  return {
    id,
    finish(passed: boolean) {
      const seconds = Number(((performance.now() - start) / 1000).toFixed(3));
      const record = {
        version: 1,
        ...identity,
        spanId: id,
        parentSpanId: parentId,
        kind: root ? "command" : "phase",
        phase,
        configuration,
        startedAtMs,
        endedAtMs: performance.timeOrigin + performance.now(),
        seconds,
        passed,
      };
      console.log(`[timing] ${phase}: ${seconds.toFixed(3)} s (${passed ? "passed" : "failed"})`);
      const file = process.env.TRIGO_TIMINGS_FILE;
      if (file) {
        mkdirSync(dirname(file), { recursive: true });
        appendFileSync(file, `${JSON.stringify(record)}\n`);
      }
      if (process.env.GITHUB_STEP_SUMMARY) {
        appendFileSync(
          process.env.GITHUB_STEP_SUMMARY,
          `- ${phase}: **${seconds.toFixed(3)} s** (${passed ? "passed" : "failed"}; ${id})\n`,
        );
      }
    },
  };
}

/** Call after validating arguments, so rejected commands never start tools or timing. */
export function beginTiming(command: string, selection: TimingContext["selection"] = {}): void {
  timingContext().selection = selection;
  const span = startSpan(command, null, true);
  process.once("exit", (code: number) => span.finish(code === 0));
}

export function timingEnvironment(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const identity = timingContext();
  return {
    ...base,
    TRIGO_CHECK_RUN_ID: identity.runId,
    TRIGO_CHECK_PARENT_SPAN_ID: activeSpan ?? identity.rootSpanId,
  };
}

export const timingRunId = () => timingContext().runId;

export function timed<T>(
  phase: string,
  operation: () => T,
  configuration: string | null = null,
): T {
  const span = startSpan(phase, configuration);
  const previous = activeSpan;
  activeSpan = span.id;
  let passed = false;
  try {
    const result = operation();
    passed = true;
    return result;
  } finally {
    activeSpan = previous;
    span.finish(passed);
  }
}

export async function timedAsync<T>(
  phase: string,
  operation: () => Promise<T>,
  configuration: string | null = null,
): Promise<T> {
  const span = startSpan(phase, configuration);
  const previous = activeSpan;
  activeSpan = span.id;
  let passed = false;
  try {
    const result = await operation();
    passed = true;
    return result;
  } finally {
    activeSpan = previous;
    span.finish(passed);
  }
}

export function timedRun(phase: string, command: string[], options?: Parameters<typeof run>[1]) {
  const configurationIndex = command.findIndex((value) =>
    ["--configuration", "-configuration"].includes(value),
  );
  timed(
    phase,
    () => run(command, { ...options, env: timingEnvironment(options?.env) }),
    configurationIndex < 0 ? null : (command[configurationIndex + 1] ?? null),
  );
}
