import { execFileSync, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { release } from "node:os";
import { resolve } from "node:path";
import { finished } from "node:stream/promises";

import { buildEnvironmentFingerprint, supportsBuildReuse } from "./build-reuse.ts";
import { inputFingerprint } from "./check-inputs.ts";
import { nativeToolchain } from "./native-cache.ts";

type Source = { head: string; tree: string; fingerprint: string };
const digest = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const git = (root: string, args: string[], env = process.env) =>
  execFileSync("git", args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  }).trim();

/** Git exports repository variables to hooks; they must not leak into fixture repositories. */
export function verificationEnvironment(root: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const name of git(root, ["rev-parse", "--local-env-vars"]).split("\n")) {
    delete env[name];
  }
  const gitExec = git(root, ["--exec-path"]);
  // Git prepends its private executables to PATH. These are not build inputs.
  env.PATH = env.PATH?.split(":")
    .filter((path) => path !== gitExec)
    .join(":");
  delete env.MANPATH;
  if (process.platform === "darwin" && env.GIT_EXEC_PATH === gitExec) {
    // Apple's /usr/bin/git shim appends these defaults through xcrun. Preserve
    // any caller-supplied paths preceding that one added suffix.
    for (const [key, suffix] of [
      ["CPATH", "/usr/local/include"],
      ["LIBRARY_PATH", "/usr/local/lib"],
    ] as const) {
      const paths = env[key]?.split(":");
      if (paths?.at(-1) === suffix) {
        paths.pop();
        if (paths.length) {
          env[key] = paths.join(":");
        } else {
          delete env[key];
        }
      }
    }
    if (env.SDKROOT) {
      const sdk = execFileSync("xcrun", ["--sdk", "macosx", "--show-sdk-path"], {
        encoding: "utf8",
      }).trim();
      if (realpathSync(env.SDKROOT) === realpathSync(sdk)) {
        delete env.SDKROOT;
      }
    }
  }
  delete env.GIT_EXEC_PATH;
  return env;
}

export function checkedSource(root: string, env = process.env, expectedHead?: string): Source {
  const head = git(root, ["rev-parse", "HEAD"], env);
  if (expectedHead !== undefined && head !== expectedHead) {
    throw new Error("HEAD changed after verification admission; check the intended commit again");
  }
  if (git(root, ["status", "--porcelain=v1", "--untracked-files=all"], env)) {
    throw new Error(
      "Commit or preserve your working changes before verification; only a clean pushed HEAD can be checked",
    );
  }
  if (
    git(root, ["ls-files", "-v"], env)
      .split("\n")
      .some((line) => /^[a-zS] /.test(line))
  ) {
    throw new Error(
      "Clear assume-unchanged/skip-worktree flags before verifying the pushed source",
    );
  }
  const source = {
    head,
    tree: git(root, ["rev-parse", `${head}^{tree}`], env),
    fingerprint: inputFingerprint(["."], root),
  };
  if (git(root, ["rev-parse", "HEAD"], env) !== head) {
    throw new Error("HEAD changed while reading source; check the intended commit again");
  }
  return source;
}

export function assertPushMatchesHead(
  input: string,
  root: string,
  head: string,
  env = process.env,
): boolean {
  let updated = false;
  for (const line of input.split("\n").filter(Boolean)) {
    const fields = line.trim().split(/\s+/);
    if (fields.length !== 4 || !/^[0-9a-f]{40,64}$/.test(fields[1] ?? "")) {
      throw new Error("Invalid Git pre-push input");
    }
    const revision = fields[1]!;
    if (/^0+$/.test(revision)) {
      continue;
    }
    if (git(root, ["rev-parse", `${revision}^{commit}`], env) !== head) {
      throw new Error(
        "Push each revision from its own checked-out worktree; this push includes a commit other than HEAD",
      );
    }
    updated = true;
  }
  return updated;
}

type VerificationOptions = {
  directory: string;
  source: () => Source;
  environment: () => string;
  check: (log: string) => Promise<void>;
  reusable: boolean;
};

