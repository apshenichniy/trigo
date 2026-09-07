import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { lockPaths } from "./locks.ts";
import { requireNativeTools, toolOutput } from "./toolchain.ts";

type NativeCacheInputs = {
  platform: string;
  architecture: string;
  toolchain: string[];
  root?: string;
};

export function nativeDependencyCacheIdentity(inputs: NativeCacheInputs): string {
  return identity(inputs, [
    ...lockPaths.filter((path) => path.endsWith("Package.resolved")),
    "packages/contracts/Package.swift",
    "apps/macos/Package.swift",
  ]);
}

export function nativeCacheIdentity(inputs: NativeCacheInputs): string {
  const files = [
    ...lockPaths,
    "mise.toml",
    "packages/contracts/Package.swift",
    "apps/macos/Package.swift",
    "apps/macos/project.yml",
    "scripts/toolchain.ts",
    "scripts/commands.ts",
    "scripts/arguments.ts",
    "scripts/macos.ts",
    "scripts/native-check.ts",
    "scripts/native-suites.ts",
    "scripts/check-inputs.ts",
    "scripts/build-reuse.ts",
    "scripts/native-cache.ts",
    "scripts/offline.sb",
  ];
  return identity(inputs, files);
}

function identity(inputs: NativeCacheInputs, paths: string[]): string {
  const files = paths.map((path) => [
    path,
    readFileSync(resolve(inputs.root ?? ".", path), "utf8"),
  ]);
  return createHash("sha256")
    .update(
      JSON.stringify({
        platform: inputs.platform,
        architecture: inputs.architecture,
        toolchain: inputs.toolchain,
        files,
      }),
    )
    .digest("hex");
}

export function nativeToolchain(): string[] {
  requireNativeTools();
  return [
    toolOutput(["xcodebuild", "-version"]),
    toolOutput(["swift", "--version"]),
    toolOutput(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
    toolOutput(["xcodegen", "--version"]),
  ];
}

if (import.meta.main) {
  const inputs = {
    platform: process.platform,
    architecture: process.arch,
    toolchain: nativeToolchain(),
  };
  console.log(`dependencies=${nativeDependencyCacheIdentity(inputs)}`);
  console.log(`build=${nativeCacheIdentity(inputs)}`);
}
