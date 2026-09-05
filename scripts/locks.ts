import { readFileSync } from "node:fs";
export const lockPaths = [
  "bun.lock",
  "packages/contracts/Package.resolved",
  "apps/macos/Package.resolved",
  "apps/macos/Locks/Package.resolved",
];
export function snapshotLocks(): ReadonlyMap<string, string> {
  return new Map(lockPaths.map((path) => [path, readFileSync(path, "utf8")]));
}
export function assertLocksUnchanged(before: ReadonlyMap<string, string>): void {
  for (const [path, content] of before)
    if (readFileSync(path, "utf8") !== content)
      throw new Error(`Operation changed tracked lock: ${path}`);
}
