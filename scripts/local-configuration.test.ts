import { mkdtempSync, chmodSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import structuralCorpus from "../packages/contracts/fixtures/structure-cases.json";
import {
  localConfiguration,
  localWorkerEnvironment,
  readLocalConfiguration,
} from "./local-configuration.ts";

const worktree = "012345abcdef";
const origin = "http://127.0.0.1:19371";
function fixture(use: (path: string) => void) {
  const root = mkdtempSync(join(tmpdir(), "trigo-local-configuration-"));
  try {
    use(join(root, "connection.json"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe("private offline bridge", () => {
  for (const item of structuralCorpus.filter((item) => item.kind === "LocalDevelopmentBridge")) {
    it(`enforces the shared bridge corpus at the file boundary: ${item.name}`, () =>
      fixture((path) => {
        writeFileSync(path, item.json, { mode: 0o600 });
        const read = () => readLocalConfiguration(path, worktree);
        if (item.valid) {
          expect(read()).toEqual(JSON.parse(item.json));
        } else {
          expect(read).toThrow();
        }
      }));
  }
  it("reuses the local archive/token on restart and isolates independent worktrees", () =>
    fixture((path) => {
      const first = localConfiguration(path, worktree, origin);
      expect(localConfiguration(path, worktree, origin)).toEqual(first);
      expect(() => localConfiguration(path, "abcdef012345", origin)).toThrow("worktree");
      expect(() => localConfiguration(path, worktree, "http://127.0.0.1:19372")).toThrow(
        "endpoint changed",
      );
      expect(localConfiguration(`${path}.other`, "abcdef012345", origin).namespaceId).not.toBe(
        first.namespaceId,
      );
    }));
  it("rejects symlinks, permissive credentials, unknown fields and noncanonical origins", () =>
    fixture((path) => {
      localConfiguration(path, worktree, origin);
      const valid = JSON.parse(readFileSync(path, "utf8"));
      symlinkSync(path, `${path}.link`);
      expect(() => readLocalConfiguration(`${path}.link`, worktree)).toThrow();
      chmodSync(path, 0o644);
      expect(() => readLocalConfiguration(path, worktree)).toThrow("0600");
      chmodSync(path, 0o600);
      for (const serverURL of [
        "http://localhost:19371",
        "http://127.0.0.1:80",
        "http://[::1]:19371",
        "http://192.168.0.1:19371",
        "https://cloud.example",
        "http://127.0.0.1:19371/",
        "http://127.0.0.1:019371",
        "http://user@127.0.0.1:19371",
      ]) {
        writeFileSync(path, JSON.stringify({ ...valid, serverURL }));
        expect(() => readLocalConfiguration(path, worktree)).toThrow();
      }
      writeFileSync(path, JSON.stringify({ ...valid, cloudToken: "not-allowed" }));
      expect(() => readLocalConfiguration(path, worktree)).toThrow();
    }));
  it("passes no cloud credentials, local owner token or proxy configuration to Alchemy", () =>
    fixture((path) => {
      vi.stubEnv("CLOUDFLARE_API_TOKEN", "secret-cloud-token");
      vi.stubEnv("HTTPS_PROXY", "https://proxy.example");
      vi.stubEnv("TRIGO_LIVE_HANDOFF_PATH", "/personal/credential");
      try {
        const config = localConfiguration(path, worktree, origin);
        const env = localWorkerEnvironment(config, "run-id", 19371);
        expect(env.CLOUDFLARE_API_TOKEN).toBe("trigo-local-invalid-token");
        expect(env.TRIGO_LOCAL_OWNER_VERIFIER).toMatch(/^[0-9a-f]{64}$/);
        expect(env.TRIGO_LOCAL_ARCHIVE_ID).toBe(config.namespaceId);
        expect(JSON.stringify(env)).not.toContain(config.ownerToken);
        expect(env.HTTPS_PROXY).toBeUndefined();
        expect(env.TRIGO_LIVE_HANDOFF_PATH).toBeUndefined();
      } finally {
        vi.unstubAllEnvs();
      }
    }));
});
