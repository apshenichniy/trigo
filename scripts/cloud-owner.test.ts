import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { expect, it } from "@effect/vitest";
import { DateTime, Effect, Redacted, Schema } from "effect";

import { ownerOperationQueries } from "../apps/server/src/owner-state.ts";
import {
  applyRemoteOwnerOperation,
  assertOwnerMutationAllowed,
  type CloudflareOwnerTransport,
  ownerHandoffFromUnknown,
  ownerOperationFromHandoff,
  ownerHandoffTarget,
  parseOwnerCommand,
  prepareOwnerHandoff,
} from "./cloud-owner.ts";
import { cloudTargetFor } from "./cloud.ts";

const unknownFromJsonString = Schema.fromJsonString(Schema.Unknown);
const encodeUnknownJson = Schema.encodeSync(unknownFromJsonString);
const decodeUnknownJson = Schema.decodeUnknownSync(unknownFromJsonString);
const devTarget = ownerHandoffTarget(cloudTargetFor("dev"), "11111111111111111111111111111111");

it.effect("reuses a private initialization handoff after a lost acknowledgement", () =>
  Effect.gen(function* () {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-owner-handoff-"));
    const handoffPath = resolve(directory, "owner.json");
    try {
      const command = parseOwnerCommand("initialize", ["--stage", "dev", "--handoff", handoffPath]);
      const first = yield* prepareOwnerHandoff(command, devTarget);
      const replay = yield* prepareOwnerHandoff(command, devTarget);

      expect(replay).toEqual(first);
      expect(first).toMatchObject({
        schemaVersion: 1,
        action: "initialize",
        stage: "dev",
        target: devTarget,
      });
      if (first.action !== "initialize") {
        throw new Error("Expected initialization handoff");
      }
      expect(first.operationId).toMatch(/^[0-9a-f-]{36}$/);
      expect(first.archiveId).toMatch(/^[0-9a-f-]{36}$/);
      expect(first.token).toMatch(/^trigo_v1_[0-9a-f]{64}$/);
      expect(statSync(handoffPath).mode & 0o777).toBe(0o600);

      const operation = yield* ownerOperationFromHandoff(first);
      if (operation.kind !== "initialize") {
        throw new Error("Expected initialization operation");
      }
      const requestBody = encodeUnknownJson({ batch: ownerOperationQueries(operation) });
      expect(requestBody).not.toContain(first.token);
      expect(requestBody).toContain(operation.verifierSha256);
      expect(decodeUnknownJson(readFileSync(handoffPath, "utf8"))).toMatchObject({
        schemaVersion: 1,
        action: first.action,
        stage: first.stage,
        target: devTarget,
        operationId: first.operationId,
        archiveId: first.archiveId,
        token: first.token,
        createdAt: DateTime.formatIso(first.createdAt),
      });
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }),
);

it.effect(
  "prepares distinct rotate and revoke operations without persisting plaintext in SQL",
  () =>
    Effect.gen(function* () {
      const directory = mkdtempSync(resolve(tmpdir(), "trigo-owner-handoff-"));
      try {
        const rotate = yield* prepareOwnerHandoff(
          parseOwnerCommand("rotate", [
            "--stage",
            "dev",
            "--handoff",
            resolve(directory, "rotate.json"),
            "--expected-generation",
            "7",
          ]),
          devTarget,
        );
        const revoke = yield* prepareOwnerHandoff(
          parseOwnerCommand("revoke", [
            "--stage",
            "dev",
            "--handoff",
            resolve(directory, "revoke.json"),
            "--expected-generation",
            "8",
          ]),
          devTarget,
        );
        if (rotate.action !== "rotate" || revoke.action !== "revoke") {
          throw new Error("Expected rotate and revoke handoffs");
        }

        expect(rotate.expectedGeneration).toBe(7);
        expect(rotate.token).toMatch(/^trigo_v1_[0-9a-f]{64}$/);
        expect(revoke.expectedGeneration).toBe(8);
        expect(Reflect.has(revoke, "token")).toBe(false);

        const rotateOperation = yield* ownerOperationFromHandoff(rotate);
        const revokeOperation = yield* ownerOperationFromHandoff(revoke);
        const rotateBody = encodeUnknownJson({ batch: ownerOperationQueries(rotateOperation) });
        expect(rotateBody).not.toContain(rotate.token);
        expect(revokeOperation).not.toHaveProperty("verifierSha256");
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    }),
);

it.effect("rejects unsafe or mismatched handoff replay", () =>
  Effect.gen(function* () {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-owner-handoff-"));
    const handoffPath = resolve(directory, "owner.json");
    try {
      const initial = parseOwnerCommand("initialize", ["--stage", "dev", "--handoff", handoffPath]);
      yield* prepareOwnerHandoff(initial, devTarget);

      const wrongStage = parseOwnerCommand("initialize", [
        "--stage",
        "personal",
        "--handoff",
        handoffPath,
      ]);
      const mismatch = yield* Effect.flip(
        prepareOwnerHandoff(
          wrongStage,
          ownerHandoffTarget(cloudTargetFor("personal"), "22222222222222222222222222222222"),
        ),
      );
      expect(mismatch.message).toContain("Cannot prepare owner handoff");

      const wrongAccount = yield* Effect.flip(
        prepareOwnerHandoff(
          initial,
          ownerHandoffTarget(cloudTargetFor("dev"), "33333333333333333333333333333333"),
        ),
      );
      expect(wrongAccount.message).toContain("does not match the requested Cloudflare target");

      chmodSync(handoffPath, 0o644);
      const unsafe = yield* Effect.flip(prepareOwnerHandoff(initial, devTarget));
      expect(unsafe.message).toContain("Cannot prepare owner handoff");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }),
);

it("validates operation-specific arguments before creating a handoff", () => {
  expect(() => parseOwnerCommand("rotate", ["--stage", "dev"])).toThrow(
    "Pass an absolute path after --handoff",
  );
  expect(() =>
    parseOwnerCommand("revoke", [
      "--stage",
      "dev",
      "--handoff",
      "/tmp/owner.json",
      "--expected-generation",
      "0",
    ]),
  ).toThrow("Pass a positive integer after --expected-generation");
  expect(() =>
    parseOwnerCommand("initialize", [
      "--stage",
      "dev",
      "--handoff",
      "/tmp/owner.json",
      "--expected-generation",
      "1",
    ]),
  ).toThrow("Unexpected owner argument");
});

it("rejects an incomplete executable command before any Cloudflare request", () => {
  const result = spawnSync("bun", ["scripts/cloud-owner.ts", "initialize", "--stage", "dev"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });

  expect(result.status).toBe(1);
  expect(result.stderr).toContain("Pass an absolute path after --handoff");
});

it("requires the operator credential before creating a handoff", () => {
  const directory = mkdtempSync(resolve(tmpdir(), "trigo-owner-command-"));
  const handoffPath = resolve(directory, "owner.json");
  const environment = { ...process.env };
  delete environment.CLOUDFLARE_API_TOKEN;
  try {
    const result = spawnSync(
      "bun",
      ["scripts/cloud-owner.ts", "initialize", "--stage", "dev", "--handoff", handoffPath],
      {
        cwd: new URL("..", import.meta.url),
        encoding: "utf8",
        env: environment,
      },
    );

    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Missing CLOUDFLARE_API_TOKEN for owner operation");
    expect(existsSync(handoffPath)).toBe(false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

it("keeps personal owner mutations behind the #32 deployment gate", () => {
  expect(() =>
    assertOwnerMutationAllowed({
      stage: "personal",
      accountId: "11111111111111111111111111111111",
      profile: "trigo-cloud-personal",
      personalDeploymentGate: "blocked-by-32",
    }),
  ).toThrow("Personal owner operations are blocked until #32 is accepted");
  expect(() =>
    assertOwnerMutationAllowed({
      stage: "personal",
      accountId: "11111111111111111111111111111111",
      profile: "trigo-cloud-personal",
      personalDeploymentGate: "approved-after-32",
    }),
  ).not.toThrow();
});

it("exposes explicit initialization, rotation, and revocation commands", () => {
  const manifest = decodeUnknownJson(
    readFileSync(new URL("../package.json", import.meta.url), "utf8"),
  );
  const scripts =
    typeof manifest === "object" && manifest !== null
      ? Reflect.get(manifest, "scripts")
      : undefined;

  expect(scripts).toMatchObject({
    "cloud:owner:init": "bun scripts/cloud-owner.ts initialize",
    "cloud:owner:rotate": "bun scripts/cloud-owner.ts rotate",
    "cloud:owner:revoke": "bun scripts/cloud-owner.ts revoke",
  });
});

it("documents the private handoff, replay, and authenticated status procedure", () => {
  const runbook = readFileSync(new URL("../docs/development/cloud.md", import.meta.url), "utf8");
  const setup = readFileSync(new URL("../docs/development/setup.md", import.meta.url), "utf8");

  expect(runbook).toContain("bun run cloud:owner:init --stage dev --handoff");
  expect(runbook).toContain("bun run cloud:owner:rotate --stage dev --handoff");
  expect(runbook).toContain("bun run cloud:owner:revoke --stage dev --handoff");
  expect(runbook).toMatch(/rerun the exact command with\s+the same handoff path/);
  expect(runbook).toContain("test:cloud --stage dev --owner-handoff");
  expect(setup).toContain("`cloud:owner:init --stage dev --handoff <absolute-path>`");
});

it.effect("applies only verifier material through the authenticated Cloudflare D1 boundary", () =>
  Effect.gen(function* () {
    const ownerToken = "trigo_v1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const verifierSha256 = yield* ownerOperationFromHandoff(
      ownerHandoffFromUnknown({
        schemaVersion: 1,
        action: "initialize",
        stage: "dev",
        target: devTarget,
        operationId: "00000000-0000-4000-8000-000000000301",
        archiveId: "00000000-0000-4000-8000-000000000030",
        token: ownerToken,
        createdAt: "2026-09-05T22:00:00.000Z",
      }),
    );
    if (verifierSha256.kind !== "initialize") {
      throw new Error("Expected initialization operation");
    }
    const requests: Array<Request> = [];
    const responses: Array<{ readonly status: number; readonly body: unknown }> = [
      {
        status: 200,
        body: {
          success: true,
          errors: [],
          result: [{ name: "trigo-dev-catalog", uuid: "00000000-0000-4000-8000-000000000099" }],
        },
      },
      {
        status: 200,
        body: {
          success: true,
          errors: [],
          result: [
            { success: true, results: [] },
            { success: true, results: [] },
            { success: true, results: [] },
            {
              success: true,
              results: [
                {
                  archive_id: "00000000-0000-4000-8000-000000000030",
                  generation: 1,
                  operation_id: "00000000-0000-4000-8000-000000000301",
                  revoked: 0,
                },
              ],
            },
          ],
        },
      },
    ];
    const transport: CloudflareOwnerTransport = {
      request: (request) =>
        Effect.sync(() => {
          requests.push(request);
          const response = responses[requests.length - 1];
          if (response === undefined) {
            throw new Error("Unexpected Cloudflare request");
          }
          return response;
        }),
    };

    const result = yield* applyRemoteOwnerOperation(
      "11111111111111111111111111111111",
      "trigo-dev-catalog",
      Redacted.make("operator-secret"),
      verifierSha256,
      transport,
    );

    expect(result).toEqual({
      archiveId: "00000000-0000-4000-8000-000000000030",
      generation: 1,
      operationId: "00000000-0000-4000-8000-000000000301",
      state: "active",
    });
    expect(requests).toHaveLength(2);
    expect(requests[0]?.url).toBe(
      "https://api.cloudflare.com/client/v4/accounts/11111111111111111111111111111111/d1/database?name=trigo-dev-catalog&per_page=10",
    );
    expect(requests[1]?.url).toBe(
      "https://api.cloudflare.com/client/v4/accounts/11111111111111111111111111111111/d1/database/00000000-0000-4000-8000-000000000099/query",
    );
    expect(
      requests.every(
        (request) => request.headers.get("authorization") === "Bearer operator-secret",
      ),
    ).toBe(true);
    const queryRequest = requests[1];
    if (queryRequest === undefined) {
      throw new Error("Expected D1 query request");
    }
    const body = encodeUnknownJson(yield* Effect.promise(() => queryRequest.json()));
    expect(body).not.toContain(ownerToken);
    expect(body).toContain(verifierSha256.verifierSha256);
  }),
);
