import { expect, it } from "@effect/vitest";
import { env } from "cloudflare:workers";
import { Effect, Schema } from "effect";
import { beforeEach, vi } from "vitest";

import { storedByteHash, validateDocument } from "@trigo/contracts";

import ownerMigration from "../migrations/0001_owner_identity.sql?raw";
import { asrReadRangeBytes, makeAsrMasterHeader } from "../src/asr-master.ts";
import cloudWorker, { type CloudEnvironmentProbe } from "../src/cloud-worker.ts";
import { HostedMasterFixture, fixtureTemplateByteLength } from "../src/hosted-master-fixture.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";

const token = OwnerToken.make(`trigo_v1_${"cd".repeat(32)}`);
const fixture = "master-control-en";
const root = `acceptance/issue-13/hosted-masters/${fixture}`;
const url = `https://trigo.invalid/__trigo/hosted-master-probe/${fixture}`;

function template() {
  const bytes = new Uint8Array(fixtureTemplateByteLength);
  bytes.set(makeAsrMasterHeader());
  bytes.fill(10, 68, 68 + 1_280_000);
  bytes.fill(20, 68 + 1_280_000, 68 + 2_560_000);
  bytes.fill(30, 68 + 2_560_000);
  return bytes;
}

function request(method: string, query = "", body?: Uint8Array) {
  return new Request(url + query, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "audio/x-caf" },
    ...(body === undefined ? {} : { body: new Blob([new Uint8Array(body)]) }),
  });
}

function bindings(
  run = vi.fn().mockRejectedValue(new Error("No provider acknowledgement")),
): CloudEnvironmentProbe {
  return {
    ARCHIVE: env.LOCAL_ARCHIVE,
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: { create: vi.fn(), get: vi.fn() },
    AI: { run },
    DEPLOYMENT_STAGE: "dev",
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };
}

const fetch = (environment: CloudEnvironmentProbe, method: string, query = "", body?: Uint8Array) =>
  Effect.promise(() =>
    Promise.resolve(cloudWorker.fetch(request(method, query, body), environment)),
  );

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
    ...["fixture", "ready", "normalized", "provenance", "normalization"].map(
      (name) => `${root}/${name}.json`,
    ),
    `${root}/master.caf`,
    ...[0, 1].flatMap((index) =>
      ["extraction", "admission", "raw", "failure"].map(
        (name) => `${root}/submissions/${index}/${name}.json`,
      ),
    ),
  ]);
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000001311"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000001312"),
      verifierSha256: await Effect.runPromise(hashOwnerToken(token)),
      now: "2026-09-08T00:00:00.000Z",
    }),
  );
});

it.effect(
  "streams a controlled CAF master, retains exact submission provenance and recovers a stable normalized revision",
  () =>
    Effect.gen(function* () {
      const inputs: Uint8Array[] = [];
      const run = vi.fn(async (_model: string, input: Record<string, unknown>) => {
        const audio = input.audio;
        if (
          typeof audio !== "object" ||
          audio === null ||
          !("body" in audio) ||
          !(audio.body instanceof ReadableStream)
        ) {
          throw new Error("Expected streamed audio");
        }
        inputs.push(new Uint8Array(await new Response(audio.body).arrayBuffer()));
        const word = (text: string, start: number, speaker: number) => ({
          word: text,
          punctuated_word: text,
          start,
          end: start + 0.3,
          speaker,
          confidence: 0.99,
        });
        return Response.json(
          {
            results: {
              channels: [
                { alternatives: [{ words: [word("local", 1, 0)] }] },
                { alternatives: [{ words: [word("alpha", 5, 0), word("beta", 12, 1)] }] },
              ],
            },
            usage: { neurons: 472.73 },
          },
          { headers: { "cf-ai-req-id": `request-${inputs.length}` } },
        );
      });
      const environment = bindings(run);
      expect(
        (yield* fetch(
          environment,
          "PUT",
          "?language=en&durationMs=120000&intervalMs=60000",
          template(),
        )).status,
      ).toBe(201);
      const masterObject = yield* Effect.promise(() => env.LOCAL_ARCHIVE.get(`${root}/master.caf`));
      expect(masterObject?.size).toBe(7_680_068);
      if (masterObject === null) {
        throw new Error("The generated master must be retained");
      }
      const master = yield* Effect.promise(
        async () => new Uint8Array(await masterObject.arrayBuffer()),
      );
      expect(master[68]).toBe(10);
      expect(master[68 + 60_000 * 64]).toBe(20);
      expect(master[68 + 100_000 * 64]).toBe(30);
      const planResponse = yield* fetch(environment, "GET", "?artifact=plan");
      const plan = yield* Schema.decodeUnknownEffect(HostedMasterFixture)(
        yield* Effect.promise(() => planResponse.json()),
      );
      expect(plan.master.sha256).toBe(yield* Effect.promise(() => storedByteHash(master)));
      expect(
        (yield* fetch(
          environment,
          "PUT",
          "?language=en&durationMs=120000&intervalMs=60000",
          template(),
        )).status,
      ).toBe(409);
      for (const index of [0, 1]) {
        const result = yield* fetch(environment, "POST", `?index=${index}`);
        expect(result.status).toBe(200);
        expect(yield* Effect.promise(() => result.json())).toMatchObject({
          fullyConsumed: "true",
          httpStatus: "200",
        });
        expect((yield* fetch(environment, "POST", `?index=${index}`)).status).toBe(200);
      }
      expect(run).toHaveBeenCalledTimes(2);
      expect(inputs.map((input) => input.byteLength)).toEqual([3_840_044, 3_840_044]);
      for (const [index, input] of inputs.entries()) {
        const expected = master.slice(68 + index * 3_840_000, 68 + (index + 1) * 3_840_000);
        expect(yield* Effect.promise(() => storedByteHash(input.slice(44)))).toBe(
          yield* Effect.promise(() => storedByteHash(expected)),
        );
      }
      const normalized = yield* fetch(environment, "POST", "?action=normalize");
      expect(normalized.status).toBe(200);
      const text = yield* Effect.promise(() => normalized.text());
      const revision = validateDocument(
        "TranscriptRevision",
        yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(text),
      );
      expect(new Set(revision.speakers.map((speaker) => speaker.diarizationScopeId)).size).toBe(4);
      expect(revision.speakers).toHaveLength(6);
      expect(revision.turns.map((turn) => turn.startMs)).toEqual([
        1000, 5000, 12000, 61000, 65000, 72000,
      ]);
      const recovered = yield* fetch(environment, "POST", "?action=normalize");
      expect(yield* Effect.promise(() => recovered.text())).toBe(text);
      expect(run).toHaveBeenCalledTimes(2);
    }),
);

