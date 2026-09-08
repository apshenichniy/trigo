import { spawnSync } from "node:child_process";

import { expect, it } from "vitest";

it("validates the selected-call collector against disposable repository and media fixtures", () => {
  const result = spawnSync("python3", ["scripts/installed-capture-evidence-test.py"], {
    encoding: "utf8",
    timeout: 60_000,
    maxBuffer: 1024 * 1024,
  });
  expect(result.error, result.stderr).toBeUndefined();
  expect(result.status, result.stderr).toBe(0);
  expect(result.stderr).toContain("Ran 21 tests");
  expect(result.stderr).toContain("OK");
});
