import { execFileSync, spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { afterEach, expect, it } from "vitest";

import { installHooks } from "./install-hooks.ts";
import {
  assertPushMatchesHead,
  checkedSource,
  verificationEnvironment,
  verifyPush,
} from "./verify-push.ts";

const directories: string[] = [];
function directory(): string {
  const path = mkdtempSync(resolve(tmpdir(), "trigo-push-test-"));
  directories.push(path);
  return path;
}
afterEach(() => {
  for (const path of directories.splice(0)) {
    rmSync(path, { recursive: true, force: true });
  }
});

it.skipIf(process.platform !== "darwin")(
  "excludes concurrent verification and releases the kernel lease after process death",
  async () => {
    const lock = resolve(directory(), "verification.lock");
    const module = pathToFileURL(resolve("scripts/native-ui-lease.ts")).href;
    const source = `import { acquireLocalLease } from ${JSON.stringify(module)};
const release = acquireLocalLease(${JSON.stringify(lock)}, "local verification");
console.log("leased");
if (process.env.TRIGO_LEASE_FIXTURE_HOLD === "true") await Bun.stdin.text();
release();`;
    const owner = spawn("bun", ["-e", source], {
      env: { ...process.env, TRIGO_LEASE_FIXTURE_HOLD: "true" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    try {
      await once(owner.stdout, "data");
      const contender = spawnSync("bun", ["-e", source], { encoding: "utf8", timeout: 5000 });
      expect(contender.status).not.toBe(0);
      expect(contender.stderr).toContain("already owned");
      const closed = once(owner, "close");
      owner.kill("SIGKILL");
      await closed;
      const successor = spawnSync("bun", ["-e", source], { encoding: "utf8", timeout: 5000 });
      expect(successor.status, successor.stderr).toBe(0);
    } finally {
      if (owner.exitCode === null && owner.signalCode === null) {
        owner.kill("SIGTERM");
      }
    }
  },
  15_000,
);

function fixture() {
  const root = directory();
  const env = verificationEnvironment(process.cwd());
  const git = (...args: string[]) =>
    execFileSync("git", args, { cwd: root, env, encoding: "utf8" }).trim();
  git("init", "-q");
  git("config", "user.email", "test@example.invalid");
  git("config", "user.name", "Local verification fixture");
  writeFileSync(resolve(root, ".gitignore"), ".local/\n");
  writeFileSync(resolve(root, "source.txt"), "initial\n");
  git("add", ".");
  git("commit", "-qm", "test: initial fixture");
  return { root, git, env };
}

it("reuses only completed matching evidence and invalidates changed inputs, environments and logs", async () => {
  const root = directory();
  let source = { head: "first", tree: "tree", fingerprint: "inputs" };
  let environment = "tools-and-environment";
  let runs = 0;
  const options = {
    directory: root,
    source: () => source,
    environment: () => environment,
    check: async (log: string) => {
      runs += 1;
      writeFileSync(log, "all required checks passed\n");
    },
    reusable: true,
  };
  expect((await verifyPush(options)).reused).toBe(false);
  source = { ...source, head: "ancestry-only-commit" };
  expect((await verifyPush(options)).reused).toBe(true);
  expect(runs).toBe(1);
  source = { ...source, fingerprint: "changed-inputs" };
  expect((await verifyPush(options)).reused).toBe(false);
  environment = "changed-tools";
  expect((await verifyPush(options)).reused).toBe(false);
  const receipt = JSON.parse(readFileSync(resolve(root, "success.json"), "utf8"));
  writeFileSync(receipt.log, "changed log");
  expect((await verifyPush(options)).reused).toBe(false);
  expect(runs).toBe(4);
});

it.each(["failure", "source", "environment"])(
  "retains %s evidence without leaving a success receipt",
  async (failure) => {
    const root = directory();
    let source = { head: "head", tree: "tree", fingerprint: "inputs" };
    let environment = "environment";
    const options = {
      directory: root,
      source: () => source,
      environment: () => environment,
      check: async (log: string) => {
        writeFileSync(log, "initial pass\n");
      },
      reusable: false,
    };
    await verifyPush(options);
    await expect(
      verifyPush({
        ...options,
        check: async (log) => {
          writeFileSync(log, "retained failing run\n");
          if (failure === "failure") {
            throw new Error("fixture test failed");
          }
          if (failure === "source") {
            source = { ...source, head: "new-head" };
          } else {
            environment = "new-environment";
          }
        },
      }),
    ).rejects.toThrow();
    expect(existsSync(resolve(root, "success.json"))).toBe(false);
    const results = readdirSync(root).map((run) =>
      JSON.parse(readFileSync(resolve(root, run, "result.json"), "utf8")),
    );
    expect(results.map((result) => result.status).sort((a, b) => a.localeCompare(b))).toEqual([
      "failed",
      "passed",
    ]);
  },
);

it("checks the actual pushed commit and rejects dirty or hidden working changes", () => {
  const { root, git, env } = fixture();
  const first = checkedSource(root, env);
  const update = (sha: string) => `refs/heads/main ${sha} refs/heads/main ${"0".repeat(40)}\n`;
  expect(assertPushMatchesHead(update(first.head), root, first.head, env)).toBe(true);
  expect(assertPushMatchesHead(update("0".repeat(40)), root, first.head, env)).toBe(false);
  git("tag", "-a", "fixture", "-m", "fixture");
  expect(assertPushMatchesHead(update(git("rev-parse", "fixture")), root, first.head, env)).toBe(
    true,
  );
  writeFileSync(resolve(root, "source.txt"), "modified\n");
  expect(() => checkedSource(root, env)).toThrow("clean");
  git("add", "source.txt");
  expect(() => checkedSource(root, env)).toThrow("clean");
  git("commit", "-qm", "test: next fixture");
  const second = checkedSource(root, env);
  expect(() => assertPushMatchesHead(update(first.head), root, second.head, env)).toThrow(
    "other than HEAD",
  );
  git("update-index", "--assume-unchanged", "source.txt");
  expect(() => checkedSource(root, env)).toThrow("assume-unchanged");
});

it("installs one shared hook for worktrees and preserves custom hooks and configuration", () => {
  const { root, git } = fixture();
  mkdirSync(resolve(root, ".githooks"));
  const hook = readFileSync(".githooks/pre-push", "utf8");
  writeFileSync(resolve(root, ".githooks/pre-push"), hook);
  git("add", ".");
  git("commit", "-qm", "test: hook fixture");
  const first = installHooks(root);
  const worktree = resolve(directory(), "worktree");
  git("worktree", "add", "-q", "-b", "second", worktree);
  expect(installHooks(worktree)).toBe(first);
  writeFileSync(first, "#!/bin/sh\necho custom\n");
  expect(() => installHooks(root)).toThrow("preserved");
  expect(readFileSync(first, "utf8")).toContain("custom");
  git("config", "core.hooksPath", ".custom-hooks");
  expect(() => installHooks(root)).toThrow("core.hooksPath");
});

it.each([false, true])(
  "blocks failed Git pushes and reuses manual checks with custom search paths=%s",
  (customPaths) => {
    const { root, git, env } = fixture();
    if (customPaths) {
      env.CPATH = "/fixture/include";
      env.LIBRARY_PATH = "/fixture/lib";
    }
    const remote = resolve(directory(), "remote.git");
    execFileSync("git", ["init", "--bare", "-q", remote], { env });
    git("remote", "add", "origin", remote);
    mkdirSync(resolve(root, ".githooks"));
    mkdirSync(resolve(root, "scripts"));
    writeFileSync(resolve(root, ".githooks/pre-push"), readFileSync(".githooks/pre-push", "utf8"));
    writeFileSync(
      resolve(root, "package.json"),
      JSON.stringify({ scripts: { "verify:push": "bun scripts/verify-push.ts" } }),
    );
    const entry = pathToFileURL(resolve("scripts/verify-push.ts")).href;
    writeFileSync(
      resolve(root, "scripts/verify-push.ts"),
      `
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { checkedSource, assertPushMatchesHead, verificationEnvironment, verifyPush } from ${JSON.stringify(entry)};
import { buildEnvironmentFingerprint } from ${JSON.stringify(pathToFileURL(resolve("scripts/build-reuse.ts")).href)};
const root = process.cwd();
const env = verificationEnvironment(root);
for (const name of Object.keys(process.env)) if (!(name in env)) delete process.env[name];
const before = checkedSource(root, env);
assertPushMatchesHead(readFileSync(0, "utf8"), root, before.head, env);
await verifyPush({
  directory: root + "/.local/proof", source: () => checkedSource(root, env), environment: () => buildEnvironmentFingerprint(env), reusable: true,
  check: async (log) => {
    const counter = root + "/.local/count";
    const count = Number(existsSync(counter) ? readFileSync(counter, "utf8") : 0) + 1;
    writeFileSync(counter, String(count));
    writeFileSync(root + "/.local/environment-" + count + ".json", JSON.stringify(Object.fromEntries(Object.entries(env).map(([key, value]) => [key, buildEnvironmentFingerprint({ [key]: value })]))));
    writeFileSync(log, "fabricated verifier input, not application acceptance");
    if (!existsSync(root + "/.local/allow")) throw new Error("expected fixture failure");
  }
});
`,
    );
    git("add", ".");
    git("commit", "-qm", "test: disposable push gate");
    installHooks(root);
    const push = (branch: string) =>
      spawnSync("git", ["push", "origin", `HEAD:refs/heads/${branch}`], {
        cwd: root,
        env,
        encoding: "utf8",
        timeout: 15_000,
      });
    const failed = push("first");
    expect(failed.status, failed.stderr).not.toBe(0);
    expect(git("ls-remote", "origin")).toBe("");
    writeFileSync(resolve(root, ".local/allow"), "yes");
    const manual = spawnSync("mise", ["exec", "--", "bun", "run", "verify:push", "--hook"], {
      cwd: root,
      env,
      input: `refs/heads/main ${git("rev-parse", "HEAD")} refs/heads/main ${"0".repeat(40)}\n`,
      encoding: "utf8",
      timeout: 15_000,
    });
    expect(manual.status, manual.stderr).toBe(0);
    const passed = push("first");
    expect(passed.status, passed.stderr).toBe(0);
    const repeated = push("second");
    expect(repeated.status, repeated.stderr).toBe(0);
    let changedEnvironmentKeys: string[] = [];
    if (existsSync(resolve(root, ".local/environment-3.json"))) {
      const manualEnvironment = JSON.parse(
        readFileSync(resolve(root, ".local/environment-2.json"), "utf8"),
      );
      const hookEnvironment = JSON.parse(
        readFileSync(resolve(root, ".local/environment-3.json"), "utf8"),
      );
      changedEnvironmentKeys = [
        ...new Set([...Object.keys(manualEnvironment), ...Object.keys(hookEnvironment)]),
      ].filter((key) => manualEnvironment[key] !== hookEnvironment[key]);
    }
    expect(
      readFileSync(resolve(root, ".local/count"), "utf8"),
      `Changed environment keys: ${changedEnvironmentKeys.join(", ")}`,
    ).toBe("2");
  },
  45_000,
);
