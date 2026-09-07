import { expect, it } from "vitest";

import { nativeTests, swiftTests } from "./native-check.ts";
import { contentionTests, resourceTests } from "./native-suites.ts";

const discovered = ["ordinaryCorrectness", ...contentionTests, ...resourceTests].map(
  (name) => `TrigoNativeTests.${name}()`,
);

function operations(failedBuild?: string) {
  const events: { kind: string; phase: string; command: string[] }[] = [];
  return {
    events,
    execute(phase: string, command: string[]) {
      events.push({ kind: "command", phase, command });
      if (phase === failedBuild) {
        throw new Error("compiler failed");
      }
    },
    prepareNative(build: () => void) {
      build();
      return "/unused/unit-test-receipt.json";
    },
    discover(command: string[]) {
      events.push({ kind: "discovery", phase: "discovery", command });
      return discovered.join("\n");
    },
    test(phase: string, command: string[]) {
      events.push({ kind: "test", phase, command });
    },
  };
}

it("builds current sources once before discovery and all native groups on every invocation", () => {
  const recorded = operations();
  for (let attempt = 0; attempt < 2; attempt++) {
    swiftTests(recorded);
  }
  const builds = recorded.events.filter((event) => event.command.includes("--build-tests"));
  expect(builds).toHaveLength(4);
  for (const event of builds) {
    expect(event.command).toContain("-enable-testing");
    expect(event.command[event.command.indexOf("-enable-testing") - 1]).toBe("-Xswiftc");
    expect(event.command).toContain("--force-resolved-versions");
    expect(event.command).toContain("--skip-update");
  }
  for (const [index, event] of recorded.events.entries()) {
    if (event.kind === "discovery") {
      expect(recorded.events[index - 1]?.phase).toBe("apps/macos release build tests");
    }
  }
  expect(recorded.events.filter((event) => event.phase.startsWith("Native resource"))).toHaveLength(
    resourceTests.length * 2,
  );
});

it.each(["packages/contracts debug build tests", "apps/macos release build tests"])(
  "does not discover or execute stale native binaries after %s fails",
  (failed) => {
    const recorded = operations(failed);
    expect(() => swiftTests(recorded)).toThrow("compiler failed");
    expect(recorded.events.at(-1)?.phase).toBe(failed);
    expect(recorded.events.some((event) => event.kind !== "command")).toBe(false);
  },
);

it("uses the same Release build for focused feedback and executes only the selected current test", () => {
  const recorded = operations();
  nativeTests({ suite: "fast", filter: "ordinaryCorrectness" }, recorded);
  expect(recorded.events[0]?.command).toContain("release");
  const tests = recorded.events.filter((event) => event.kind === "test");
  expect(tests).toHaveLength(1);
  const filter = tests[0]!.command.at(-1)!;
  expect(discovered.filter((test) => new RegExp(filter).test(test))).toEqual([
    "TrigoNativeTests.ordinaryCorrectness()",
  ]);
});
