import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
export function restoreLock(canonical: string, nested: string): void {
  if (!existsSync(canonical)) {
    throw new Error(
      `Canonical SwiftPM lock missing: ${canonical}. Run the explicit dependency update command.`,
    );
  }
  mkdirSync(dirname(nested), { recursive: true });
  copyFileSync(canonical, nested);
}