/** A receipt records completed local checks, never a remote status or a build-cache hit. */
export async function verifyPush(
  options: VerificationOptions,
): Promise<{ reused: boolean; receipt: string }> {
  const before = options.source();
  const environment = options.environment();
  const identity = digest(
    JSON.stringify({ version: 1, tree: before.tree, inputs: before.fingerprint, environment }),
  );
  const assertUnchanged = () => {
    if (
      JSON.stringify(options.source()) !== JSON.stringify(before) ||
      options.environment() !== environment
    ) {
      throw new Error(
        "Source or environment changed during verification; check the current commit again",
      );
    }
  };
  mkdirSync(options.directory, { recursive: true });
  const receipt = resolve(options.directory, "success.json");
  if (options.reusable) {
    let matches = false;
    try {
      const saved = JSON.parse(readFileSync(receipt, "utf8"));
      matches =
        saved.version === 1 &&
        saved.status === "passed" &&
        saved.identity === identity &&
        saved.logSHA256 === digest(readFileSync(saved.log));
    } catch {
      // Missing, malformed or incomplete proof requires an actual full check.
    }
    if (matches) {
      assertUnchanged();
      return { reused: true, receipt };
    }
  }
  rmSync(receipt, { force: true });
  const run = resolve(
    options.directory,
    `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID()}`,
  );
  mkdirSync(run);
  const log = resolve(run, "check.log");
  const result = {
    version: 1,
    identity,
    source: before,
    environment,
    log,
    startedAt: new Date().toISOString(),
  };
  try {
    await options.check(log);
    assertUnchanged();
    const completed = {
      ...result,
      status: "passed",
      completedAt: new Date().toISOString(),
      logSHA256: digest(readFileSync(log)),
    };
    const serialized = `${JSON.stringify(completed, null, 2)}\n`;
    writeFileSync(resolve(run, "result.json"), serialized);
    const temporary = `${receipt}.${randomUUID()}`;
    writeFileSync(temporary, serialized);
    renameSync(temporary, receipt);
    return { reused: false, receipt };
  } catch (error) {
    writeFileSync(
      resolve(run, "result.json"),
      `${JSON.stringify({ ...result, status: "failed", completedAt: new Date().toISOString(), error: error instanceof Error ? error.message : "Verification failed" }, null, 2)}\n`,
    );
    throw error;
  }
}

async function fullCheck(root: string, env: NodeJS.ProcessEnv, log: string): Promise<void> {
  const { createWriteStream } = await import("node:fs");
  const output = createWriteStream(log, { flags: "wx" });
  const child = spawn("bun", ["run", "check"], {
    cwd: root,
    env,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (data: Buffer) => {
    process.stdout.write(data);
    output.write(data);
  });
  child.stderr.on("data", (data: Buffer) => {
    process.stderr.write(data);
    output.write(data);
  });
  const stop = (signal: NodeJS.Signals) => {
    if (child.pid && child.exitCode === null && child.signalCode === null) {
      try {
        process.kill(-child.pid, signal);
      } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) {
          throw error;
        }
      }
    }
  };
  const interrupt = () => stop("SIGINT");
  const terminate = () => stop("SIGTERM");
  let executionError: Error | undefined;
  child.on("error", (error) => {
    executionError = error;
  });
  output.on("error", (error) => {
    executionError = error;
    stop("SIGTERM");
  });
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", terminate);
  try {
    const code = await new Promise<number | null>((accept) => {
      child.on("close", accept);
    });
    output.end();
    await finished(output);
    if (executionError) {
      throw executionError;
    }
    if (code !== 0) {
      throw new Error(`Full local verification failed (${code ?? "signal"}); see ${log}`);
    }
  } finally {
    stop("SIGTERM");
    process.off("SIGINT", interrupt);
    process.off("SIGTERM", terminate);
    output.end();
  }
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args.length === 1 && args[0] !== "--hook")) {
    throw new Error("Usage: bun run verify:push (Git supplies --hook internally)");
  }
  const root = realpathSync(git(process.cwd(), ["rev-parse", "--show-toplevel"]));
  process.chdir(root);
  const env = verificationEnvironment(root);
  // Also clean the current process: fingerprint helpers and nested tool queries use it.
  for (const name of Object.keys(process.env)) {
    if (!(name in env)) {
      delete process.env[name];
    }
  }
  Object.assign(process.env, env);
  const head = git(root, ["rev-parse", "HEAD"], env);
  if (
    process.argv.includes("--hook") &&
    !assertPushMatchesHead(readFileSync(0, "utf8"), root, head, env)
  ) {
    process.exit(0);
  }
  const { acquireLocalLease } = await import("./native-ui-lease.ts");
  const common = git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"], env);
  const releaseLease = acquireLocalLease(
    resolve(common, "trigo-local-verification.lock"),
    "local verification",
  );
  try {
    const tools = [
      ...nativeToolchain(),
      execFileSync("bun", ["--version"], { env, encoding: "utf8" }).trim(),
      execFileSync("node", ["--version"], { env, encoding: "utf8" }).trim(),
      execFileSync("python3", ["--version"], { env, encoding: "utf8" }).trim(),
    ];
    const result = await verifyPush({
      directory: resolve(root, ".local/push-verification"),
      source: () => checkedSource(root, env, head),
      environment: () =>
        digest(
          JSON.stringify({
            root,
            platform: process.platform,
            architecture: process.arch,
            os: release(),
            tools,
            environment: buildEnvironmentFingerprint(env),
          }),
        ),
      check: (log) => fullCheck(root, env, log),
      reusable: supportsBuildReuse(),
    });
    console.log(
      `${result.reused ? "Reused matching successful" : "Completed full"} local verification: ${result.receipt}`,
    );
  } finally {
    releaseLease();
  }
}
