import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export function installHooks(root = process.cwd()): string {
  const git = (args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
  const configured = spawnSync("git", ["config", "--get", "core.hooksPath"], {
    cwd: root,
    encoding: "utf8",
  });
  if (configured.status !== 0 && configured.status !== 1) {
    throw new Error("Cannot read the repository hook configuration");
  }
  if (configured.status === 0) {
    throw new Error(
      "Existing core.hooksPath is preserved; integrate .githooks/pre-push into that hook setup",
    );
  }
  const path = git(["rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-push"]);
  const source = readFileSync(resolve(root, ".githooks/pre-push"), "utf8");
  const existing = lstatSync(path, { throwIfNoEntry: false });
  if (existing) {
    if (
      !existing.isFile() ||
      !readFileSync(path, "utf8").startsWith("#!/bin/sh\n# Trigo managed pre-push hook v1\n")
    ) {
      throw new Error(
        `Existing hook is preserved: ${path}. Integrate .githooks/pre-push explicitly`,
      );
    }
  }
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, source, { mode: 0o755 });
  chmodSync(path, 0o755);
  return path;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args.length === 1 && args[0] !== "--if-repository")) {
    throw new Error("Usage: bun run hooks:install");
  }
  const optional = args[0] === "--if-repository";
  const repository = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
  if (optional && (process.env.CI === "true" || repository.status !== 0)) {
    console.log("Local hook installation skipped outside a development checkout.");
  } else {
    console.log(`Installed local verification hook: ${installHooks()}`);
  }
}
