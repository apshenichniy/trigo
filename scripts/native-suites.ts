export const nativeSuites = ["fast", "contention", "resource", "all"] as const;
export type NativeSuite = (typeof nativeSuites)[number];

// All other discovered tests enter the fast suite. Explicit names make removal or
// renaming of a slow proof a visible classification change instead of silent omission.
export const contentionTests = [
  "repositoryBackgroundImportAndLargeTypedReadsStayInsideCaptureWindow",
  "productionDurabilityIsRecoverableWhileItsObserverIsDelayed",
  "productionDurabilityDriverDistinguishesCallerDelayFromActualQueueDelay",
] as const;
export const resourceTests = [
  "mediaMasterOneHourFrequentIntervals",
  "mediaMasterThreeHourFrequentIntervals",
  "mediaMasterOneHourCommonClockDrift",
  "threeHourProfileWriterRetainsEverySecondWithoutTruncation",
  "oneHourCommonClockFixtureHasNoAccumulatingSourceRelativeDrift",
  "productionMasterOneHourFrequentStateProof",
  "productionMasterThreeHourFrequentStateProof",
] as const;

export function nativeTestName(id: string): string {
  return id.split(/[./]/).at(-1)!.split("(")[0]!;
}

export function parseNativeTests(output: string): string[] {
  const tests = output.trim().split(/\r?\n/).filter(Boolean);
  if (!tests.length || tests.some((test) => !/^TrigoNativeTests[./]\S+$/.test(test))) {
    throw new Error("Native test discovery was empty or contained an unknown test target/format");
  }
  if (new Set(tests).size !== tests.length) {
    throw new Error("Native test discovery contained duplicates");
  }
  return tests;
}

export function planNativeTests(
  tests: readonly string[],
  suite: NativeSuite,
  filter?: string,
): { suite: Exclude<NativeSuite, "all">; tests: string[] }[] {
  for (const name of [...contentionTests, ...resourceTests]) {
    if (tests.filter((test) => nativeTestName(test) === name).length !== 1) {
      throw new Error(`Expected exactly one discovered native proof: ${name}`);
    }
  }
  const selected = filter === undefined ? undefined : new RegExp(filter);
  const groups = { fast: [] as string[], contention: [] as string[], resource: [] as string[] };
  for (const test of tests) {
    const name = nativeTestName(test);
    const group = resourceTests.some((proof) => proof === name)
      ? "resource"
      : contentionTests.some((proof) => proof === name)
        ? "contention"
        : "fast";
    if ((suite === "all" || suite === group) && (!selected || selected.test(test))) {
      groups[group].push(test);
    }
  }
  const plan = [
    { suite: "fast" as const, tests: groups.fast },
    { suite: "contention" as const, tests: groups.contention },
    // Separate processes make each resource proof's RSS measurement independent.
    ...groups.resource.map((test) => ({ suite: "resource" as const, tests: [test] })),
  ].filter((group) => group.tests.length);
  if (!plan.length) {
    throw new Error(
      `No native tests matched suite ${suite}${filter ? ` and filter ${filter}` : ""}`,
    );
  }
  return plan;
}

export function exactTestFilter(tests: readonly string[]): string {
  // Swift Testing lists IDs without source locations but matches runtime IDs
  // with an optional /file.swift:line:column suffix (Test.ID.description).
  return `^(?:${tests.map((test) => test.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})(?:/.*)?$`;
}

export function assertNativeTestOutput(output: string, resourceTest?: string): void {
  const text = stripVTControlCharacters(output);
  if (!/Test run with [1-9]\d* tests?(?: in [^\n]+?)? passed after /.test(text)) {
    throw new Error("Native test runner did not report a non-empty successful Swift Testing run");
  }
  if (!resourceTest || resourceTest === "mediaMasterOneHourCommonClockDrift") {
    return;
  }
  const measurements = [...text.matchAll(/MASTER_RESOURCES phase=(\S+) peak_rss_bytes=(\d+)/g)];
  if (!measurements.length) {
    throw new Error(`Resource proof emitted no RSS measurements: ${resourceTest}`);
  }
  const limit = 80 * 1024 * 1024;
  for (const [, phase, bytes] of measurements) {
    if (Number(bytes) <= 0 || Number(bytes) >= limit) {
      throw new Error(
        `Resource proof ${resourceTest} exceeded its 80-MiB RSS bound at ${phase}: ${bytes}`,
      );
    }
  }
}
import { stripVTControlCharacters } from "node:util";
