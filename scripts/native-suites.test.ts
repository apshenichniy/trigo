import { expect, it } from "vitest";

import {
  assertNativeTestOutput,
  contentionTests,
  exactTestFilter,
  parseNativeTests,
  planNativeTests,
  resourceTests,
} from "./native-suites.ts";

const tests = [
  "TrigoNativeTests.Example/aNewCorrectnessTest(_:)",
  ...contentionTests.map((name) => `TrigoNativeTests.${name}()`),
  ...resourceTests.map((name) => `TrigoNativeTests.${name}()`),
];

it("partitions all discovered tests exactly once, including new tests, and isolates resource proofs", () => {
  const plan = planNativeTests(parseNativeTests(tests.join("\n")), "all");
  expect(plan.flatMap((group) => group.tests).sort()).toEqual([...tests].sort());
  expect(
    plan.filter((group) => group.suite === "resource").every((group) => group.tests.length === 1),
  ).toBe(true);
  expect(planNativeTests(tests, "fast").flatMap((group) => group.tests)).toEqual([tests[0]]);
});

it("refuses a renamed or removed slow proof instead of silently dropping acceptance", () => {
  expect(() => planNativeTests(tests.slice(0, -1), "all")).toThrow("Expected exactly one");
  expect(() => planNativeTests([...tests, tests.at(-1)!], "fast")).toThrow("Expected exactly one");
});

it("rejects missing tests, unknown discovery output and empty/invalid focused selections", () => {
  expect(() => parseNativeTests("")).toThrow("discovery");
  expect(() => parseNativeTests("AnotherTarget.test()")).toThrow("discovery");
  expect(() => parseNativeTests(`${tests[0]}\n${tests[0]}`)).toThrow("duplicates");
  expect(() => planNativeTests(tests, "fast", "doesNotExist")).toThrow("No native tests matched");
  expect(() => planNativeTests(tests, "fast", "[")).toThrow();
});

it("escapes complete Swift test identifiers without selecting adjacent names", () => {
  const pattern = new RegExp(exactTestFilter([tests[0]!, tests[1]!]));
  expect(tests.filter((test) => pattern.test(test))).toEqual(tests.slice(0, 2));
  expect(pattern.test(`${tests[0]}extra`)).toBe(false);
  expect(pattern.test(`${tests[0]}/File.swift:12:3`)).toBe(true);
});

it("rejects an empty successful runner or missing/excessive resource measurements", () => {
  expect(() => assertNativeTestOutput("Test run with 0 tests passed after 0.001 seconds.")).toThrow(
    "non-empty",
  );
  const passed = "✔ Test run with 1 test passed after 1.000 seconds.";
  expect(() => assertNativeTestOutput(passed)).not.toThrow();
  expect(() => assertNativeTestOutput(passed, resourceTests[0])).toThrow("no RSS");
  expect(() =>
    assertNativeTestOutput(
      `${passed}\nMASTER_RESOURCES phase=extract peak_rss_bytes=83886080`,
      resourceTests[0],
    ),
  ).toThrow("80-MiB");
  expect(() =>
    assertNativeTestOutput(
      `${passed}\nMASTER_RESOURCES phase=extract peak_rss_bytes=54362112`,
      resourceTests[0],
    ),
  ).not.toThrow();
});
