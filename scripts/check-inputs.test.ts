import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { inputFingerprint } from "./check-inputs.ts";

it("identifies dirty native inputs, additions, deletions and permissions while ignoring unrelated documentation", () => {
  const root = mkdtempSync(join(tmpdir(), "trigo-inputs-"));
  try {
    execFileSync("git", ["init", "-q"], { cwd: root });
    mkdirSync(join(root, "native"));
    const source = join(root, "native/source.swift");
    writeFileSync(source, "original");
    writeFileSync(join(root, "README.md"), "original");
    execFileSync("git", ["add", "."], { cwd: root });
    const original = inputFingerprint(["native"], root);
    writeFileSync(join(root, "README.md"), "documentation changed");
    expect(inputFingerprint(["native"], root)).toBe(original);
    writeFileSync(source, "changed");
    expect(inputFingerprint(["native"], root)).not.toBe(original);
    writeFileSync(source, "original");
    writeFileSync(join(root, "native/new.swift"), "untracked");
    expect(inputFingerprint(["native"], root)).not.toBe(original);
    rmSync(join(root, "native/new.swift"));
    expect(inputFingerprint(["native"], root)).toBe(original);
    chmodSync(source, 0o755);
    expect(inputFingerprint(["native"], root)).not.toBe(original);
    rmSync(source);
    expect(inputFingerprint(["native"], root)).not.toBe(original);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
