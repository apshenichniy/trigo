/* oxlint-disable effecttsgo/async-function, effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Disposable Worker fixtures use the native test/SDK boundary and independent real identities. */
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { vi } from "vitest";

import { storedByteHash, validateDocument } from "@trigo/contracts";

import ownerMigration from "../migrations/0001_owner_identity.sql?raw";
import uploadMigration from "../migrations/0002_master_uploads.sql?raw";
import transcriptionMigration from "../migrations/0003_transcriptions.sql?raw";
import { type Nova3Runner } from "../src/asr-probe.ts";
import { fakeTranscriptionRunner } from "../src/fake-transcription.ts";
import { MasterUploads, masterUploadsLayer } from "../src/master-uploads.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";
import { productFetch } from "../src/product-handler.ts";
import { type TranscriptionExecutionEnvironment } from "../src/transcription-submissions.ts";
import { cafMasterHeader } from "../src/upload-streams.ts";

export const transcriptionArchiveId = ArchiveId.make("00000000-0000-4000-8000-000000000018");
export const transcriptionToken = OwnerToken.make(`trigo_v1_${"4".repeat(64)}`);
export const owner = { archiveId: transcriptionArchiveId, credentialGeneration: 1 };

export async function resetTranscriptionFixture() {
  vi.restoreAllMocks();
  const tables = [
    "trigo_transcription_writers",
    "trigo_transcription_attempt_submissions",
    "trigo_asr_submissions",
    "trigo_transcription_attempts",
    "trigo_transcription_operations",
    "trigo_upload_writers",
    "trigo_master_finalizations",
    "trigo_upload_parts",
    "trigo_master_uploads",
    "trigo_owner_credential_operations",
    "trigo_owner_credential_state",
    "trigo_archive_identity",
  ];
  const sql =
    tables.map((table) => `DROP TABLE IF EXISTS ${table};`).join("\n") +
    ownerMigration +
    uploadMigration +
    transcriptionMigration;
  await env.CATALOG.batch(
    sql
      .split(";")
      .map((statement) => statement.trim())
      .filter(Boolean)
      .map((statement) => env.CATALOG.prepare(statement)),
  );
  await Effect.runPromise(
    applyOwnerOperation(env.CATALOG, {
      kind: "initialize",
      operationId: OwnerOperationId.make(crypto.randomUUID()),
      archiveId: transcriptionArchiveId,
      verifierSha256: await Effect.runPromise(hashOwnerToken(transcriptionToken)),
      now: "2026-09-08T00:00:00.000Z",
    }),
  );
}

export function fixtureRuntime(
  runner: Nova3Runner = fakeTranscriptionRunner,
): TranscriptionExecutionEnvironment {
  return {
    CATALOG: env.CATALOG,
    ARCHIVE: env.LOCAL_ARCHIVE,
    AI: runner,
    TRANSCRIPTION_MODE: "hosted",
    TRANSCRIPTION_WORKFLOW: {
      create: vi.fn(async ({ id }: { id: string }) => ({ id })),
      get: vi.fn(async () => ({
        status: async () => ({ status: "running" }),
        restart: async () => {},
      })),
    },
  };
}

export async function createUploadedCall(
  runtime: TranscriptionExecutionEnvironment,
  durationMs = 1000,
) {
  const callId = crypto.randomUUID();
  const uploadId = crypto.randomUUID();
  const masterId = crypto.randomUUID();
  const tracks = ["microphone", "application"].map((role) => ({
    trackId: crypto.randomUUID(),
    role,
    inputDevice: null,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
    intervals: [],
  }));
  const call = validateDocument("CallDocument", {
    schemaVersion: 2,
    archiveId: transcriptionArchiveId,
    callId,
    documentVersion: 1,
    startedAt: "2026-09-08T00:00:00.000Z",
    endedAt: null,
    durationMs: null,
    captureState: "recording",
    interruptionReason: null,
    source: {
      applicationName: "Transcription fixture",
      bundleId: "test.trigo.asr",
      processId: 18,
      windowId: null,
      windowTitle: null,
    },
    tracks,
    audioManifest: null,
    revisions: [],
    activeRevisionId: null,
    speakerNames: {},
    speakerGroups: {},
  });
  const bytes = new Uint8Array(68 + durationMs * 64);
  bytes.set(cafMasterHeader);
  const sha256 = await storedByteHash(bytes);
  const audioManifest = JSON.stringify({
    schemaVersion: 1,
    callId,
    manifestId: crypto.randomUUID(),
    durationMs,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
    objects:
      durationMs === 0
        ? []
        : [
            {
              objectId: masterId,
              index: 0,
              contentType: "audio/x-caf",
              byteLength: bytes.byteLength,
              sha256,
              startMs: 0,
              endMs: durationMs,
              channelMap: tracks.map((track, channelIndex) => ({
                channelIndex,
                trackId: track.trackId,
              })),
            },
          ],
  });
  const encodedCall = JSON.stringify(call);
  const receipt = await Effect.runPromise(
    Effect.gen(function* () {
      const uploads = yield* MasterUploads;
      yield* uploads.register({
        schemaVersion: 1,
        uploadId,
        masterId,
        callDocument: encodedCall,
      });
      yield* uploads.part(
        callId,
        uploadId,
        { index: 0, byteOffset: 0, byteLength: bytes.byteLength, sha256 },
        new Response(bytes).body!,
      );
      return yield* uploads.finalize(callId, {
        schemaVersion: 1,
        operationId: crypto.randomUUID(),
        uploadId,
        captureState: "stopped",
        durationMs,
        sourceStates: {
          encoding: "source-states-2bit-ms-v1",
          data: btoa("\0".repeat(Math.ceil(durationMs / 2))),
        },
        audioManifest,
        masterSHA256: sha256,
      });
    }).pipe(Effect.provide(masterUploadsLayer(runtime, owner))),
  );
  return { call, receipt, bytes, uploadId };
}

export const transcriptionCommand = () =>
  validateDocument("RequestTranscription", {
    schemaVersion: 1,
    operationId: crypto.randomUUID(),
    revisionId: crypto.randomUUID(),
    requestedLanguage: "en",
    profileId: "nova3-wav-s16le-16000-stereo-stream-v1",
  });

export function requestProduct(
  runtime: TranscriptionExecutionEnvironment,
  path: string,
  body?: unknown,
  token: string = transcriptionToken,
) {
  return productFetch(
    new Request(`https://fixture.test${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }),
    { ...runtime, DEPLOYMENT_STAGE: "dev" },
  );
}

export const speechResponse = () => ({
  metadata: { duration: 1, channels: 2, request_id: "fixture-provider-operation" },
  results: {
    channels: ["microphone", "application"].map((source) => ({
      alternatives: [
        {
          transcript: `Hello ${source}.`,
          words: [
            {
              word: "hello",
              punctuated_word: "Hello",
              start: 0.1,
              end: 0.2,
              speaker: 0,
              confidence: 0.9,
            },
            { word: source, punctuated_word: `${source}.`, start: 0.3, end: 0.4, speaker: 0 },
          ],
        },
      ],
    })),
  },
});

export function speechRunner() {
  return {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      await fakeTranscriptionRunner.run(model, input);
      return Response.json(speechResponse(), {
        headers: { "cf-ai-req-id": "fixture-provider-operation" },
      });
    }),
  } satisfies Nova3Runner;
}
