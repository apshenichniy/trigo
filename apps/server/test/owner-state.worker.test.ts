import { expect, it } from "@effect/vitest";
import { env } from "cloudflare:workers";
import { Effect, Result } from "effect";
import { beforeEach, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import ownerIdentityMigration from "../migrations/0001_owner_identity.sql?raw";
import cloudWorker, { type CloudEnvironmentProbe } from "../src/cloud-worker.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  authenticateOwner,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
  type OwnerToken as OwnerTokenType,
} from "../src/owner-state.ts";

function token(): OwnerTokenType {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return OwnerToken.make(
    `trigo_v1_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`,
  );
}

function cloudBindings(): CloudEnvironmentProbe {
  return {
    ARCHIVE: { get: vi.fn(), put: vi.fn(), head: vi.fn(), delete: vi.fn() },
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: { create: vi.fn() },
    AI: { run: vi.fn() },
    DEPLOYMENT_STAGE: "dev",
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };
}

const fetchWorker = Effect.fn("OwnerStateTest.fetchWorker")(function* (
  request: Request,
  bindings: CloudEnvironmentProbe,
) {
  return yield* Effect.promise(() => Promise.resolve(cloudWorker.fetch(request, bindings)));
});

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

it.effect("initializes one archive identity and safely replays the same operation", () =>
  Effect.gen(function* () {
    const ownerToken = token();
    const input = {
      kind: "initialize" as const,
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(ownerToken),
      now: "2026-09-05T21:30:00.000Z",
    };

    const first = yield* applyOwnerOperation(env.CATALOG, input);
    const replay = yield* applyOwnerOperation(env.CATALOG, input);

    expect(first).toEqual({
      archiveId: input.archiveId,
      generation: 1,
      operationId: input.operationId,
      state: "active",
    });
    expect(replay).toEqual(first);
    const identity = yield* Effect.promise(() =>
      env.CATALOG.prepare("SELECT archive_id FROM trigo_archive_identity").all(),
    );
    expect(identity).toMatchObject({ results: [{ archive_id: input.archiveId }] });
  }),
);

it.effect("rejects an operation ID replayed with different initialization content", () =>
  Effect.gen(function* () {
    const ownerToken = token();
    const input = {
      kind: "initialize" as const,
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(ownerToken),
      now: "2026-09-05T21:30:00.000Z",
    };
    yield* applyOwnerOperation(env.CATALOG, input);

    const failure = yield* applyOwnerOperation(env.CATALOG, {
      ...input,
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000031"),
    }).pipe(Effect.flip);
    expect(failure).toMatchObject({ _tag: "OwnerState.OwnerOperationConflict" });
  }),
);

it.effect("commits exactly one concurrent owner-token replacement", () =>
  Effect.gen(function* () {
    const initialToken = token();
    yield* applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(initialToken),
      now: "2026-09-05T21:30:00.000Z",
    });

    const candidates = [
      {
        operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000302"),
        token: token(),
      },
      {
        operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000303"),
        token: token(),
      },
    ];
    const replacements = yield* Effect.forEach(
      candidates,
      (candidate) =>
        Effect.gen(function* () {
          const verifierSha256 = yield* hashOwnerToken(candidate.token);
          return yield* applyOwnerOperation(env.CATALOG, {
            kind: "rotate",
            operationId: candidate.operationId,
            expectedGeneration: 1,
            verifierSha256,
            now: "2026-09-05T21:31:00.000Z",
          });
        }).pipe(Effect.result),
      { concurrency: "unbounded" },
    );

    const succeeded = replacements.filter(Result.isSuccess);
    const failed = replacements.filter(Result.isFailure);
    expect(succeeded).toHaveLength(1);
    expect(succeeded[0]?.success).toMatchObject({ generation: 2, state: "active" });
    expect(failed).toHaveLength(1);
    expect(failed[0]?.failure).toMatchObject({ _tag: "OwnerState.OwnerOperationConflict" });

    const state = yield* Effect.promise(() =>
      env.CATALOG.prepare(
        "SELECT generation, current_operation_id FROM trigo_owner_credential_state",
      ).first(),
    );
    expect(state).toEqual({
      generation: 2,
      current_operation_id: succeeded[0]?.success.operationId,
    });
  }),
);

