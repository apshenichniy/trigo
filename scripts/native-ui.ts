import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { DateTime } from "effect";

import { commandOptions } from "./arguments.ts";
import { artifactFingerprint, nativeBuildIdentity } from "./build-reuse.ts";
import { sourceState } from "./check-inputs.ts";
import { assertLocksUnchanged, snapshotLocks } from "./locks.ts";
import { assertSuccessfulUIRun, collectNativeUIEvidence } from "./native-ui-evidence.ts";
import { beginTiming, timed } from "./timing.ts";
import { requireNativeTools, toolOutput } from "./toolchain.ts";

const shellTests = [
  "testBackgroundMenuLibraryReopenAndSettings",
  "testRealCoordinatorStartMuteFinishAndBackgroundQuit",
  "testDeniedAccessRetainsSettingsAndPreventsStart",
] as const;

function acquireGUILease(): () => void {
  const path = resolve(tmpdir(), "trigo-native-ui-acceptance.lock");
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const descriptor = openSync(path, "wx", 0o600);
      try {
        writeFileSync(descriptor, String(process.pid));
      } finally {
        closeSync(descriptor);
      }
      return () => {
        if (readFileSync(path, "utf8") === String(process.pid)) {
          unlinkSync(path);
        }
      };
    } catch (error) {
      if (!(error instanceof Error) || !("code" in error) || error.code !== "EEXIST") {
        throw error;
      }
      const pid = Number(readFileSync(path, "utf8"));
      if (!Number.isSafeInteger(pid) || pid < 1) {
        throw new Error("The native UI lease is invalid; inspect it before retrying");
      }
      try {
        process.kill(pid, 0);
      } catch (failure) {
        if (failure instanceof Error && "code" in failure && failure.code === "ESRCH") {
          unlinkSync(path);
          continue;
        }
        throw failure;
      }
      throw new Error(`Another native UI acceptance owns the GUI session (PID ${pid})`);
    }
  }
  throw new Error("Could not acquire the native UI acceptance lease");
}

export function runNativeUI(args: string[]): void {
  const options = commandOptions("native ui", args, { "--suite": "value", "--filter": "value" });
  const suite = options.get("--suite") ?? "shell";
  if (suite !== "shell" && suite !== "all") {
    throw new Error("--suite must be shell or all");
  }
  const filter = options.get("--filter");
  if (filter !== undefined && typeof filter !== "string") {
    throw new Error("--filter requires a test-name expression");
  }
  const expression = filter === undefined ? undefined : new RegExp(filter);
  const selected = shellTests.filter((test) => !expression || expression.test(test));
  if (selected.length === 0) {
    throw new Error("No native UI tests matched the selection");
  }
  requireNativeTools();
  beginTiming("macos:ui", { suite, ...(filter === undefined ? {} : { filter }) });
  const release = acquireGUILease();
  const locks = snapshotLocks();
  const run = resolve(
    ".local/ui-runs",
    `${DateTime.formatIso(DateTime.nowUnsafe()).replaceAll(":", "-")}-${randomUUID().slice(0, 8)}`,
  );
  mkdirSync(run, { recursive: true, mode: 0o700 });
  const bundle = resolve(run, "result.xcresult");
  const identity = nativeBuildIdentity("native-ui-fixture-debug", ["Trigo UI", ...selected]);
  const initialIdentity = identity();
  const commands: {
    phase: string;
    command: string[];
    exitCode: number | null;
    signal: string | null;
    seconds: number;
  }[] = [];
  const metadata: Record<string, unknown> = {
    schemaVersion: 1,
    status: "running",
    source: sourceState(),
    inputHash: initialIdentity,
    startedAt: DateTime.formatIso(DateTime.nowUnsafe()),
    selection: selected,
    environment: {
      os: toolOutput(["sw_vers", "-productVersion"]),
      architecture: process.arch,
      fixtureBundle: "io.github.apshenichniy.trigo.fixture.desktop",
    },
    commands,
  };
  const save = () =>
    writeFileSync(resolve(run, "run.json"), `${JSON.stringify(metadata, null, 2)}\n`);
  save();
  function execute(phase: string, command: string[], timeout: number): void {
    timed(phase, () => {
      const started = performance.now();
      const descriptor = openSync(resolve(run, `${phase}.log`), "w", 0o600);
      let result;
      try {
        result = spawnSync(command[0]!, command.slice(1), {
          stdio: ["ignore", descriptor, descriptor],
          timeout,
        });
      } finally {
        closeSync(descriptor);
      }
      commands.push({
        phase,
        command,
        exitCode: result.status,
        signal: result.signal,
        seconds: (performance.now() - started) / 1000,
      });
      save();
      if (result.error || result.status !== 0) {
        throw new Error(`${phase} failed; inspect ${resolve(run, `${phase}.log`)}`);
      }
    });
  }
  try {
    execute("prepare", ["bun", "scripts/macos.ts", "prepare", "--variant", "dev"], 60_000);
    const common = [
      "-project",
      "apps/macos/Trigo.xcodeproj",
      "-scheme",
      "Trigo UI",
      "-configuration",
      "Debug",
      "-destination",
      "platform=macOS,arch=arm64",
      "-derivedDataPath",
      ".local/DerivedData",
      "-disableAutomaticPackageResolution",
      "-onlyUsePackageVersionsFromResolvedFile",
      "-skipPackageUpdates",
    ];
    execute("build", ["xcodebuild", "build-for-testing", ...common], 15 * 60_000);
    metadata.fixtureBundleHash = artifactFingerprint(
      resolve(".local/DerivedData/Build/Products/Debug/Trigo UI Fixture.app"),
    );
    execute(
      "tests",
      [
        "xcodebuild",
        "test-without-building",
        ...common,
        "-parallel-testing-enabled",
        "NO",
        "-test-timeouts-enabled",
        "YES",
        "-maximum-test-execution-time-allowance",
        "120",
        "-resultBundlePath",
        bundle,
        ...selected.map((name) => `-only-testing:TrigoUITests/DesktopShellUITests/${name}`),
      ],
      10 * 60_000,
    );
    assertSuccessfulUIRun(collectNativeUIEvidence(bundle, run), selected.length);
    if (identity() !== initialIdentity) {
      throw new Error("Native UI inputs changed during the run");
    }
    assertLocksUnchanged(locks);
    metadata.status = "passed";
  } catch (error) {
    metadata.status = "failed";
    metadata.failure = error instanceof Error ? error.message : "Native UI acceptance failed";
    if (existsSync(bundle)) {
      try {
        collectNativeUIEvidence(bundle, run);
      } catch (collection) {
        metadata.collectionFailure =
          collection instanceof Error ? collection.message : "Evidence collection failed";
      }
    }
    throw error;
  } finally {
    metadata.finishedAt = DateTime.formatIso(DateTime.nowUnsafe());
    try {
      save();
    } finally {
      release();
    }
    console.log(`Native UI ${String(metadata.status)}; evidence: ${run}`);
  }
}
