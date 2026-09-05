import { toolOutput as output, requireNativeTools } from "./toolchain.ts";
import { snapshotLocks, assertLocksUnchanged } from "./locks.ts";
import { run } from "./process.ts";
const command = process.argv[2] ?? "doctor";
function native() {
  if (process.platform !== "darwin")
    throw new Error(
      "Full/native checks require macOS and Xcode 26.6 (17F113). Use check:server for the portable subset.",
    );
}
function doctor() {
  if (process.platform === "darwin") requireNativeTools();
  const checks: [[string, ...string[]], string][] = [
    [["bun", "--version"], "1.3.13"],
    [["node", "--version"], "v24.14.1"],
  ];
  for (const [cmd, expected] of checks) {
    const actual = output(cmd);
    console.log(`${cmd[0]}: ${actual}`);
    if (actual !== expected) throw new Error(`Expected ${expected}`);
  }
  console.log(
    "Target: local; fake ASR. Cloud commands require an explicit stage and stage config; provider probes (#13) remain unavailable.",
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
  run(["node", "node_modules/oxfmt/bin/oxfmt", write ? "--write" : "--check", "."]);
const swiftformat = (write = false) => {
  native();
  run([
    "swift",
    "format",
    write ? "format" : "lint",
    ...(write ? ["--in-place"] : ["--strict"]),
    ...swiftFiles(),
  ]);
};
const types = () => run(["node", "node_modules/typescript/bin/tsc", "--noEmit"]);
const lint = () =>
  run([
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
const units = () => run(["bun", "run", "test:unit"]);
const workers = () => run(["bun", "run", "test:workers"]);
const generation = () => run(["bun", "run", "contracts:check"]);
const swiftTest = () => {
  native();
  for (const path of ["packages/contracts", "apps/macos"])
    run(["swift", "test", "--package-path", path, "--force-resolved-versions", "--skip-update"]);
};
const swiftBuild = () => {
  native();
  run([
    "swift",
    "build",
    "--package-path",
    "apps/macos",
    "--force-resolved-versions",
    "--skip-update",
  ]);
};
const macosBuild = () => {
  native();
  for (const variant of ["dev", "personal"])
    run(["bun", "run", "macos:build", "--variant", variant]);
};
async function serverBuild() {
  const result = await Bun.build({
    entrypoints: ["apps/server/src/local-worker.ts", "apps/server/src/cloud-worker.ts"],
    outdir: "apps/server/dist",
    target: "browser",
    format: "esm",
    external: ["cloudflare:workers"],
  });
  if (!result.success) throw new Error(result.logs.map((log) => log.message).join("\n"));
  console.log("Local and cloud Worker bundles built.");
}
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
      run(["bun", "run", "test:local"]);
      break;
    case "build":
      native();
      await serverBuild();
      macosBuild();
      break;
    case "check:server":
      doctor();
      tsformat();
      lint();
      types();
      generation();
      units();
      workers();
      await serverBuild();
      break;
    case "check:macos":
      native();
      doctor();
      swiftformat();
      swiftTest();
      macosBuild();
      run(["bun", "run", "test:local"]);
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
      run(["bun", "run", "test:local"]);
      break;
    default:
      throw new Error(`Unknown command: ${command}`);
  }
} finally {
  assertLocksUnchanged(snapshot);
}
