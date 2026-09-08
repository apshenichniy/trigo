import { describe, expect, it } from "vitest";

import { assertSuccessfulUIRun, curatedUIAttachment } from "./native-ui-evidence.ts";

describe("native UI evidence", () => {
  const passed = {
    result: "Passed",
    totalTestCount: 3,
    passedTests: 3,
    failedTests: 0,
    skippedTests: 0,
    expectedFailures: 0,
  };
  it("requires every selected UI test to pass instead of accepting an empty or skipped runner", () => {
    expect(() => assertSuccessfulUIRun(passed, 3)).not.toThrow();
    for (const failed of [
      null,
      {},
      { ...passed, result: "Failed" },
      { ...passed, totalTestCount: 0 },
      { ...passed, passedTests: 2, skippedTests: 1 },
      { ...passed, expectedFailures: 1 },
    ]) {
      expect(() => assertSuccessfulUIRun(failed, 3)).toThrow();
    }
    expect(() => assertSuccessfulUIRun(passed, 0)).toThrow();
  });
  it("curates explicit fixture attachments while excluding automatic desktop recordings", () => {
    expect(curatedUIAttachment("shell-library-empty-light_1_ABC123-DEF456.png")).toBe(
      "shell-library-empty-light.png",
    );
    expect(curatedUIAttachment("fixture-final-state_1_ABC123-DEF456.txt")).toBe(
      "fixture-final-state.txt",
    );
    for (const filename of [
      "Screen Recording_1_ABC123.mov",
      "Screenshot_1_ABC123.png",
      "../shell-window_1_ABC123.png",
      "shell-library_1_ABC123.mov",
    ]) {
      expect(curatedUIAttachment(filename)).toBeNull();
    }
  });
});