it.effect("revokes idempotently and permits an operator-authorized replacement", () =>
  Effect.gen(function* () {
    const initialToken = token();
    yield* applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(initialToken),
      now: "2026-09-05T21:30:00.000Z",
    });
    const revoke = {
      kind: "revoke" as const,
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000304"),
      expectedGeneration: 1,
      now: "2026-09-05T21:32:00.000Z",
    };

    const first = yield* applyOwnerOperation(env.CATALOG, revoke);
    const replay = yield* applyOwnerOperation(env.CATALOG, revoke);
    expect(first).toEqual({
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      generation: 2,
      operationId: revoke.operationId,
      state: "revoked",
    });
    expect(replay).toEqual(first);

    const replacementToken = token();
    const replacement = yield* applyOwnerOperation(env.CATALOG, {
      kind: "rotate",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000305"),
      expectedGeneration: 2,
      verifierSha256: yield* hashOwnerToken(replacementToken),
      now: "2026-09-05T21:33:00.000Z",
    });
    expect(replacement).toMatchObject({ generation: 3, state: "active" });
  }),
);

it.effect("authenticates status with the current owner token and returns the shared contract", () =>
  Effect.gen(function* () {
    const ownerToken = token();
    const wrongToken = token();
    yield* applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(ownerToken),
      now: "2026-09-05T21:30:00.000Z",
    });
    const bindings = cloudBindings();

    for (const authorization of [undefined, "Basic invalid", `Bearer ${wrongToken}`]) {
      const response = yield* fetchWorker(
        new Request(
          "https://trigo.invalid/v1/status",
          authorization === undefined ? {} : { headers: { authorization } },
        ),
        bindings,
      );
      expect(response.status).toBe(401);
      expect(
        validateDocument("ErrorEnvelope", yield* Effect.promise(() => response.json())),
      ).toMatchObject({
        schemaVersion: 1,
        error: {
          code: "owner_unauthorized",
          retry: "after_correction",
          message: "Provide the current Trigo owner token.",
        },
      });
    }

    const response = yield* fetchWorker(
      new Request("https://trigo.invalid/v1/status", {
        headers: { authorization: `Bearer ${ownerToken}` },
      }),
      bindings,
    );
    expect(response.status).toBe(200);
    expect(
      validateDocument("StatusResponse", yield* Effect.promise(() => response.json())),
    ).toEqual({
      schemaVersion: 1,
      apiVersion: 1,
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      stage: "dev",
      readiness: {
        archive: "ready",
        ownerAuthentication: "ready",
        transcription: "not_verified",
        callOperations: "ready",
      },
      errors: [
        {
          code: "asr_not_verified",
          retry: "after_correction",
          message:
            "Nova-3 readiness has not been verified; complete issue #13 before transcription.",
        },
      ],
    });
    expect(bindings.ARCHIVE.get).not.toHaveBeenCalled();
    expect(bindings.ARCHIVE_WORKFLOW.create).not.toHaveBeenCalled();
    expect(bindings.AI.run).not.toHaveBeenCalled();
  }),
);

it.effect("reports persistence failures as retryable infrastructure errors", () =>
  Effect.gen(function* () {
    const response = yield* fetchWorker(
      new Request("https://trigo.invalid/v1/status", {
        headers: { authorization: `Bearer ${token()}` },
      }),
      {
        ...cloudBindings(),
        CATALOG: {
          prepare: () => {
            throw new Error("D1 temporarily unavailable");
          },
        },
      },
    );

    expect(response.status).toBe(503);
    expect(
      validateDocument("ErrorEnvelope", yield* Effect.promise(() => response.json())),
    ).toMatchObject({
      error: {
        code: "owner_persistence_unavailable",
        retry: "retryable",
        message: "Owner authentication storage is temporarily unavailable; retry the request.",
      },
    });
  }),
);

