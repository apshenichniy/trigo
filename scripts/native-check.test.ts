import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { swiftTests } from "./native-check.ts";
import { timedRun } from "./timing.ts";

afterEach(() => vi.unstubAllEnvs());

it("builds current sources before each complete test suite, even with warm caches", () => {
  const commands: string[][] = [];
  for (let run = 0; run < 2; run++)
    swiftTests((_phase, command) => {
      commands.push(command);
    });
  expect(commands).toHaveLength(8);
  for (let index = 0; index < commands.length; index += 2) {
    const build = commands[index]!;
    const test = commands[index + 1]!;
    expect(build).toContain("--build-tests");
    expect(build).toContain("-enable-testing");
    expect(test).toContain("--skip-build");
    for (const command of [build, test]) {
      expect(command[0]).toBe("swift");
      expect(command).toContain("--force-resolved-versions");
      expect(command).toContain("--skip-update");
      expect(command).not.toContain("--filter");
      expect(command).not.toContain("--skip");
      const path = command[command.indexOf("--package-path") + 1];
      expect(command[command.indexOf("--configuration") + 1]).toBe(
        path === "apps/macos" ? "release" : "debug",
      );
    }
  }
});

it.each([0, 2])("does not run stale test binaries when build phase %s fails", (failedPhase) => {
  const executed: string[] = [];
  expect(() =>
    swiftTests((phase) => {
      executed.push(phase);
      if (executed.length - 1 === failedPhase) throw new Error("compiler failed");
    }),
  ).toThrow("compiler failed");
  expect(executed).toHaveLength(failedPhase + 1);
  expect(executed.at(-1)).toContain("build tests");
});

it("records a failing subprocess duration and still propagates the failure", () => {
  const dir = mkdtempSync(join(tmpdir(), "trigo-timing-"));
  try {
    const file = join(dir, "nested", "timings.jsonl");
    vi.stubEnv("TRIGO_TIMINGS_FILE", file);
    vi.stubEnv("GITHUB_STEP_SUMMARY", "");
    expect(() => timedRun("failed compiler", [process.execPath, "-e", "process.exit(7)"])).toThrow(
      "failed (7)",
    );
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({
      phase: "failed compiler",
      seconds: expect.any(Number),
      passed: false,
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
