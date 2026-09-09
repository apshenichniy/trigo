import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";

const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const shellTestAttachments: Readonly<Record<string, readonly string[]>> = {
  testReaderApproximateTimingRetainsTextAndDisablesEmptyPlayback: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-reader-approximate-timing.png",
  ],
  testReaderSelectionRevisionsPlaybackAndNarrowDarkLayout: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-reader-light.png",
    "shell-reader-accessibility.txt",
    "shell-reader-retained-state.txt",
    "shell-reader-narrow-dark.png",
  ],
  testReaderUnicodeNamesGroupingAndExplicitConflictChoice: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-reader-group-editor.png",
    "shell-reader-grouped-state.txt",
    "shell-reader-conflict-comparison.png",
    "shell-reader-conflict-resolved-state.txt",
  ],
  testReaderNoSpeechUnavailablePlaybackAndRecovery: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-reader-playback-unavailable.png",
    "shell-reader-no-speech-playback.png",
    "shell-reader-playback-recovered-state.txt",
  ],
  testBackgroundMenuLibraryReopenAndSettings: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-library-empty-light.png",
    "shell-library-accessibility.txt",
    "shell-settings-general.png",
    "shell-settings-connection.png",
    "shell-settings-diagnostics.png",
  ],
  testRealCoordinatorStartMuteFinishAndBackgroundQuit: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-recording-started.png",
  ],
  testDeniedAccessRetainsSettingsAndPreventsStart: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-denied-capture-access.png",
    "shell-permission-status.png",
  ],
  testGestureSetupDenialKeepsMenuStartAvailable: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-gesture-disabled.png",
    "shell-gesture-denied.png",
  ],
  testCompactPanelMeasuredSignalsAndMicrophoneAvailability: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-panel-measured.png",
    "shell-panel-accessibility.txt",
    "shell-panel-measured-state.txt",
    "shell-panel-application-only.txt",
    "shell-panel-microphone-only.txt",
    "shell-panel-silent.png",
    "shell-panel-muted.png",
    "shell-panel-microphone-unavailable.png",
    "shell-panel-reattached-muted.txt",
  ],
  testCompactPanelFocusDragHideRevealInFullscreen: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-panel-fullscreen.png",
    "shell-panel-focus-input.png",
    "shell-panel-fullscreen-finished.txt",
  ],
  testCompactPanelPendingMuteKeepsFinishAvailable: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-panel-mute-pending.png",
    "shell-panel-mute-pending-accessibility.txt",
    "shell-panel-next-call-microphone.txt",
  ],
  testCompactPanelCancelRetiresLateStart: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-panel-starting.png",
    "shell-panel-cancelling-late-start.png",
    "shell-panel-cancelling-state.txt",
  ],
  testCompactPanelSaveWaitAndFailureRecovery: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-panel-saving.png",
    "shell-panel-save-failed.png",
    "shell-panel-save-failed-accessibility.txt",
  ],
  testCompactPanelStopFailureRetainsSavedAudio: [
    "fixture-configuration.txt",
    "fixture-final-state.txt",
    "shell-panel-stop-failed.png",
    "shell-panel-stop-failed-accessibility.txt",
    "shell-panel-stop-failed-state.txt",
  ],
};

export type UIAttachment = { test: string; file: string; sha256: string; byteLength: number };

export function assertUIAttachments(
  index: readonly UIAttachment[],
  selected: readonly string[],
): void {
  for (const name of selected) {
    const required = shellTestAttachments[name];
    if (!required) {
      throw new Error(`Native UI test has no required evidence contract: ${name}`);
    }
    for (const filename of required) {
      const matches = index.filter(
        (entry) =>
          entry.test === `DesktopShellUITests/${name}()` && basename(entry.file) === filename,
      );
      if (
        matches.length !== 1 ||
        matches[0]!.byteLength < 1 ||
        !/^[a-f0-9]{64}$/.test(matches[0]!.sha256)
      ) {
        throw new Error(`Missing, empty or duplicate native UI evidence: ${name}/${filename}`);
      }
    }
  }
}

export function assertSuccessfulUIRun(value: unknown, expected: number): void {
  if (
    !record(value) ||
    value.result !== "Passed" ||
    value.totalTestCount !== expected ||
    value.passedTests !== expected ||
    value.failedTests !== 0 ||
    value.skippedTests !== 0 ||
    value.expectedFailures !== 0 ||
    expected < 1
  ) {
    throw new Error("Native UI acceptance did not report the complete non-empty passing selection");
  }
}

export function curatedUIAttachment(name: string): string | null {
  const match =
    /^(shell-[a-z0-9-]+|fixture-configuration|fixture-final-state)_\d+_[A-Fa-f0-9-]+\.(png|txt)$/.exec(
      name,
    );
  return match ? `${match[1]}.${match[2]}` : null;
}

function xcrun(args: string[]): string {
  const result = spawnSync("xcrun", args, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 60_000,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`xcresult collection failed: ${result.error?.message ?? result.stderr.trim()}`);
  }
  return result.stdout;
}

/** Automatic desktop recordings remain in the ignored result/attachment directories.
 * Only explicit fixture-window screenshots and fixture input/state are curated. */
export function collectNativeUIEvidence(
  bundle: string,
  run: string,
): {
  summary: unknown;
  attachments: UIAttachment[];
} {
  const summary: unknown = JSON.parse(
    xcrun(["xcresulttool", "get", "test-results", "summary", "--path", bundle]),
  );
  writeFileSync(resolve(run, "summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
  const attachments = resolve(run, "attachments");
  xcrun(["xcresulttool", "export", "attachments", "--path", bundle, "--output-path", attachments]);
  const manifest: unknown = JSON.parse(readFileSync(resolve(attachments, "manifest.json"), "utf8"));
  if (!Array.isArray(manifest)) {
    throw new Error("Unknown xcresult attachment manifest");
  }
  const index: UIAttachment[] = [];
  for (const test of manifest) {
    if (
      !record(test) ||
      typeof test.testIdentifier !== "string" ||
      !Array.isArray(test.attachments)
    ) {
      throw new Error("Unknown xcresult test attachment entry");
    }
    const directory = test.testIdentifier.replace(/[^a-zA-Z0-9_-]/g, "-");
    for (const attachment of test.attachments) {
      if (
        !record(attachment) ||
        typeof attachment.suggestedHumanReadableName !== "string" ||
        typeof attachment.exportedFileName !== "string"
      ) {
        throw new Error("Unknown xcresult attachment entry");
      }
      const filename = curatedUIAttachment(attachment.suggestedHumanReadableName);
      if (!filename) {
        continue;
      }
      if (basename(attachment.exportedFileName) !== attachment.exportedFileName) {
        throw new Error("xcresult attachment path escapes its export directory");
      }
      const destination = resolve(run, "evidence", directory);
      mkdirSync(destination, { recursive: true });
      const source = resolve(attachments, attachment.exportedFileName);
      if (index.some((entry) => entry.file === `${directory}/${filename}`)) {
        throw new Error("Native UI evidence names collide; no attachment may overwrite another");
      }
      const bytes = readFileSync(source);
      copyFileSync(source, resolve(destination, filename));
      index.push({
        test: test.testIdentifier,
        file: `${directory}/${filename}`,
        sha256: createHash("sha256").update(bytes).digest("hex"),
        byteLength: bytes.byteLength,
      });
    }
  }
  mkdirSync(resolve(run, "evidence"), { recursive: true });
  writeFileSync(resolve(run, "evidence", "index.json"), `${JSON.stringify(index, null, 2)}\n`);
  return { summary, attachments: index };
}