it.effect(
  "never repeats an uncertain admission and refuses normalization when the provider stops consuming input",
  () =>
    Effect.gen(function* () {
      const run = vi.fn().mockRejectedValue(new Error("Lost response"));
      const environment = bindings(run);
      expect(
        (yield* fetch(
          environment,
          "PUT",
          "?language=en&durationMs=120000&intervalMs=60000",
          template(),
        )).status,
      ).toBe(201);
      expect((yield* fetch(environment, "POST", "?index=0")).status).toBe(202);
      expect((yield* fetch(environment, "POST", "?index=0")).status).toBe(202);
      expect(run).toHaveBeenCalledOnce();
      run.mockResolvedValue(Response.json({ results: { channels: [] } }));
      const incomplete = yield* fetch(environment, "POST", "?index=1");
      expect(incomplete.status).toBe(200);
      expect(yield* Effect.promise(() => incomplete.json())).toMatchObject({
        fullyConsumed: "false",
      });
      expect((yield* fetch(environment, "POST", "?action=normalize")).status).toBe(409);
      expect(run).toHaveBeenCalledTimes(2);
    }),
);

it.effect("keeps master fixture mutation dev-only and owner-authenticated", () =>
  Effect.gen(function* () {
    const environment = bindings();
    const anonymous = new Request(url + "?language=en&durationMs=60000&intervalMs=60000", {
      method: "PUT",
    });
    expect(
      (yield* Effect.promise(() => Promise.resolve(cloudWorker.fetch(anonymous, environment))))
        .status,
    ).toBe(401);
    expect(
      (yield* fetch(
        { ...environment, DEPLOYMENT_STAGE: "personal" },
        "PUT",
        "?language=en&durationMs=60000&intervalMs=60000",
        template(),
      )).status,
    ).toBe(404);
    expect(yield* Effect.promise(() => env.LOCAL_ARCHIVE.get(`${root}/fixture.json`))).toBeNull();
  }),
);

it.effect("rejects a prefetched final audio block as delivery evidence", () =>
  Effect.gen(function* () {
    const run = vi.fn(async (_model: string, input: Record<string, unknown>) => {
      const audio = input.audio;
      if (
        typeof audio !== "object" ||
        audio === null ||
        !("body" in audio) ||
        !(audio.body instanceof ReadableStream)
      ) {
        throw new Error("Expected streamed input");
      }
      const reader = audio.body.getReader();
      let delivered = 0;
      while (delivered < 44 + asrReadRangeBytes) {
        const next = await reader.read();
        if (next.done) {
          break;
        }
        delivered += next.value.byteLength;
      }
      expect(delivered).toBe(44 + asrReadRangeBytes);
      expect(delivered).toBeLessThan(3_840_044);
      reader.releaseLock();
      return Response.json({
        results: {
          channels: [
            { alternatives: [{ transcript: "", words: [] }] },
            { alternatives: [{ transcript: "", words: [] }] },
          ],
        },
      });
    });
    const environment = bindings(run);
    expect(
      (yield* fetch(
        environment,
        "PUT",
        "?language=en&durationMs=60000&intervalMs=60000",
        template(),
      )).status,
    ).toBe(201);
    const result = yield* fetch(environment, "POST", "?index=0");
    expect(yield* Effect.promise(() => result.json())).toMatchObject({ fullyConsumed: "false" });
    expect((yield* fetch(environment, "POST", "?action=normalize")).status).toBe(409);
  }),
);
