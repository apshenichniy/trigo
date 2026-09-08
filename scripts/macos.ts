import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
} from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

import { commandOptions } from "./arguments.ts";
import { buildCurrentArtifact, nativeBuildIdentity } from "./build-reuse.ts";
import { readLocalConfiguration } from "./local-configuration.ts";
import { assertLocksUnchanged, snapshotLocks } from "./locks.ts";
import {
  assertSupportedReplacement,
  installationDestination,
  nativeSigning,
} from "./macos-install.ts";
import { restoreLock } from "./macos-lock.ts";
import { lockedSwiftArguments, swiftPackages } from "./native-check.ts";
import { runNativeUI } from "./native-ui.ts";
import { run } from "./process.ts";
import { beginTiming, timedRun } from "./timing.ts";
import { requireNativeTools, toolOutput } from "./toolchain.ts";
const action = process.argv[2] ?? "build";
if (action === "ui") {
  runNativeUI(process.argv.slice(3));
  process.exit(0);
}
if (!["build", "archive", "run", "install", "dependencies", "setup", "prepare"].includes(action)) {
  throw new Error(`Unknown native action: ${action}`);
}
const options = commandOptions(`native ${action}`, process.argv.slice(3), {
  "--variant": "value",
  ...(["build", "archive", "install", "run"].includes(action)
    ? { "--ad-hoc": "flag" as const }
    : {}),
  ...(["build", "install", "run"].includes(action) ? { "--local-config": "value" as const } : {}),
  ...(["install", "run"].includes(action) ? { "--replace-worktree": "flag" as const } : {}),
});
const variant = options.get("--variant") ?? "dev";
if (variant !== "dev" && variant !== "personal") {
  throw new Error("--variant must be dev or personal");
}
const localConfigPath = options.get("--local-config");
if (localConfigPath !== undefined && (variant !== "dev" || typeof localConfigPath !== "string")) {
  throw new Error(
    "--local-config requires dev build/install/run and a private local configuration path",
  );
}
const adHoc = options.has("--ad-hoc");
const signing = nativeSigning(action, process.env.TRIGO_SIGNING_TEAM, adHoc);
requireNativeTools();
const root = realpathSync(new URL("..", import.meta.url).pathname);
process.chdir(root);
beginTiming(`macos:${action}`, { variant, adHoc });
const scheme = variant === "dev" ? "Trigo Dev" : "Trigo";
const project = "apps/macos/Trigo.xcodeproj";
const canonical = "apps/macos/Locks/Package.resolved";
const nested = `${project}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
const before = action === "dependencies" ? new Map<string, string>() : snapshotLocks();
const derived = resolve(root, ".local/DerivedData");
const worktree = createHash("sha256").update(root).digest("hex").slice(0, 12);
if (localConfigPath !== undefined) {
  readLocalConfiguration(resolve(localConfigPath), worktree);
}
if (adHoc) {
  console.log(
    "Explicit ad-hoc mode: permission and Keychain continuity after rebuilds is not established.",
  );
}
mkdirSync(".local", { recursive: true });
timedRun(
  "Xcode project generation",
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
  try {
    if (action === "prepare") {
      console.log("Generated project and restored the canonical dependency lock.");
    } else if (action === "setup") {
      for (const { path } of swiftPackages) {
        timedRun(`${path} locked dependency setup`, [
          "swift",
          "package",
          ...lockedSwiftArguments(path),
          "resolve",
        ]);
      }
      timedRun("Xcode locked dependency setup", [
        "xcodebuild",
        "-resolvePackageDependencies",
        "-project",
        project,
        "-scheme",
        scheme,
        "-derivedDataPath",
        derived,
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-skipPackageUpdates",
      ]);
    } else {
      const bundle =
        action === "archive"
          ? resolve(root, `.local/archives/${scheme}.xcarchive/Products/Applications/${scheme}.app`)
          : resolve(derived, `Build/Products/Debug/${scheme}.app`);
      const buildCommand = [
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
      ];
      const result = buildCurrentArtifact(
        {
          receipt: resolve(
            root,
            `.local/build-receipts/app-${variant}-${action === "archive" ? "release" : "debug"}.json`,
          ),
          artifact: bundle,
          identity: nativeBuildIdentity(
            action === "archive" ? "app-release" : "app-debug",
            buildCommand,
          ),
          reuse: action === "install" || action === "run",
        },
        () =>
          timedRun(
            `${scheme} ${action === "archive" ? "Release archive" : "Debug build"}`,
            buildCommand,
          ),
        () => {
          const info = resolve(bundle, "Contents/Info.plist");
          const bundleId =
            variant === "dev" ? "io.github.apshenichniy.trigo.dev" : "io.github.apshenichniy.trigo";
          for (const [key, expected] of [
            ["CFBundleIdentifier", bundleId],
            ["TrigoWorktreeID", worktree],
            [
              "NSScreenCaptureUsageDescription",
              "Trigo records audio from your selected application into a local call archive. No screen images are saved.",
            ],
            [
              "NSMicrophoneUsageDescription",
              "Trigo records your microphone as a separate audio track in your local call archive.",
            ],
          ]) {
            if (toolOutput(["plutil", "-extract", key!, "raw", "-o", "-", info]) !== expected) {
              throw new Error(`Built app identity mismatch: ${key}`);
            }
          }
          const plist: unknown = JSON.parse(
            toolOutput(["plutil", "-convert", "json", "-o", "-", info]),
          );
          if (typeof plist !== "object" || plist === null) {
            throw new Error("Built app Info.plist is invalid");
          }
          const transport =
            "NSAppTransportSecurity" in plist ? plist.NSAppTransportSecurity : undefined;
          if (variant === "dev") {
            if (
              typeof transport !== "object" ||
              transport === null ||
              !("NSAllowsLocalNetworking" in transport) ||
              transport.NSAllowsLocalNetworking !== true
            ) {
              throw new Error("Dev app must contain the Boolean local-network ATS allowance");
            }
          } else if (transport !== undefined) {
            throw new Error("Personal app must retain default ATS");
          }
          if (process.env.TRIGO_SIGNING_TEAM || adHoc) {
            run(["codesign", "--verify", "--strict", bundle]);
          }
          if (readFileSync(nested, "utf8") !== readFileSync(canonical, "utf8")) {
            throw new Error("Xcode changed the restored dependency lock");
          }
          assertLocksUnchanged(before);
        },
      );
      if (result === "reused") {
        console.log(`Reused the verified current-source ${scheme} Debug app build.`);
      }
      if (action === "run" || action === "install") {
        const applications = resolve(homedir(), "Applications");
        mkdirSync(applications, { recursive: true });
        const destination = installationDestination(
          applications,
          variant,
          worktree,
          localConfigPath !== undefined,
        );
        if (
          toolOutput(["ps", "-axo", "comm="])
            .split("\n")
            .some((path) => path.trim().startsWith(`${destination}/`))
        ) {
          throw new Error("Quit the destination app before replacing its installed bundle");
        }
        const identity = (path: string) => ({
          bundleId: toolOutput([
            "plutil",
            "-extract",
            "CFBundleIdentifier",
            "raw",
            "-o",
            "-",
            resolve(path, "Contents/Info.plist"),
          ]),
          worktree: toolOutput([
            "plutil",
            "-extract",
            "TrigoWorktreeID",
            "raw",
            "-o",
            "-",
            resolve(path, "Contents/Info.plist"),
          ]),
          requirement: toolOutput(["codesign", "-d", "-r-", path]),
        });
        if (existsSync(destination)) {
          if (lstatSync(destination).isSymbolicLink()) {
            throw new Error("Installed app must not be a symlink");
          }
          assertSupportedReplacement(
            identity(destination),
            identity(bundle),
            options.has("--replace-worktree"),
            adHoc,
          );
        }
        const staging = `${destination}.installing`;
        const backup = `${destination}.previous`;
        if (existsSync(staging) || existsSync(backup)) {
          throw new Error(
            "A previous installation needs review; staging/backup paths were retained",
          );
        }
        run(["ditto", bundle, staging]);
        run(["codesign", "--verify", "--strict", staging]);
        if (existsSync(destination)) {
          renameSync(destination, backup);
        }
        try {
          renameSync(staging, destination);
        } catch (error) {
          if (existsSync(backup)) {
            renameSync(backup, destination);
          }
          throw error;
        }
        if (existsSync(backup)) {
          rmSync(backup, { recursive: true });
        }
        if (action === "run") {
          run(
            localConfigPath
              ? ["open", "-n", destination, "--args", "--local-config", resolve(localConfigPath)]
              : ["open", "-n", destination],
          );
        }
        console.log(`Installed ${destination}`);
        if (localConfigPath) {
          console.log(
            "Local data and installation are isolated; this signed Dev bundle shares its macOS permission identity with ordinary Trigo Dev.",
          );
        }
      }
    }
    if (readFileSync(nested, "utf8") !== readFileSync(canonical, "utf8")) {
      throw new Error("Xcode changed the restored dependency lock");
    }
  } finally {
    assertLocksUnchanged(before);
  }
}
