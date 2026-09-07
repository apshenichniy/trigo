import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, it } from "vitest";

it("retains failed nested command timings with source identity and a shared run without double-counting", () => {
  const directory = mkdtempSync(join(tmpdir(), "trigo-timing-"));
  try {
    const modulePath = JSON.stringify(resolve("scripts/timing.ts"));
    const child = `import { beginTiming } from ${modulePath}; beginTiming('child'); process.exitCode = 7;`;
    const parent = `import { beginTiming, timedRun } from ${modulePath}; beginTiming('parent', { scope: 'native' }); timedRun('child command', ['bun', '-e', ${JSON.stringify(child)}]);`;
    const file = join(directory, "timings.jsonl");
    const result = spawnSync("bun", ["-e", parent], {
      encoding: "utf8",
      env: { ...process.env, TRIGO_TIMINGS_FILE: file, GITHUB_STEP_SUMMARY: "" },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("failed (7)");
    const records = readFileSync(file, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const root = records.find((record) => record.phase === "parent");
    const phase = records.find((record) => record.phase === "child command");
    const nested = records.find((record) => record.phase === "child");
    expect(records).toHaveLength(3);
    for (const record of records) {
      expect(record).toMatchObject({
        passed: false,
        runId: root.runId,
        source: { fingerprint: expect.any(String), revision: expect.any(String) },
      });
      expect(record.endedAtMs).toBeGreaterThanOrEqual(record.startedAtMs);
    }
    expect(nested.invocationId).not.toBe(root.invocationId);
    expect(root.selection).toEqual({ scope: "native" });
    expect(phase.selection).toEqual(root.selection);
    expect(nested.selection).toEqual({});
    expect(nested.parentSpanId).toBe(phase.spanId);
    expect(phase.parentSpanId).toBe(root.spanId);
    expect(root.seconds).toBeGreaterThanOrEqual(phase.seconds);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
