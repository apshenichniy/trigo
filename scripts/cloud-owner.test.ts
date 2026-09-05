import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { expect, it } from "@effect/vitest";
import { Effect, Redacted } from "effect";
import { ownerOperationQueries } from "../apps/server/src/owner-state.ts";
import {
  applyRemoteOwnerOperation,
  assertOwnerMutationAllowed,
  type CloudflareOwnerTransport,
  ownerOperationFromHandoff,
  parseOwnerCommand,
  prepareOwnerHandoff,
} from "./cloud-owner.ts";

it.effect("reuses a private initialization handoff after a lost acknowledgement", () =>
  Effect.gen(function* () {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-owner-handoff-"));
    const handoffPath = resolve(directory, "owner.json");
    try {
      const command = parseOwnerCommand("initialize", ["--stage", "dev", "--handoff", handoffPath]);
      const first = yield* prepareOwnerHandoff(command);
      const replay = yield* prepareOwnerHandoff(command);

      expect(replay).toEqual(first);
      expect(first).toMatchObject({
        schemaVersion: 1,
        action: "initialize",
        stage: "dev",
      });
      if (first.action !== "initialize") throw new Error("Expected initialization handoff");
      expect(first.operationId).toMatch(/^[0-9a-f-]{36}$/);
      expect(first.archiveId).toMatch(/^[0-9a-f-]{36}$/);
      expect(first.token).toMatch(/^trigo_v1_[0-9a-f]{64}$/);
      expect(statSync(handoffPath).mode & 0o777).toBe(0o600);

      const operation = yield* ownerOperationFromHandoff(first);
      if (operation.kind !== "initialize") throw new Error("Expected initialization operation");
      const requestBody = JSON.stringify({ batch: ownerOperationQueries(operation) });
      expect(requestBody).not.toContain(first.token);
      expect(requestBody).toContain(operation.verifierSha256);
      expect(JSON.parse(readFileSync(handoffPath, "utf8"))).toEqual(first);
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
        );
        if (rotate.action !== "rotate" || revoke.action !== "revoke")
          throw new Error("Expected rotate and revoke handoffs");

        expect(rotate.expectedGeneration).toBe(7);
        expect(rotate.token).toMatch(/^trigo_v1_[0-9a-f]{64}$/);
        expect(revoke.expectedGeneration).toBe(8);
        expect(Reflect.has(revoke, "token")).toBe(false);

        const rotateOperation = yield* ownerOperationFromHandoff(rotate);
        const revokeOperation = yield* ownerOperationFromHandoff(revoke);
        const rotateBody = JSON.stringify({ batch: ownerOperationQueries(rotateOperation) });
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
      yield* prepareOwnerHandoff(initial);

      const wrongStage = parseOwnerCommand("initialize", [
        "--stage",
        "personal",
        "--handoff",
        handoffPath,
      ]);
      const mismatch = yield* Effect.flip(prepareOwnerHandoff(wrongStage));
      expect(mismatch.message).toContain("Cannot prepare owner handoff");

      chmodSync(handoffPath, 0o644);
      const unsafe = yield* Effect.flip(prepareOwnerHandoff(initial));
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
  const manifest: unknown = JSON.parse(
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

it.effect("applies only verifier material through the authenticated Cloudflare D1 boundary", () =>
  Effect.gen(function* () {
    const ownerToken = "trigo_v1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const verifierSha256 = yield* ownerOperationFromHandoff({
      schemaVersion: 1,
      action: "initialize",
      stage: "dev",
      operationId: "00000000-0000-4000-8000-000000000301",
      archiveId: "00000000-0000-4000-8000-000000000030",
      token: ownerToken,
      createdAt: "2026-09-05T22:00:00.000Z",
    });
    if (verifierSha256.kind !== "initialize") throw new Error("Expected initialization operation");
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
          if (response === undefined) throw new Error("Unexpected Cloudflare request");
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
    if (queryRequest === undefined) throw new Error("Expected D1 query request");
    const body = JSON.stringify(yield* Effect.promise(() => queryRequest.json()));
    expect(body).not.toContain(ownerToken);
    expect(body).toContain(verifierSha256.verifierSha256);
  }),
);
