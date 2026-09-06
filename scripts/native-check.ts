import { resolve } from "node:path";
import { timedRun } from "./timing.ts";

export const swiftPackages = [
  { path: "packages/contracts", configuration: "debug" },
  { path: "apps/macos", configuration: "release" },
] as const;

export function lockedSwiftArguments(path: string): string[] {
  return [
    "--package-path",
    path,
    "--cache-path",
    resolve(".local/SwiftPMCache"),
    "--force-resolved-versions",
    "--skip-update",
  ];
}

export function swiftTests(execute = timedRun): void {
  for (const { path, configuration } of swiftPackages) {
    const args = [...lockedSwiftArguments(path), "--configuration", configuration];
    // Always check current sources before executing tests, including exact cache hits.
    // Match swift test's testable imports in Release as well as Debug.
    execute(`${path} ${configuration} build tests`, [
      "swift",
      "build",
      ...args,
      "--build-tests",
      "-Xswiftc",
      "-enable-testing",
    ]);
    execute(`${path} ${configuration} test`, ["swift", "test", ...args, "--skip-build"]);
  }
}
