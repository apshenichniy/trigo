import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { expect, it } from "vitest";

import { nativeCacheIdentity } from "./native-cache.ts";

it("invalidates restored native products on any lock, toolchain, or build configuration change", () => {
  const root = mkdtempSync(join(tmpdir(), "trigo-native-cache-"));
  const paths = [
    "bun.lock",
    "mise.toml",
    "packages/contracts/Package.resolved",
    "apps/macos/Package.resolved",
    "apps/macos/Locks/Package.resolved",
    "packages/contracts/Package.swift",
    "apps/macos/Package.swift",
    "apps/macos/project.yml",
    "scripts/toolchain.ts",
    "scripts/commands.ts",
    "scripts/arguments.ts",
    "scripts/macos.ts",
    "scripts/native-check.ts",
    "scripts/native-cache.ts",
    "scripts/offline.sb",
  ];
  try {
    for (const path of paths) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      copyFileSync(path, join(root, path));
    }
    const inputs = {
      root,
      platform: "darwin",
      architecture: "arm64",
      toolchain: ["Xcode 26.6", "SDK 17F113"],
    };
    const original = nativeCacheIdentity(inputs);
    expect(nativeCacheIdentity(inputs)).toBe(original);
    for (const path of paths) {
      const full = join(root, path);
      const before = readFileSync(full, "utf8");
      writeFileSync(full, `${before}\nchanged input\n`);
      expect(nativeCacheIdentity(inputs), path).not.toBe(original);
      writeFileSync(full, before);
    }
    for (const changed of [
      { platform: "linux" },
      { architecture: "x64" },
      { toolchain: ["Xcode 26.6", "different SDK"] },
    ]) {
      expect(nativeCacheIdentity({ ...inputs, ...changed })).not.toBe(original);
    }
    rmSync(join(root, "apps/macos/Locks/Package.resolved"));
    expect(() => nativeCacheIdentity(inputs)).toThrow();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
