import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { expect, it } from "vitest";

import { changedPaths, ciPlan, selectChecks } from "./ci-plan.ts";
import { assertCIResults } from "./ci-summary.ts";

it.each([
  [["docs/development/acceptance.md", "README.md"], { server: false, macos: "none" }],
  [["apps/macos/Native/File.swift"], { server: false, macos: "full" }],
  [["apps/server/src/api.ts"], { server: true, macos: "smoke" }],
  [["infra/local.ts"], { server: true, macos: "smoke" }],
  [["packages/contracts/fixtures/example.json"], { server: true, macos: "full" }],
  [["scripts/ci-plan.ts"], { server: true, macos: "full" }],
  [["bun.lock"], { server: true, macos: "full" }],
  [[".github/workflows/check.yml"], { server: true, macos: "full" }],
  [["unknown/README.md"], { server: true, macos: "full" }],
  [["docs/development/fixtures/runtime.html"], { server: true, macos: "full" }],
  [["apps/server/src/api.ts", "apps/macos/Native/File.swift"], { server: true, macos: "full" }],
  [[], { server: true, macos: "full" }],
] as const)("selects dependent checks for %j", (paths, expected) => {
  expect(selectChecks(paths)).toEqual(expected);
});

it("uses the entire PR diff, retains deleted paths, and falls back to full checks for missing history", () => {
  const root = mkdtempSync(join(tmpdir(), "trigo-ci-plan-"));
  const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" });
  const write = (path: string, contents: string) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), contents);
  };
  const commit = () => {
    git("add", ".");
    git("-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid", "commit", "-qm", "test");
    return git("rev-parse", "HEAD").trim();
  };
  try {
    git("init", "-q");
    write("README.md", "base\n");
    const base = commit();
    write("apps/macos/Native/File.swift", "let example = 1\n");
    const native = commit();
    write("README.md", "CI evidence\n");
    const head = commit();
    const event = { pull_request: { base: { sha: base }, head: { sha: head } } };
    expect(changedPaths("pull_request", event, root)).toEqual([
      "README.md",
      "apps/macos/Native/File.swift",
    ]);
    expect(ciPlan("pull_request", event, true, root).selected.macos).toBe("full");
    expect(changedPaths("push", { before: native, after: head }, root)).toEqual(["README.md"]);
    mkdirSync(join(root, "docs"));
    renameSync(join(root, "apps/macos/Native/File.swift"), join(root, "docs/moved.md"));
    const moved = commit();
    expect(changedPaths("push", { before: head, after: moved }, root)).toContain(
      "apps/macos/Native/File.swift",
    );
    expect(ciPlan("push", { before: "0".repeat(40), after: moved }, true, root).selected).toEqual({
      server: true,
      macos: "full",
    });
    expect(ciPlan("push", { before: native, after: head }, false, root).selected).toEqual({
      server: true,
      macos: "full",
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

it.each(["failure", "cancelled", "skipped", "neutral", "", undefined])(
  "refuses required work that did not succeed: %s",
  (result) => {
    const needs = {
      plan: { result: "success", outputs: { server: "true", macos: "smoke" } },
      server: { result: "success" },
      macos: { result },
    };
    expect(() => assertCIResults(needs)).toThrow();
    expect(() =>
      assertCIResults({ ...needs, macos: { result: "success" }, plan: { ...needs.plan, result } }),
    ).toThrow();
  },
);

it("accepts intentional skips only with a successful, complete check selection", () => {
  const needs = {
    plan: { result: "success", outputs: { server: "false", macos: "none" } },
    server: { result: "skipped" },
    macos: { result: "skipped" },
  };
  expect(() => assertCIResults(needs)).not.toThrow();
  expect(() => assertCIResults({ ...needs, plan: { result: "success", outputs: {} } })).toThrow();
  expect(() => assertCIResults({ ...needs, macos: undefined })).toThrow();
});
