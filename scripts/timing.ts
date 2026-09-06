import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { run } from "./process.ts";

export function timedRun(phase: string, command: string[], options?: Parameters<typeof run>[1]) {
  const start = performance.now();
  let passed = false;
  try {
    run(command, options);
    passed = true;
  } finally {
    const seconds = Number(((performance.now() - start) / 1000).toFixed(3));
    console.log(`[timing] ${phase}: ${seconds.toFixed(3)} s (${passed ? "passed" : "failed"})`);
    const file = process.env.TRIGO_TIMINGS_FILE;
    if (file) {
      mkdirSync(dirname(file), { recursive: true });
      appendFileSync(file, `${JSON.stringify({ phase, seconds, passed })}\n`);
    }
    if (process.env.GITHUB_STEP_SUMMARY)
      appendFileSync(
        process.env.GITHUB_STEP_SUMMARY,
        `- ${phase}: **${seconds.toFixed(3)} s** (${passed ? "passed" : "failed"})\n`,
      );
  }
}
