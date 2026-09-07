import { expect, it } from "@effect/vitest";
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, vi } from "vitest";

import {
  frameCountForDuration,
  makeWaveHeader,
  selectedMediaProfile,
  validateDocument,
  waveByteLength,
} from "@trigo/contracts";

import ownerIdentityMigration from "../migrations/0001_owner_identity.sql?raw";
import cloudWorker, { type CloudEnvironmentProbe } from "../src/cloud-worker.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";

const ownerToken = OwnerToken.make(`trigo_v1_${"ab".repeat(32)}`);

function fixtureBytes(): Uint8Array {
  const frameCount = frameCountForDuration(2_000);
  const bytes = new Uint8Array(waveByteLength(frameCount));
  bytes.set(makeWaveHeader(frameCount));
  return bytes;
}

function providerResponse() {
  return {
    results: {
      channels: [
        {
          alternatives: [
            {
              transcript: "Local marker.",
              words: [
                {
                  word: "Local",
                  punctuated_word: "Local",
                  start: 0.1,
                  end: 0.4,
                  confidence: 0.98,
                  speaker: 0,
                },
                {
                  word: "marker",
                  punctuated_word: "marker.",
                  start: 0.4,
                  end: 0.8,
                  confidence: 0.97,
                  speaker: 0,
                },
              ],
            },
          ],
        },
        {
          alternatives: [
            {
              transcript: "Remote one. Remote two.",
              words: [
                { word: "Remote", start: 0.2, end: 0.5, speaker: 0 },
                { word: "one", start: 0.5, end: 0.9, speaker: 0 },
                { word: "Remote", start: 1.1, end: 1.4, speaker: 1 },
                { word: "two", start: 1.4, end: 1.8, speaker: 1 },
              ],
            },
          ],
        },
      ],
    },
  };
}

function bindings(run = vi.fn().mockResolvedValue(providerResponse())): CloudEnvironmentProbe {
  return {
    ARCHIVE: env.LOCAL_ARCHIVE,
    CATALOG: env.CATALOG,
    ARCHIVE_WORKFLOW: { create: vi.fn() },
    AI: { run },
    DEPLOYMENT_STAGE: "dev",
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };
}

function request(method: "PUT" | "POST" | "DELETE", body?: Uint8Array): Request {
  const requestBody =
    body === undefined
      ? undefined
      : (() => {
          const buffer = new ArrayBuffer(body.byteLength);
          new Uint8Array(buffer).set(body);
          return buffer;
        })();
  return new Request("https://trigo.invalid/__trigo/asr-probe/two-source-en?language=en", {
    method,
    headers: {
      authorization: `Bearer ${ownerToken}`,
      ...(method === "PUT"
        ? {
            "content-type": selectedMediaProfile.contentType,
            "x-trigo-media-profile": selectedMediaProfile.id,
          }
        : {}),
    },
    ...(requestBody === undefined ? {} : { body: requestBody }),
  });
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
  await env.LOCAL_ARCHIVE.delete([
    "acceptance/issue-13/two-source-en/input.wav",
    "acceptance/issue-13/two-source-en/en/audio-manifest.json",
    "acceptance/issue-13/two-source-en/en/provider-result.json",
    "acceptance/issue-13/two-source-en/en/provider-error.json",
    "acceptance/issue-13/two-source-en/en/normalized-revision.json",
  ]);
  const verifierSha256 = await Effect.runPromise(hashOwnerToken(ownerToken));
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make("00000000-0000-4000-8000-000000001391"),
      archiveId: ArchiveId.make("00000000-0000-4000-8000-000000001392"),
      verifierSha256,
      now: "2026-09-06T00:00:00.000Z",
    }),
  );
});

it.effect("keeps the dev probe behind owner authentication", () =>
  Effect.gen(function* () {
    const response = yield* Effect.promise(() =>
      Promise.resolve(
        cloudWorker.fetch(
          new Request("https://trigo.invalid/__trigo/asr-probe/two-source-en?language=en", {
            method: "POST",
          }),
          bindings(),
        ),
      ),
    );

    expect(response.status).toBe(401);
  }),
);