it.effect("rejects malformed persisted owner rows with a typed persistence error", () =>
  Effect.gen(function* () {
    const ownerToken = token();
    yield* applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(ownerToken),
      now: "2026-09-05T21:30:00.000Z",
    });
    yield* Effect.promise(() =>
      env.CATALOG.prepare(
        "UPDATE trigo_archive_identity SET archive_id = 'zzzzzzzz-zzzz-4zzz-8zzz-zzzzzzzzzzzz'",
      ).run(),
    );

    const failure = yield* authenticateOwner(
      env.CATALOG,
      new Request("https://trigo.invalid/v1/status", {
        headers: { authorization: `Bearer ${ownerToken}` },
      }),
    ).pipe(Effect.flip);
    expect(failure).toMatchObject({
      _tag: "OwnerState.OwnerPersistenceError",
      operation: "OwnerState.authenticateOwner.decode",
    });
  }),
);

it.effect("rejects rotated and revoked tokens without caching authorization results", () =>
  Effect.gen(function* () {
    const initialToken = token();
    const replacementToken = token();
    yield* applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000000030"),
      verifierSha256: yield* hashOwnerToken(initialToken),
      now: "2026-09-05T21:30:00.000Z",
    });
    const bindings = cloudBindings();
    const status = Effect.fn("OwnerStateTest.status")(function* (ownerToken: OwnerTokenType) {
      return yield* fetchWorker(
        new Request("https://trigo.invalid/v1/status", {
          headers: { authorization: `Bearer ${ownerToken}` },
        }),
        bindings,
      );
    });

    expect((yield* status(initialToken)).status).toBe(200);
    const rotation = {
      kind: "rotate" as const,
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000302"),
      expectedGeneration: 1,
      verifierSha256: yield* hashOwnerToken(replacementToken),
      now: "2026-09-05T21:31:00.000Z",
    };
    yield* applyOwnerOperation(env.CATALOG, rotation);
    expect(yield* applyOwnerOperation(env.CATALOG, rotation)).toMatchObject({
      generation: 2,
      state: "active",
    });
    expect((yield* status(initialToken)).status).toBe(401);
    expect((yield* status(replacementToken)).status).toBe(200);

    const unauthenticatedOperation = yield* fetchWorker(
      new Request(
        "https://trigo.invalid/v1/calls/00000000-0000-4000-8000-000000000017/transcriptions",
        { method: "POST" },
      ),
      bindings,
    );
    expect(unauthenticatedOperation.status).toBe(401);
    const unavailableOperation = yield* fetchWorker(
      new Request(
        "https://trigo.invalid/v1/calls/00000000-0000-4000-8000-000000000017/transcriptions",
        {
          method: "POST",
          headers: { authorization: `Bearer ${replacementToken}` },
        },
      ),
      bindings,
    );
    expect(unavailableOperation.status).toBe(501);
    expect(
      validateDocument("ErrorEnvelope", yield* Effect.promise(() => unavailableOperation.json())),
    ).toMatchObject({ error: { code: "operation_unavailable" } });

    yield* applyOwnerOperation(env.CATALOG, {
      kind: "revoke",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000000304"),
      expectedGeneration: 2,
      now: "2026-09-05T21:32:00.000Z",
    });
    expect((yield* status(replacementToken)).status).toBe(401);

    const stored = yield* Effect.promise(() =>
      env.CATALOG.prepare(
        `SELECT verifier_sha256 FROM trigo_owner_credential_operations
         WHERE verifier_sha256 IS NOT NULL`,
      ).all(),
    );
    for (const row of stored.results) {
      const verifier = Reflect.get(row, "verifier_sha256");
      expect(verifier).not.toBe(initialToken);
      expect(verifier).not.toBe(replacementToken);
      expect(verifier).toMatch(/^[0-9a-f]{64}$/);
    }
  }),
);
