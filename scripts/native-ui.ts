import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { DateTime } from "effect";

import { commandOptions } from "./arguments.ts";
import { artifactFingerprint, nativeBuildIdentity } from "./build-reuse.ts";
import { sourceState } from "./check-inputs.ts";
import { assertLocksUnchanged, snapshotLocks } from "./locks.ts";
import {
  assertSuccessfulUIRun,
  assertUIAttachments,
  collectNativeUIEvidence,
  shellTestAttachments,
} from "./native-ui-evidence.ts";
import { acquireGUILease } from "./native-ui-lease.ts";
import { beginTiming, timed } from "./timing.ts";
import { requireNativeTools, toolOutput } from "./toolchain.ts";

const shellTests = Object.keys(shellTestAttachments);

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
  const run = resolve(
    ".local/ui-runs",
    `${DateTime.formatIso(DateTime.nowUnsafe()).replaceAll(":", "-")}-${randomUUID().slice(0, 8)}`,
  );
  mkdirSync(run, { recursive: true, mode: 0o700 });
  const bundle = resolve(run, "result.xcresult");
  let release: (() => void) | undefined;
  let failure: { error: unknown } | undefined;
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
    startedAt: DateTime.formatIso(DateTime.nowUnsafe()),
    selection: selected,
    environment: {
      platform: process.platform,
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
    metadata.source = sourceState();
    save();
    beginTiming("macos:ui", { suite, ...(filter === undefined ? {} : { filter }) });
    requireNativeTools();
    release = acquireGUILease();
    const locks = snapshotLocks();
    const identity = nativeBuildIdentity("native-ui-fixture-debug", ["Trigo UI", ...selected]);
    const initialIdentity = identity();
    metadata.inputHash = initialIdentity;
    metadata.osVersion = toolOutput(["sw_vers", "-productVersion"]);
    save();
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
    const keyboard = (...args: string[]) => {
      const result = spawnSync("swift", ["scripts/native-ui-keyboard.swift", ...args], {
        encoding: "utf8",
        timeout: 15_000,
      });
      if (result.error || result.status !== 0) {
        throw new Error(
          `Native UI keyboard ${args[0]} failed: ${result.stderr.trim() || result.error || result.status}`,
        );
      }
      return result.stdout.trim();
    };
    const inputSource = {
      original: keyboard("current"),
      fixture: keyboard("fixture"),
      restored: false,
    };
    metadata.keyboardInputSource = inputSource;
    save();
    const testFailures: unknown[] = [];
    try {
      if (keyboard("select", inputSource.fixture) !== inputSource.fixture) {
        throw new Error("Native UI fixture keyboard layout was not selected");
      }
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
        Math.max(10 * 60_000, selected.length * 120_000 + 60_000),
      );
    } catch (error) {
      testFailures.push(error);
    } finally {
      try {
        inputSource.restored = keyboard("select", inputSource.original) === inputSource.original;
      } catch (error) {
        testFailures.push(error);
      }
      if (!inputSource.restored) {
        testFailures.push(
          new Error("Native UI test did not restore the original keyboard input source"),
        );
      }
      save();
    }
    if (testFailures.length > 0) {
      throw new AggregateError(testFailures, "Native UI test or keyboard restoration failed");
    }
    const evidence = collectNativeUIEvidence(bundle, run);
    assertSuccessfulUIRun(evidence.summary, selected.length);
    assertUIAttachments(evidence.attachments, selected);
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
    failure = { error };
  } finally {
    try {
      release?.();
    } catch (error) {
      metadata.status = "failed";
      metadata.cleanupFailure = error instanceof Error ? error.message : "GUI lease cleanup failed";
      failure ??= { error };
    } finally {
      metadata.finishedAt = DateTime.formatIso(DateTime.nowUnsafe());
      save();
      console.log(`Native UI ${String(metadata.status)}; evidence: ${run}`);
    }
  }
  if (failure) {
    throw failure.error;
  }
}
