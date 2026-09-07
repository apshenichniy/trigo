import { chmodSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effect, Exit, Redacted, Schema } from "effect";
import { expect, it } from "@effect/vitest";
import { readProbeCredential } from "./asr-credential.ts";
import { ownerHandoffTarget } from "./cloud-owner.ts";
import { cloudTargetFor, type CloudConfiguration } from "./cloud.ts";

const config: CloudConfiguration = {
  stage: "dev",
  accountId: "a".repeat(32),
  profile: "trigo-cloud-dev",
  apiUrl: "https://dev.example.test",
};
const token = `trigo_v1_${"0".repeat(64)}`;
const encodeJson = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));
const fixture = () => ({
  schemaVersion: 1,
  stage: "dev",
  action: "initialize",
  archiveId: "00000000-0000-4000-8000-000000000055",
  target: ownerHandoffTarget(cloudTargetFor("dev"), config.accountId),
  operationId: "00000000-0000-4000-8000-000000000056",
  createdAt: "2026-09-07T00:00:00Z",
  token,
});

it.effect("reads only the explicitly selected matching private dev handoff", () =>
  Effect.gen(function* () {
    const root = mkdtempSync(join(tmpdir(), "trigo-probe-credential-"));
    const path = join(root, "handoff.json");
    try {
      writeFileSync(path, encodeJson(fixture()), { mode: 0o600 });
      expect(Redacted.value(yield* readProbeCredential(path, config))).toBe(token);
      chmodSync(path, 0o644);
      expect(Exit.isFailure(yield* Effect.exit(readProbeCredential(path, config)))).toBe(true);
      chmodSync(path, 0o600);
      const link = join(root, "handoff-link.json");
      symlinkSync(path, link);
      expect(Exit.isFailure(yield* Effect.exit(readProbeCredential(link, config)))).toBe(true);
      writeFileSync(path, " ".repeat(65_537), { mode: 0o600 });
      expect(Exit.isFailure(yield* Effect.exit(readProbeCredential(path, config)))).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }),
);

it.effect.each(["personal", "target", "revoke", "malformed"])(
  "rejects %s handoffs without falling back to Keychain",
  (kind) =>
    Effect.gen(function* () {
      const root = mkdtempSync(join(tmpdir(), "trigo-probe-credential-"));
      const path = join(root, "handoff.json");
      const handoff = fixture();
      const altered =
        kind === "personal"
          ? { ...handoff, stage: "personal" }
          : kind === "target"
            ? { ...handoff, target: { ...handoff.target, databaseName: "another-dev-db" } }
            : kind === "revoke"
              ? { ...handoff, action: "revoke", expectedGeneration: 2 }
              : { ...handoff, token: "invalid" };
      try {
        writeFileSync(path, encodeJson(altered), { mode: 0o600 });
        expect(Exit.isFailure(yield* Effect.exit(readProbeCredential(path, config)))).toBe(true);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    }),
);
