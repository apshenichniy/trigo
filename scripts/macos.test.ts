import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { restoreLock } from "./macos-lock.ts";
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
