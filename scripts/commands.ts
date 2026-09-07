import { commandOptions } from "./arguments.ts";
import { snapshotLocks, assertLocksUnchanged } from "./locks.ts";
import {
  lockedSwiftArguments,
  nativeTests,
  swiftContractTests,
  swiftTests,
} from "./native-check.ts";
import { nativeSuites } from "./native-suites.ts";
import { beginTiming, timedAsync, timedRun } from "./timing.ts";
import { toolOutput as output, requireNativeTools } from "./toolchain.ts";
const command = process.argv[2] ?? "doctor";
const options = commandOptions(
  command,
  process.argv.slice(3),
  command === "check:quick"
    ? { "--scope": "value" }
    : command === "test:native"
      ? { "--suite": "value", "--filter": "value" }
      : {},
);
const scope = options.get("--scope") ?? "all";
if (typeof scope !== "string" || !["server", "native", "all"].includes(scope)) {
  throw new Error("--scope must be server, native or all");
}
const suite = nativeSuites.find((value) => value === (options.get("--suite") ?? "all"));
if (!suite) {
  throw new Error("--suite must be fast, contention, resource or all");
}
const filter = options.get("--filter");
if (typeof filter === "string") {
  new RegExp(filter);
}
beginTiming(
  command,
  command === "check:quick"
    ? { scope }
    : command === "test:native"
      ? { suite, ...(typeof filter === "string" ? { filter } : {}) }
      : {},
);
function native() {
  if (process.platform !== "darwin") {
    throw new Error(
      "Full/native checks require macOS and Xcode 26.6 (17F113). Use check:server for the portable subset.",
    );
  }
}
function doctor(includeNative = process.platform === "darwin") {
  if (includeNative) {
    requireNativeTools();
  }
  const checks: [[string, ...string[]], string][] = [
    [["bun", "--version"], "1.3.13"],
    [["node", "--version"], "v24.14.1"],
  ];
  for (const [cmd, expected] of checks) {
    const actual = output(cmd);
    console.log(`${cmd[0]}: ${actual}`);
    if (actual !== expected) {
      throw new Error(`Expected ${expected}`);
    }
  }
  console.log(
    "Target: local; fake ASR. Cloud commands require an explicit stage and stage config; the opt-in Nova-3 probe requires test:asr --stage dev.",
  );
}
function swiftFiles(): string[] {
  return output([
    "git",
    "ls-files",
    "--cached",
    "--others",
    "--exclude-standard",
    "apps/macos",
    "packages/contracts",
  ])
    .split("\n")
    .filter((path) => path.endsWith(".swift"));
}
const tsformat = (write = false) =>
  timedRun("Repository formatting", [
    "node",
    "node_modules/oxfmt/bin/oxfmt",
    write ? "--write" : "--check",
    ".",
  ]);
const swiftformat = (write = false) => {
  native();
  timedRun("Swift format", [
    "swift",
    "format",
    write ? "format" : "lint",
    ...(write ? ["--in-place"] : ["--strict"]),
    ...swiftFiles(),
  ]);
};
const types = () =>
  timedRun("TypeScript types", ["node", "node_modules/typescript/bin/tsc", "--noEmit"]);
const lint = () =>
  timedRun("TypeScript lint", [
    "node",
    "node_modules/oxlint/bin/oxlint",
    "scripts",
    "apps/server",
    "infra",
    "packages/contracts/src",
    "packages/contracts/test",
    "--ignore-pattern",
    "**/generated/**",
    "--deny-warnings",
  ]);
const units = () => timedRun("Unit tests", ["bun", "run", "test:unit"]);
const workers = () => timedRun("Workers tests", ["bun", "run", "test:workers"]);
const generation = () => timedRun("Contract generation check", ["bun", "run", "contracts:check"]);
let nativeReceipt: string | undefined;
const swiftTest = () => {
  native();
  nativeReceipt = swiftTests();
};
const swiftBuild = () => {
  native();
  timedRun("Native Debug typecheck", ["swift", "build", ...lockedSwiftArguments("apps/macos")]);
};
const macosBuild = () => {
  native();
  for (const variant of ["dev", "personal"]) {
    timedRun(`${variant} app build`, ["bun", "scripts/macos.ts", "build", "--variant", variant]);
  }
};
async function serverBuild() {
  await timedAsync("Worker bundles", async () => {
    const result = await Bun.build({
      entrypoints: ["apps/server/src/local-worker.ts", "apps/server/src/cloud-worker.ts"],
      outdir: "apps/server/dist",
      target: "browser",
      format: "esm",
      external: ["cloudflare:workers"],
    });
    if (!result.success) {
      throw new Error(result.logs.map((log) => log.message).join("\n"));
    }
  });
  console.log("Local and cloud Worker bundles built.");
}
const nativeSmoke = () =>
  // Execute the same entrypoint directly so nested `bun run` does not rewrite
  // PATH or npm bookkeeping and invalidate the verified parent build environment.
  timedRun(
    "Local Worker and native client",
    ["bun", "scripts/local.ts", "--test", "--native-client"],
    {
      env: {
        ...process.env,
        ...(nativeReceipt ? { TRIGO_NATIVE_BUILD_RECEIPT: nativeReceipt } : {}),
      },
    },
  );
const snapshot = snapshotLocks();
try {
  switch (command) {
    case "doctor":
      doctor();
      break;
    case "format":
      tsformat(true);
      swiftformat(true);
      break;
    case "format:check":
      tsformat();
      swiftformat();
      break;
    case "check:files":
      tsformat();
      break;
    case "lint":
      lint();
      swiftformat();
      break;
    case "typecheck":
      types();
      swiftBuild();
      break;
    case "test":
      native();
      units();
      workers();
      swiftTest();
      timedRun("Local Worker smoke", ["bun", "run", "test:local"]);
      break;
    case "build":
      native();
      await serverBuild();
      macosBuild();
      break;
    case "check:server":
      doctor(false);
      tsformat();
      lint();
      types();
      generation();
      units();
      workers();
      await serverBuild();
      break;
    case "check:quick":
      if (scope !== "server") {
        native();
      }
      doctor(scope !== "server");
      if (scope !== "native") {
        timedRun("Quick server checks", ["bun", "run", "check:server"]);
      }
      if (scope !== "server") {
        swiftformat();
        swiftContractTests();
        nativeTests({ suite: "fast" });
      }
      console.log(`Quick checks passed (scope: ${scope}); full acceptance remains separate.`);
      break;
    case "test:native":
      native();
      doctor();
      nativeTests({ suite, ...(typeof filter === "string" ? { filter } : {}) });
      break;
    case "check:macos":
      native();
      doctor();
      swiftformat();
      swiftTest();
      macosBuild();
      nativeSmoke();
      break;
    case "check:macos:smoke":
      native();
      doctor();
      nativeSmoke();
      break;
    case "check":
      native();
      doctor();
      tsformat();
      swiftformat();
      lint();
      types();
      generation();
      units();
      workers();
      swiftTest();
      await serverBuild();
      macosBuild();
      nativeSmoke();
      break;
    default:
      throw new Error(`Unknown command: ${command}`);
  }
} finally {
  assertLocksUnchanged(snapshot);
}
