import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, resolve } from "node:path";

import { expect, it } from "vitest";

it("retains failed-run source identity when native tools are unavailable, without starting UI", () => {
  const entry = resolve("scripts/macos.ts");
  const directory = mkdtempSync(resolve(tmpdir(), "trigo-ui-preflight-test-"));
  try {
    const bin = resolve(directory, "bin");
    mkdirSync(bin);
    writeFileSync(resolve(bin, "xcodebuild"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
    writeFileSync(resolve(directory, ".gitignore"), ".local/\nbin/\n");
    for (const args of [
      ["init", "--quiet", "--initial-branch=main"],
      ["add", ".gitignore"],
      [
        "-c",
        "user.name=UI Fixture",
        "-c",
        "user.email=fixture@invalid.test",
        "commit",
        "--quiet",
        "-m",
        "test: initialize disposable acceptance inputs",
      ],
    ]) {
      const result = spawnSync("git", args, { cwd: directory, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    }
    const result = spawnSync("bun", [entry, "ui", "--suite", "shell"], {
      cwd: directory,
      env: {
        ...process.env,
        PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
        GITHUB_STEP_SUMMARY: "",
        TRIGO_TIMINGS_FILE: "",
      },
      encoding: "utf8",
      timeout: 20_000,
    });
    expect(result.status).toBe(1);
    const parent = resolve(directory, ".local/ui-runs");
    const runs = readdirSync(parent);
    expect(runs).toHaveLength(1);
    const receipt: unknown = JSON.parse(
      readFileSync(resolve(parent, runs[0]!, "run.json"), "utf8"),
    );
    expect(receipt).toMatchObject({
      status: "failed",
      commands: [],
      source: { revision: expect.any(String), fingerprint: expect.any(String) },
      failure: expect.any(String),
      finishedAt: expect.any(String),
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
