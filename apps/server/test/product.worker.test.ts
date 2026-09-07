import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Effect } from "effect";
import { validateDocument } from "@trigo/contracts";
import migration from "../migrations/0001_owner_identity.sql?raw";
import localWorker from "../src/local-worker.ts";
import cloudWorker from "../src/cloud-worker.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";

const archiveId = ArchiveId.make("00000000-0000-4000-8000-000000000054");
const initialToken = OwnerToken.make(`trigo_v1_${"1".repeat(64)}`);
const nextToken = OwnerToken.make(`trigo_v1_${"2".repeat(64)}`);
const wrongToken = OwnerToken.make(`trigo_v1_${"3".repeat(64)}`);
const operationId = (n: number) =>
  OwnerOperationId.make(`00000000-0000-4000-8000-${String(n).padStart(12, "0")}`);
const now = "2026-09-07T00:00:00.000Z";

beforeEach(async () => {
  const sql = `DROP TABLE IF EXISTS trigo_owner_credential_operations; DROP TABLE IF EXISTS trigo_owner_credential_state; DROP TABLE IF EXISTS trigo_archive_identity; ${migration}`;
  await env.CATALOG.batch(
    sql
      .split(";")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => env.CATALOG.prepare(s)),
  );
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: operationId(1),
      archiveId,
      verifierSha256: await Effect.runPromise(hashOwnerToken(initialToken)),
      now,
    }),
  );
});

for (const composition of ["local", "cloud"] as const) {
  describe(`${composition} shared product contract`, () => {
    const cloud = {
      ARCHIVE: { get: vi.fn(), put: vi.fn(), delete: vi.fn() },
      CATALOG: env.CATALOG,
      ARCHIVE_WORKFLOW: { create: vi.fn() },
      AI: { run: vi.fn() },
      DEPLOYMENT_STAGE: "dev" as const,
      DEPLOYMENT_IDENTITY: "test-cloud-dev",
    };
    const request = (
      path = "/v1/status",
      authorization: string | undefined = `Bearer ${initialToken}`,
      method = "GET",
    ) => {
      const request = new Request(`http://localhost${path}`, {
        method,
        ...(authorization ? { headers: { authorization } } : {}),
      });
      return composition === "local"
        ? localWorker.fetch(request, env)
        : cloudWorker.fetch(request, cloud);
    };
    async function error(
      response: Response,
      status: number,
      code: string,
      retry = "after_correction",
    ) {
      expect(response.status).toBe(status);
      expect(response.headers.get("content-type")).toContain("application/json");
      const value = validateDocument("ErrorEnvelope", await response.json());
      expect(value).toMatchObject({ schemaVersion: 1, error: { code, retry } });
      expect(value.error.requestId).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
      return value.error.requestId;
    }
    it("serves the existing readiness contract without invoking storage processing or providers", async () => {
      const read = vi.spyOn(env.LOCAL_ARCHIVE, "get");
      const workflow = vi.spyOn(env.ARCHIVE_WORKFLOW, "create");
      try {
        const response = await request();
        expect(response.status).toBe(200);
        expect(validateDocument("StatusResponse", await response.json())).toMatchObject({
          schemaVersion: 1,
          apiVersion: 1,
          archiveId,
          stage: "dev",
          readiness: {
            archive: "ready",
            ownerAuthentication: "ready",
            transcription: "not_verified",
            callOperations: "unavailable",
          },
          errors: [
            { code: "asr_not_verified", retry: "after_correction" },
            { code: "call_operations_unavailable", retry: "after_correction" },
          ],
        });
        expect(read).not.toHaveBeenCalled();
        expect(workflow).not.toHaveBeenCalled();
        expect(cloud.ARCHIVE.get).not.toHaveBeenCalled();
        expect(cloud.ARCHIVE_WORKFLOW.create).not.toHaveBeenCalled();
        expect(cloud.AI.run).not.toHaveBeenCalled();
      } finally {
        read.mockRestore();
        workflow.mockRestore();
      }
    });
    it("preserves exact bearer grammar and gives each failed request a fresh identity", async () => {
      const ids = new Set<string>();
      for (const header of [
        "",
        "Basic invalid",
        `Bearer ${wrongToken}`,
        `bearer ${initialToken}`,
        `BEARER ${initialToken}`,
        `Bearer  ${initialToken}`,
        `Bearer\t${initialToken}`,
        `Bearer ${initialToken.toUpperCase()}`,
      ]) {
        ids.add(await error(await request("/v1/status", header), 401, "owner_unauthorized"));
      }
      expect(ids.size).toBe(8);
    });
    it("authenticates before disclosing unavailable operations including unknown methods", async () => {
      for (const [path, method] of [
        ["/v1/calls", "POST"],
        ["/v1/status", "POST"],
        ["/v1/unknown", "GET"],
        ["/v1/status", "OPTIONS"],
      ]) {
        await error(await request(path, "", method), 401, "owner_unauthorized");
        await error(
          await request(path, `Bearer ${initialToken}`, method),
          501,
          "operation_unavailable",
        );
      }
    });
    it("observes replacement and revocation immediately without caching a prior owner", async () => {
      expect((await request()).status).toBe(200);
      const rotate = {
        kind: "rotate" as const,
        operationId: operationId(2),
        expectedGeneration: 1,
        verifierSha256: await Effect.runPromise(hashOwnerToken(nextToken)),
        now,
      };
      await Effect.runPromise(applyOwnerOperation(env.CATALOG, rotate));
      await Effect.runPromise(applyOwnerOperation(env.CATALOG, rotate));
      await error(await request(), 401, "owner_unauthorized");
      expect((await request("/v1/status", `Bearer ${nextToken}`)).status).toBe(200);
      await Effect.runPromise(
        applyOwnerOperation(env.CATALOG, {
          kind: "revoke",
          operationId: operationId(3),
          expectedGeneration: 2,
          now,
        }),
      );
      await error(await request("/v1/status", `Bearer ${nextToken}`), 401, "owner_unauthorized");
    });
    it("maps malformed and unavailable real D1 state to a retryable envelope", async () => {
      await env.CATALOG.prepare(
        "UPDATE trigo_archive_identity SET archive_id = 'zzzzzzzz-zzzz-4zzz-8zzz-zzzzzzzzzzzz'",
      ).run();
      await error(await request(), 503, "owner_persistence_unavailable", "retryable");
      await env.CATALOG.prepare("DROP TABLE trigo_owner_credential_state").run();
      await error(await request(), 503, "owner_persistence_unavailable", "retryable");
    });
  });
}

it("keeps simultaneous local/dev/personal requests in their own composition context", async () => {
  const request = () =>
    new Request("http://localhost/v1/status", {
      headers: { authorization: `Bearer ${initialToken}` },
    });
  const cloud = {
    ARCHIVE: env.LOCAL_ARCHIVE,
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: env.ARCHIVE_WORKFLOW,
    AI: { run: vi.fn() },
    DEPLOYMENT_IDENTITY: "test",
  };
  const responses = await Promise.all([
    localWorker.fetch(request(), env),
    cloudWorker.fetch(request(), { ...cloud, DEPLOYMENT_STAGE: "personal" }),
    cloudWorker.fetch(request(), { ...cloud, DEPLOYMENT_STAGE: "dev" }),
  ]);
  expect(
    await Promise.all(
      responses.map(async (r) => validateDocument("StatusResponse", await r.json()).stage),
    ),
  ).toEqual(["dev", "personal", "dev"]);
});
