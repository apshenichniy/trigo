import { validateDocument } from "@trigo/contracts";
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";
import cloudWorker from "../src/cloud-worker.ts";
import { applyOwnerOperation, hashOwnerToken } from "../src/owner-state.ts";
import ownerIdentityMigration from "../migrations/0001_owner_identity.sql?raw";

function token(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `trigo_v1_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

beforeEach(async () => {
  const setup = `
    DROP TABLE IF EXISTS trigo_owner_credential_operations;
    DROP TABLE IF EXISTS trigo_owner_credential_state;
    DROP TABLE IF EXISTS trigo_archive_identity;
    ${ownerIdentityMigration}
  `;
  await env.CATALOG.batch(
    setup
      .split(";")
      .map((statement) => statement.trim())
      .filter((statement) => statement !== "")
      .map((statement) => env.CATALOG.prepare(statement)),
  );
});

it("initializes one archive identity and safely replays the same operation", async () => {
  const ownerToken = token();
  const input = {
    kind: "initialize" as const,
    operationId: "00000000-0000-4000-8000-000000000301",
    archiveId: "00000000-0000-4000-8000-000000000030",
    verifierSha256: await Effect.runPromise(hashOwnerToken(ownerToken)),
    now: "2026-09-05T21:30:00.000Z",
  };

  const first = await Effect.runPromise(applyOwnerOperation(env.CATALOG, input));
  const replay = await Effect.runPromise(applyOwnerOperation(env.CATALOG, input));

  expect(first).toEqual({
    archiveId: input.archiveId,
    generation: 1,
    operationId: input.operationId,
    state: "active",
  });
  expect(replay).toEqual(first);
  expect(
    await env.CATALOG.prepare("SELECT archive_id FROM trigo_archive_identity").all(),
  ).toMatchObject({ results: [{ archive_id: input.archiveId }] });
});

it("rejects an operation ID replayed with different initialization content", async () => {
  const ownerToken = token();
  const input = {
    kind: "initialize" as const,
    operationId: "00000000-0000-4000-8000-000000000301",
    archiveId: "00000000-0000-4000-8000-000000000030",
    verifierSha256: await Effect.runPromise(hashOwnerToken(ownerToken)),
    now: "2026-09-05T21:30:00.000Z",
  };
  await Effect.runPromise(applyOwnerOperation(env.CATALOG, input));

  await expect(
    Effect.runPromise(
      applyOwnerOperation(env.CATALOG, {
        ...input,
        archiveId: "00000000-0000-4000-8000-000000000031",
      }),
    ),
  ).rejects.toMatchObject({ _tag: "OwnerState.OwnerOperationConflict" });
});

it("commits exactly one concurrent owner-token replacement", async () => {
  const initialToken = token();
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: "00000000-0000-4000-8000-000000000301",
      archiveId: "00000000-0000-4000-8000-000000000030",
      verifierSha256: await Effect.runPromise(hashOwnerToken(initialToken)),
      now: "2026-09-05T21:30:00.000Z",
    }),
  );

  const candidates = [
    { operationId: "00000000-0000-4000-8000-000000000302", token: token() },
    { operationId: "00000000-0000-4000-8000-000000000303", token: token() },
  ];
  const replacements = await Promise.allSettled(
    candidates.map(async (candidate) =>
      Effect.runPromise(
        applyOwnerOperation(env.CATALOG, {
          kind: "rotate",
          operationId: candidate.operationId,
          expectedGeneration: 1,
          verifierSha256: await Effect.runPromise(hashOwnerToken(candidate.token)),
          now: "2026-09-05T21:31:00.000Z",
        }),
      ),
    ),
  );

  const fulfilled = replacements.filter((result) => result.status === "fulfilled");
  const rejected = replacements.filter((result) => result.status === "rejected");
  expect(fulfilled).toHaveLength(1);
  expect(fulfilled[0]?.value).toMatchObject({ generation: 2, state: "active" });
  expect(rejected).toHaveLength(1);
  expect(rejected[0]?.reason).toMatchObject({
    _tag: "OwnerState.OwnerOperationConflict",
  });

  const state = await env.CATALOG.prepare(
    "SELECT generation, current_operation_id FROM trigo_owner_credential_state",
  ).first();
  expect(state).toEqual({
    generation: 2,
    current_operation_id: fulfilled[0]?.value.operationId,
  });
});

it("revokes idempotently and permits an operator-authorized replacement", async () => {
  const initialToken = token();
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: "00000000-0000-4000-8000-000000000301",
      archiveId: "00000000-0000-4000-8000-000000000030",
      verifierSha256: await Effect.runPromise(hashOwnerToken(initialToken)),
      now: "2026-09-05T21:30:00.000Z",
    }),
  );
  const revoke = {
    kind: "revoke" as const,
    operationId: "00000000-0000-4000-8000-000000000304",
    expectedGeneration: 1,
    now: "2026-09-05T21:32:00.000Z",
  };

  const first = await Effect.runPromise(applyOwnerOperation(env.CATALOG, revoke));
  const replay = await Effect.runPromise(applyOwnerOperation(env.CATALOG, revoke));
  expect(first).toEqual({
    archiveId: "00000000-0000-4000-8000-000000000030",
    generation: 2,
    operationId: revoke.operationId,
    state: "revoked",
  });
  expect(replay).toEqual(first);

  const replacementToken = token();
  await expect(
    Effect.runPromise(
      applyOwnerOperation(env.CATALOG, {
        kind: "rotate",
        operationId: "00000000-0000-4000-8000-000000000305",
        expectedGeneration: 2,
        verifierSha256: await Effect.runPromise(hashOwnerToken(replacementToken)),
        now: "2026-09-05T21:33:00.000Z",
      }),
    ),
  ).resolves.toMatchObject({ generation: 3, state: "active" });
});

it("authenticates status with the current owner token and returns the shared contract", async () => {
  const ownerToken = token();
  const wrongToken = token();
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: "00000000-0000-4000-8000-000000000301",
      archiveId: "00000000-0000-4000-8000-000000000030",
      verifierSha256: await Effect.runPromise(hashOwnerToken(ownerToken)),
      now: "2026-09-05T21:30:00.000Z",
    }),
  );
  const bindings = {
    ARCHIVE: { get: vi.fn() },
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: { create: vi.fn() },
    AI: { run: vi.fn() },
    DEPLOYMENT_STAGE: "dev" as const,
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };

  for (const authorization of [undefined, "Basic invalid", `Bearer ${wrongToken}`]) {
    const response = await cloudWorker.fetch(
      new Request(
        "https://trigo.invalid/v1/status",
        authorization === undefined ? {} : { headers: { authorization } },
      ),
      bindings,
    );
    expect(response.status).toBe(401);
    expect(validateDocument("ErrorEnvelope", await response.json())).toMatchObject({
      schemaVersion: 1,
      error: {
        code: "owner_unauthorized",
        retry: "after_correction",
        message: "Provide the current Trigo owner token.",
      },
    });
  }

  const response = await cloudWorker.fetch(
    new Request("https://trigo.invalid/v1/status", {
      headers: { authorization: `Bearer ${ownerToken}` },
    }),
    bindings,
  );
  expect(response.status).toBe(200);
  expect(validateDocument("StatusResponse", await response.json())).toEqual({
    schemaVersion: 1,
    apiVersion: 1,
    archiveId: "00000000-0000-4000-8000-000000000030",
    stage: "dev",
    readiness: {
      archive: "ready",
      ownerAuthentication: "ready",
      transcription: "not_verified",
      callOperations: "unavailable",
    },
    errors: [
      {
        code: "asr_not_verified",
        retry: "after_correction",
        message: "Nova-3 readiness has not been verified; complete issue #13 before transcription.",
      },
      {
        code: "call_operations_unavailable",
        retry: "after_correction",
        message: "Call operations are unavailable until issue #17.",
      },
    ],
  });
  expect(bindings.ARCHIVE.get).not.toHaveBeenCalled();
  expect(bindings.ARCHIVE_WORKFLOW.create).not.toHaveBeenCalled();
  expect(bindings.AI.run).not.toHaveBeenCalled();
});

it("rejects rotated and revoked tokens without caching authorization results", async () => {
  const initialToken = token();
  const replacementToken = token();
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: "00000000-0000-4000-8000-000000000301",
      archiveId: "00000000-0000-4000-8000-000000000030",
      verifierSha256: await Effect.runPromise(hashOwnerToken(initialToken)),
      now: "2026-09-05T21:30:00.000Z",
    }),
  );
  const bindings = {
    ARCHIVE: { get: vi.fn() },
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: { create: vi.fn() },
    AI: { run: vi.fn() },
    DEPLOYMENT_STAGE: "dev" as const,
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };
  const status = (ownerToken: string) =>
    cloudWorker.fetch(
      new Request("https://trigo.invalid/v1/status", {
        headers: { authorization: `Bearer ${ownerToken}` },
      }),
      bindings,
    );

  expect((await status(initialToken)).status).toBe(200);
  const rotation = {
    kind: "rotate" as const,
    operationId: "00000000-0000-4000-8000-000000000302",
    expectedGeneration: 1,
    verifierSha256: await Effect.runPromise(hashOwnerToken(replacementToken)),
    now: "2026-09-05T21:31:00.000Z",
  };
  await Effect.runPromise(applyOwnerOperation(env.CATALOG, rotation));
  expect(await Effect.runPromise(applyOwnerOperation(env.CATALOG, rotation))).toMatchObject({
    generation: 2,
    state: "active",
  });
  expect((await status(initialToken)).status).toBe(401);
  expect((await status(replacementToken)).status).toBe(200);

  const unauthenticatedOperation = await cloudWorker.fetch(
    new Request("https://trigo.invalid/v1/calls", { method: "POST" }),
    bindings,
  );
  expect(unauthenticatedOperation.status).toBe(401);
  const unavailableOperation = await cloudWorker.fetch(
    new Request("https://trigo.invalid/v1/calls", {
      method: "POST",
      headers: { authorization: `Bearer ${replacementToken}` },
    }),
    bindings,
  );
  expect(unavailableOperation.status).toBe(501);
  expect(validateDocument("ErrorEnvelope", await unavailableOperation.json())).toMatchObject({
    error: { code: "operation_unavailable" },
  });

  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "revoke",
      operationId: "00000000-0000-4000-8000-000000000304",
      expectedGeneration: 2,
      now: "2026-09-05T21:32:00.000Z",
    }),
  );
  expect((await status(replacementToken)).status).toBe(401);

  const stored = await env.CATALOG.prepare(
    `SELECT verifier_sha256 FROM trigo_owner_credential_operations
     WHERE verifier_sha256 IS NOT NULL`,
  ).all();
  expect(JSON.stringify(stored)).not.toContain(initialToken);
  expect(JSON.stringify(stored)).not.toContain(replacementToken);
});
