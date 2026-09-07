import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readlinkSync } from "node:fs";
import { resolve } from "node:path";

function git(root: string, args: string[]): Buffer {
  return execFileSync("git", args, { cwd: root, maxBuffer: 64 * 1024 * 1024 });
}

/** Hash current files, including unstaged edits, additions, deletions and executable bits. */
export function inputFingerprint(paths: readonly string[], root = process.cwd()): string {
  const files = new Set(
    git(root, ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", ...paths])
      .toString()
      .split("\0")
      .filter(Boolean),
  );
  const hash = createHash("sha256");
  for (const path of [...files].sort()) {
    const full = resolve(root, path);
    hash.update(`${path}\0`);
    // A tracked deletion remains an input until its directory's next fingerprint.
    if (!existsSync(full)) {
      hash.update("missing\0");
      continue;
    }
    const stat = lstatSync(full);
    hash.update(`${stat.mode}\0`);
    hash.update(stat.isSymbolicLink() ? readlinkSync(full) : readFileSync(full));
    hash.update("\0");
  }
  return hash.digest("hex");
}

export function sourceState(root = process.cwd()) {
  const revision = git(root, ["rev-parse", "HEAD"]).toString().trim();
  const status = git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  const hash = createHash("sha256")
    .update(revision)
    .update(git(root, ["diff", "--binary", "HEAD", "--"]))
    .update(status);
  if (status.length) {
    const untracked = git(root, ["ls-files", "-z", "--others", "--exclude-standard"])
      .toString()
      .split("\0")
      .filter(Boolean);
    if (untracked.length) hash.update(inputFingerprint(untracked, root));
  }
  return { revision, fingerprint: hash.digest("hex"), dirty: status.length > 0 };
}
