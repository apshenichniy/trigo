import { createHash, randomUUID } from "node:crypto";
import {
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, relative, resolve } from "node:path";

import { inputFingerprint } from "./check-inputs.ts";
import { nativeToolchain } from "./native-cache.ts";

export function artifactFingerprint(path: string): string {
  const root = realpathSync(path);
  const hash = createHash("sha256");
  function visit(full: string): void {
    const stat = lstatSync(full);
    hash.update(`${relative(root, full)}\0${stat.mode}\0`);
    if (stat.isSymbolicLink()) {
      const target = relative(root, realpathSync(full));
      if (target === ".." || target.startsWith("../")) {
        throw new Error("Artifact symlink escapes its bundle");
      }
      hash.update(readlinkSync(full));
    } else if (stat.isDirectory()) {
      for (const name of readdirSync(full).sort()) {
        visit(resolve(full, name));
      }
    } else if (stat.isFile()) {
      hash.update(readFileSync(full));
    } else {
      throw new Error("Unsupported artifact entry");
    }
    hash.update("\0");
  }
  visit(root);
  return hash.digest("hex");
}

const volatileEnvironment = new Set([
  "_",
  "SHLVL",
  "PWD",
  "OLDPWD",
  "TRIGO_CHECK_RUN_ID",
  "TRIGO_CHECK_PARENT_SPAN_ID",
  "TRIGO_NATIVE_BUILD_RECEIPT",
  "TRIGO_TIMINGS_FILE",
  "GITHUB_STEP_SUMMARY",
  "GITHUB_OUTPUT",
  "npm_lifecycle_event",
  "npm_lifecycle_script",
  "npm_command",
]);

/** Include inherited build settings without writing their values to receipts or logs. */
export function buildEnvironmentFingerprint(env: NodeJS.ProcessEnv): string {
  return createHash("sha256")
    .update(
      JSON.stringify(
        Object.entries(env)
          .filter(([key]) => !volatileEnvironment.has(key))
          .sort(([a], [b]) => a.localeCompare(b)),
      ),
    )
    .digest("hex");
}

export function nativeBuildIdentity(configuration: string, flags: readonly string[]): () => string {
  const root = realpathSync(process.cwd());
  // Tool selection stays fixed within this synchronous invocation. The receiving
  // command samples it again before using a receipt.
  const toolchain = nativeToolchain();
  return () =>
    createHash("sha256")
      .update(
        JSON.stringify({
          version: 1,
          root,
          platform: process.platform,
          architecture: process.arch,
          configuration,
          flags,
          toolchain,
          environment: buildEnvironmentFingerprint(process.env),
          inputs: inputFingerprint(
            [
              "apps/macos",
              "packages/contracts",
              "scripts",
              "mise.toml",
              "bun.lock",
              "package.json",
            ],
            root,
          ),
        }),
      )
      .digest("hex");
}

export function artifactReceiptMatches(
  receipt: string,
  identity: string,
  artifact: string,
  owner?: string,
): boolean {
  try {
    const value: unknown = JSON.parse(readFileSync(receipt, "utf8"));
    if (!value || typeof value !== "object") {
      return false;
    }
    return (
      "version" in value &&
      value.version === 1 &&
      "root" in value &&
      value.root === realpathSync(process.cwd()) &&
      "identity" in value &&
      value.identity === identity &&
      "artifact" in value &&
      value.artifact === realpathSync(artifact) &&
      (owner === undefined || ("owner" in value && value.owner === owner)) &&
      "fingerprint" in value &&
      value.fingerprint === artifactFingerprint(artifact)
    );
  } catch {
    return false;
  }
}

export function supportsBuildReuse(): boolean {
  return !["XCODE_XCCONFIG_FILE", "TOOLCHAINS", "SWIFT_EXEC", "CC", "CXX", "SDKROOT"].some(
    (key) => process.env[key],
  );
}

export function buildCurrentArtifact(
  options: {
    receipt: string;
    artifact: string;
    identity: () => string;
    reuse: boolean;
    owner?: string;
  },
  build: () => void,
  verify: () => void,
): "built" | "reused" {
  const identity = options.identity();
  // External tool overrides may refer to files outside the tracked input graph.
  if (
    options.reuse &&
    supportsBuildReuse() &&
    artifactReceiptMatches(options.receipt, identity, options.artifact, options.owner)
  ) {
    verify();
    return "reused";
  }
  // A failed fresh build cannot leave an earlier success receipt available.
  rmSync(options.receipt, { force: true });
  build();
  verify();
  if (options.identity() !== identity) {
    throw new Error(
      "Build inputs changed while compilation was running; check the current sources again",
    );
  }
  const value = {
    version: 1,
    root: realpathSync(process.cwd()),
    identity,
    ...(options.owner === undefined ? {} : { owner: options.owner }),
    artifact: realpathSync(options.artifact),
    fingerprint: artifactFingerprint(options.artifact),
  };
  mkdirSync(dirname(options.receipt), { recursive: true });
  const temporary = `${options.receipt}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    renameSync(temporary, options.receipt);
  } finally {
    rmSync(temporary, { force: true });
  }
  return "built";
}
