import { expect, it } from "@effect/vitest";
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, vi } from "vitest";

import { makeWaveHeader, selectedMediaProfile } from "@trigo/contracts";

import ownerMigration from "../migrations/0001_owner_identity.sql?raw";
import cloudWorker, { type CloudEnvironmentProbe } from "../src/cloud-worker.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";

const token = OwnerToken.make(`trigo_v1_${"ac".repeat(32)}`);
const fixture = "stream-control-en";
const root = `acceptance/issue-13/hosted-v2/${fixture}`;
const url = `https://trigo.invalid/__trigo/hosted-asr-probe/${fixture}?language=en`;

function wave() {
  const bytes = new Uint8Array(64_044);
  bytes.set(makeWaveHeader(16_000));
  bytes[48] = 47;
  return bytes;
}

function request(method: string, body?: Uint8Array) {
  return new Request(url, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": selectedMediaProfile.contentType },
    ...(body === undefined ? {} : { body: new Blob([new Uint8Array(body)]) }),
  });
}

function bindings(
  run = vi.fn().mockResolvedValue(Response.json({ results: { channels: [] } })),
): CloudEnvironmentProbe {
  return {
    ARCHIVE: env.LOCAL_ARCHIVE,
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: { create: vi.fn() },
    AI: { run },
    DEPLOYMENT_STAGE: "dev",
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };
}

beforeEach(async () => {
  const sql = `DROP TABLE IF EXISTS trigo_owner_credential_operations;
    DROP TABLE IF EXISTS trigo_owner_credential_state;
    DROP TABLE IF EXISTS trigo_archive_identity; ${ownerMigration}`;
  await env.CATALOG.batch(
    sql
      .split(";")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => env.CATALOG.prepare(s)),
  );
  await env.LOCAL_ARCHIVE.delete([
    `${root}/input.wav`,
    `${root}/admission.json`,
    `${root}/raw.json`,
    `${root}/failure.json`,
  ]);
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000001301"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000001302"),
      verifierSha256: await Effect.runPromise(hashOwnerToken(token)),
      now: "2026-09-08T00:00:00.000Z",
    }),
  );
});

it.effect(
  "submits private R2 bytes through the binary stream binding and recovers a retained response",
  () =>
    Effect.gen(function* () {
      const input = wave();
      let submitted: Uint8Array | undefined;
      const run = vi.fn(async (_model: string, value: Record<string, unknown>) => {
        const audio = value.audio;
        expect(audio).toHaveProperty("body");
        if (
          typeof audio !== "object" ||
          audio === null ||
          !("body" in audio) ||
          !(audio.body instanceof ReadableStream)
        ) {
          throw new Error("A real stream is required; base64 JSON takes the broken provider path");
        }
        submitted = new Uint8Array(await new Response(audio.body).arrayBuffer());
        return Response.json(
          { results: { channels: [] } },
          { headers: { "cf-ai-req-id": "stream-request-1" } },
        );
      });
      const environment = bindings(run);
      expect(
        (yield* Effect.promise(() =>
          Promise.resolve(cloudWorker.fetch(request("PUT", input), environment)),
        )).status,
      ).toBe(201);
      expect(
        (yield* Effect.promise(() =>
          Promise.resolve(cloudWorker.fetch(request("POST"), environment)),
        )).status,
      ).toBe(200);
      expect(submitted).toEqual(input);
      expect(
        (yield* Effect.promise(() =>
          Promise.resolve(cloudWorker.fetch(request("GET"), environment)),
        )).status,
      ).toBe(200);
      expect(
        (yield* Effect.promise(() =>
          Promise.resolve(cloudWorker.fetch(request("POST"), environment)),
        )).status,
      ).toBe(200);
      expect(run).toHaveBeenCalledOnce();
      const raw = yield* Effect.promise(() => env.LOCAL_ARCHIVE.get(`${root}/raw.json`));
      expect(raw?.customMetadata?.providerRequestId).toBe("stream-request-1");
    }),
);

it.effect(
  "admits one paid side effect across racing requests and retains uncertainty before provider acknowledgement",
  () =>
    Effect.gen(function* () {
      const run = vi.fn().mockRejectedValue(new Error("Provider response lost"));
      const environment = bindings(run);
      expect(
        (yield* Effect.promise(() =>
          Promise.resolve(cloudWorker.fetch(request("PUT", wave()), environment)),
        )).status,
      ).toBe(201);
      yield* Effect.promise(() =>
        Promise.all([
          cloudWorker.fetch(request("POST"), environment),
          cloudWorker.fetch(request("POST"), environment),
        ]),
      );
      expect(run).toHaveBeenCalledOnce();
      expect(
        yield* Effect.promise(() => env.LOCAL_ARCHIVE.get(`${root}/admission.json`)),
      ).not.toBeNull();
      const replay = yield* Effect.promise(() =>
        Promise.resolve(cloudWorker.fetch(request("POST"), environment)),
      );
      expect(replay.status).toBe(202);
      expect(run).toHaveBeenCalledOnce();
    }),
);
