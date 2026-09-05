import { requireNativeTools, toolOutput } from "./toolchain.ts";
import { assertLocksUnchanged, snapshotLocks } from "./locks.ts";
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { homedir } from "node:os";
import { run } from "./process.ts";
import { restoreLock } from "./macos-lock.ts";
requireNativeTools();
const root = realpathSync(new URL("..", import.meta.url).pathname);
process.chdir(root);
const action = process.argv[2] ?? "build";
const variantIndex = process.argv.indexOf("--variant");
const variant = variantIndex < 0 ? "dev" : process.argv[variantIndex + 1];
if (variant !== "dev" && variant !== "personal")
  throw new Error("--variant must be dev or personal");
if (!["build", "archive", "run", "dependencies"].includes(action))
  throw new Error(`Unknown native action: ${action}`);
const scheme = variant === "dev" ? "Trigo Dev" : "Trigo";
const project = "apps/macos/Trigo.xcodeproj";
const canonical = "apps/macos/Locks/Package.resolved";
const nested = `${project}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
const before = action === "dependencies" ? new Map<string, string>() : snapshotLocks();
const derived = resolve(root, ".local/DerivedData");
const worktree = createHash("sha256").update(root).digest("hex").slice(0, 12);
mkdirSync(".local", { recursive: true });
run(
  [
    "xcodegen",
    "generate",
    "--spec",
    "apps/macos/project.yml",
    "--use-cache",
    "--cache-path",
    ".local/xcodegen.cache",
  ],
  { env: { ...process.env, TRIGO_WORKTREE_ID: worktree } },
);
if (action === "dependencies") {
  run(["swift", "package", "--package-path", "packages/contracts", "update"]);
  run(["swift", "package", "--package-path", "apps/macos", "update"]);
  run([
    "xcodebuild",
    "-resolvePackageDependencies",
    "-project",
    project,
    "-scheme",
    scheme,
    "-derivedDataPath",
    derived,
  ]);
  mkdirSync("apps/macos/Locks", { recursive: true });
  copyFileSync(existsSync(nested) ? nested : "apps/macos/Package.resolved", canonical);
  console.log("Dependency locks updated explicitly; review the diff and run bun run check.");
} else {
  restoreLock(canonical, nested);
  const signed = process.env.TRIGO_SIGNING_TEAM;
  const signing = signed
    ? [`DEVELOPMENT_TEAM=${signed}`, "CODE_SIGN_IDENTITY=Apple Development"]
    : action === "run"
      ? ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES"]
      : ["CODE_SIGNING_ALLOWED=NO"];
  try {
    run([
      "xcodebuild",
      "-project",
      project,
      "-scheme",
      scheme,
      "-configuration",
      action === "archive" ? "Release" : "Debug",
      "-destination",
      "platform=macOS",
      "-derivedDataPath",
      derived,
      "-disableAutomaticPackageResolution",
      "-onlyUsePackageVersionsFromResolvedFile",
      "-skipPackageUpdates",
      `TRIGO_WORKTREE_ID=${worktree}`,
      ...signing,
      ...(action === "archive"
        ? ["-archivePath", resolve(root, `.local/archives/${scheme}.xcarchive`), "archive"]
        : ["build"]),
    ]);
    if (readFileSync(nested, "utf8") !== readFileSync(canonical, "utf8"))
      throw new Error("Xcode changed the restored dependency lock");
    const bundle =
      action === "archive"
        ? resolve(root, `.local/archives/${scheme}.xcarchive/Products/Applications/${scheme}.app`)
        : resolve(derived, `Build/Products/Debug/${scheme}.app`);
    const info = resolve(bundle, "Contents/Info.plist");
    const bundleId =
      variant === "dev" ? "io.github.apshenichniy.trigo.dev" : "io.github.apshenichniy.trigo";
    for (const [key, expected] of [
      ["CFBundleIdentifier", bundleId],
      ["TrigoWorktreeID", worktree],
    ]) {
      if (toolOutput(["plutil", "-extract", key!, "raw", "-o", "-", info]) !== expected)
        throw new Error(`Built app identity mismatch: ${key}`);
    }
    if (action === "run") {
      const applications = resolve(homedir(), "Applications");
      mkdirSync(applications, { recursive: true });
      const destination = resolve(applications, `${scheme}.app`);
      run(["ditto", resolve(derived, `Build/Products/Debug/${scheme}.app`), destination]);
      run(["open", destination]);
      console.log(`Installed ${destination}`);
    }
  } finally {
    assertLocksUnchanged(before);
  }
}
