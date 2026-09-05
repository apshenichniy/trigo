import { spawnSync } from "node:child_process";
export function toolOutput(command: string[]): string {
  const result = spawnSync(command[0]!, command.slice(1), { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`Missing prerequisite: ${command[0]}`);
  return result.stdout.trim();
}
export function requireNativeTools(): void {
  if (process.platform !== "darwin") throw new Error("macOS and Xcode 26.6 (17F113) are required");
  for (const [command, expected] of [
    [["xcodebuild", "-version"], "Xcode 26.6\nBuild version 17F113"],
    [["xcodegen", "--version"], "Version: 2.46.0"],
    [["swift", "format", "--version"], "6.3.0"],
  ] as const) {
    if (toolOutput([...command]) !== expected)
      throw new Error(`Toolchain mismatch: ${command.join(" ")} must report ${expected}`);
  }
  if (!toolOutput(["swift", "--version"]).includes("Apple Swift version 6.3.3 "))
    throw new Error("Expected Xcode-provided Swift 6.3.3");
}