it.effect("retains a private provider failure without retrying inference", () =>
  Effect.gen(function* () {
    const run = vi.fn().mockRejectedValue(new Error("6003: Invalid request input"));
    const probeBindings = bindings(run);
    const upload = yield* Effect.promise(() =>
      Promise.resolve(cloudWorker.fetch(request("PUT", fixtureBytes()), probeBindings)),
    );
    expect(upload.status).toBe(201);

    const inference = yield* Effect.promise(() =>
      Promise.resolve(cloudWorker.fetch(request("POST"), probeBindings)),
    );
    expect(inference.status).toBe(502);
    expect(run).toHaveBeenCalledOnce();
    const failure = yield* Effect.promise(() =>
      env.LOCAL_ARCHIVE.get("acceptance/issue-13/two-source-en/en/provider-error.json"),
    );
    expect(failure).not.toBeNull();
    if (failure === null) {
      throw new Error("Expected private provider failure evidence");
    }
    expect(yield* Effect.promise(() => failure.json())).toMatchObject({
      model: "@cf/deepgram/nova-3",
      profileId: selectedMediaProfile.id,
      language: "en",
      failure: { name: "Error", message: "6003: Invalid request input" },
    });
    const repeated = yield* Effect.promise(() =>
      Promise.resolve(cloudWorker.fetch(request("POST"), probeBindings)),
    );
    expect(repeated.status).toBe(409);
    expect(run).toHaveBeenCalledOnce();
  }),
);

it.effect("retains private input, raw Nova-3 output, and normalized channel evidence", () =>
  Effect.gen(function* () {
    const run = vi.fn().mockResolvedValue(providerResponse());
    const probeBindings = bindings(run);
    const upload = yield* Effect.promise(() =>
      Promise.resolve(cloudWorker.fetch(request("PUT", fixtureBytes()), probeBindings)),
    );
    expect(upload.status).toBe(201);

    const inference = yield* Effect.promise(() =>
      Promise.resolve(cloudWorker.fetch(request("POST"), probeBindings)),
    );
    expect(inference.status).toBe(200);
    const evidence = yield* Effect.promise(() => inference.json());
    expect(evidence).toMatchObject({
      fixture: "two-source-en",
      language: "en",
      profileId: selectedMediaProfile.id,
      byteLength: 128_044,
      durationMs: 2_000,
      providerLatencyMs: expect.any(Number),
      channelCount: 2,
      speakerCount: 3,
      turnCount: 3,
    });
    expect(run).toHaveBeenCalledOnce();
    expect(run.mock.calls[0]?.[0]).toBe("@cf/deepgram/nova-3");
    expect(run.mock.calls[0]?.[1]).toMatchObject({
      audio: { contentType: "audio/wav" },
      language: "en",
      channels: 2,
      multichannel: true,
      diarize: true,
    });

    const raw = yield* Effect.promise(() =>
      env.LOCAL_ARCHIVE.get("acceptance/issue-13/two-source-en/en/provider-result.json"),
    );
    const normalized = yield* Effect.promise(() =>
      env.LOCAL_ARCHIVE.get("acceptance/issue-13/two-source-en/en/normalized-revision.json"),
    );
    expect(raw).not.toBeNull();
    expect(normalized).not.toBeNull();
    if (normalized === null) {
      throw new Error("Expected normalized probe evidence");
    }
    const normalizedBody = yield* Effect.promise(() => normalized.json());
    expect(validateDocument("TranscriptRevision", normalizedBody)).toMatchObject({
      asr: { profileId: selectedMediaProfile.id },
      turns: [
        { trackId: expect.any(String), startMs: 100, endMs: 800 },
        { trackId: expect.any(String), startMs: 200, endMs: 900 },
        { trackId: expect.any(String), startMs: 1_100, endMs: 1_800 },
      ],
    });

    const cleanup = yield* Effect.promise(() =>
      Promise.resolve(cloudWorker.fetch(request("DELETE"), probeBindings)),
    );
    expect(cleanup.status).toBe(204);
    expect(
      yield* Effect.promise(() =>
        env.LOCAL_ARCHIVE.get("acceptance/issue-13/two-source-en/en/provider-result.json"),
      ),
    ).toBeNull();
  }),
);
