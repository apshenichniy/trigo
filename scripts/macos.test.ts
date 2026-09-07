import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { restoreLock } from "./macos-lock.ts";
import {
  assertSupportedReplacement,
  installationDestination,
  nativeSigning,
} from "./macos-install.ts";

it("requires an explicit installed signing mode while keeping CI credential-free", () => {
  expect(nativeSigning("build", undefined, false)).toEqual(["CODE_SIGNING_ALLOWED=NO"]);
  expect(() => nativeSigning("run", undefined, false)).toThrow("TRIGO_SIGNING_TEAM");
  expect(() => nativeSigning("install", undefined, false)).toThrow("TRIGO_SIGNING_TEAM");
  expect(nativeSigning("run", undefined, true)).toContain("CODE_SIGN_IDENTITY=-");
  expect(nativeSigning("install", "ABCDEFGHIJ", false)).toContain("DEVELOPMENT_TEAM=ABCDEFGHIJ");
  expect(() => nativeSigning("run", "ABCDEFGHIJ", true)).toThrow("Unset");
});

it("keeps local installations away from ordinary Dev and personal and requires explicit worktree replacement", () => {
  const local = installationDestination("/Applications", "dev", "0123456789ab", true);
  const dev = installationDestination("/Applications", "dev", "0123456789ab", false);
  const personal = installationDestination("/Applications", "personal", "0123456789ab", false);
  expect(new Set([local, dev, personal]).size).toBe(3);
  expect(local).not.toBe(installationDestination("/Applications", "dev", "abcdef012345", true));
  const previous = { bundleId: "dev", worktree: "one", requirement: "stable" };
  expect(() => assertSupportedReplacement(previous, previous, false, false)).not.toThrow();
  expect(() =>
    assertSupportedReplacement(previous, { ...previous, worktree: "two" }, false, false),
  ).toThrow("worktree");
  expect(() =>
    assertSupportedReplacement(previous, { ...previous, worktree: "two" }, true, false),
  ).not.toThrow();
  expect(() =>
    assertSupportedReplacement(previous, { ...previous, requirement: "changed" }, true, false),
  ).toThrow("signing");
  expect(() =>
    assertSupportedReplacement(previous, { ...previous, bundleId: "personal" }, true, true),
  ).toThrow("bundle");
});
it("restores the canonical lock even when a cached generated project lost its nested lock", () => {
  const dir = mkdtempSync(join(tmpdir(), "trigo-lock-"));
  try {
    const canonical = join(dir, "Package.resolved"),
      nested = join(
        dir,
        "Trigo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
      );
    mkdirSync(join(dir, "Trigo.xcodeproj"));
    writeFileSync(canonical, '{"version":3,"pins":[{"identity":"schema"}]}');
    restoreLock(canonical, nested);
    expect(readFileSync(nested, "utf8")).toBe(readFileSync(canonical, "utf8"));
    rmSync(nested);
    restoreLock(canonical, nested);
    expect(readFileSync(nested, "utf8")).toBe(readFileSync(canonical, "utf8"));
    rmSync(canonical);
    expect(() => restoreLock(canonical, nested)).toThrow("Canonical SwiftPM lock missing");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
