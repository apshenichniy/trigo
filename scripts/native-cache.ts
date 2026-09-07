import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { lockPaths } from "./locks.ts";
import { requireNativeTools, toolOutput } from "./toolchain.ts";

export function nativeCacheIdentity(inputs: {
  platform: string;
  architecture: string;
  toolchain: string[];
  root?: string;
}): string {
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
    "scripts/native-cache.ts",
    "scripts/offline.sb",
  ].map((path) => [path, readFileSync(resolve(inputs.root ?? ".", path), "utf8")]);
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

if (import.meta.main) {
  requireNativeTools();
  console.log(
    nativeCacheIdentity({
      platform: process.platform,
      architecture: process.arch,
      toolchain: [
        toolOutput(["xcodebuild", "-version"]),
        toolOutput(["swift", "--version"]),
        toolOutput(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
        toolOutput(["xcodegen", "--version"]),
      ],
    }),
  );
}
