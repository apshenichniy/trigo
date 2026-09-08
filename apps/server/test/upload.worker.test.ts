import { env } from "cloudflare:workers";
import { Data, DateTime, Deferred, Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import {
  storedByteHash,
  uploadPartBytes,
  validateDocument,
  type FinalizeMasterUpload,
} from "@trigo/contracts";

import migration from "../migrations/0001_owner_identity.sql?raw";
import uploadMigration from "../migrations/0002_master_uploads.sql?raw";
import localWorker from "../src/local-worker.ts";
import { storedMaster } from "../src/master-finalization.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";
import { fenceMasterUploads, inspectUploadWriters } from "../src/upload-catalog.ts";
import { cafMasterHeader } from "../src/upload-streams.ts";
import { reconcileWriter } from "../src/upload-writers.ts";

const archiveId = ArchiveId.make("00000000-0000-4000-8000-000000000017");
const token = OwnerToken.make(`trigo_v1_${"1".repeat(64)}`);
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
class LostStorageAcknowledgement extends Data.TaggedError("LostStorageAcknowledgement")<{}> {}
const call = {
  schemaVersion: 1,
  archiveId,
  callId: id(101),
  documentVersion: 1,
  startedAt: "2026-09-08T00:00:00.000Z",
  endedAt: null,
  durationMs: null,
  captureState: "recording",
  interruptionReason: null,
  source: {
    applicationName: "Synthetic capture",
    bundleId: "test.trigo.upload",
    processId: 17,
    windowId: null,
    windowTitle: null,
  },
  tracks: ["microphone", "application"].map((role, channel) => ({
    trackId: id(102 + channel),
    role,
    inputDevice: null,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
    intervals: [],
  })),
  audioManifest: null,
  revisions: [],
  activeRevisionId: null,
  speakerNames: {},
};

beforeEach(async () => {
  vi.restoreAllMocks();
  const sql = `DROP TABLE IF EXISTS trigo_upload_writers;
    DROP TABLE IF EXISTS trigo_master_finalizations;
    DROP TABLE IF EXISTS trigo_upload_parts;
    DROP TABLE IF EXISTS trigo_master_uploads;
    DROP TABLE IF EXISTS trigo_owner_credential_operations;
    DROP TABLE IF EXISTS trigo_owner_credential_state;
    DROP TABLE IF EXISTS trigo_archive_identity; ${migration} ${uploadMigration}`;
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
      operationId: OwnerOperationId.make(id(17)),
      archiveId,
      verifierSha256: await Effect.runPromise(hashOwnerToken(token)),
      now: "2026-09-08T00:00:00.000Z",
    }),
  );
});

const registration = {
  schemaVersion: 1,
  uploadId: id(104),
  masterId: id(105),
  callDocument: JSON.stringify(call),
};

function jsonRequest(path: string, body: unknown, authorization = `Bearer ${token}`) {
  return localWorker.fetch(
    new Request(`http://localhost${path}`, {
      method: "POST",
      headers: { authorization, "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    env,
  );
}

async function register() {
  const response = await jsonRequest("/v1/calls", registration);
  expect(response.status).toBe(200);
  return validateDocument("MasterUploadSession", await response.json());
}

function masterBytes(durationMs: number) {
  const bytes = new Uint8Array(68 + durationMs * 64);
  bytes.set(cafMasterHeader);
  const view = new DataView(bytes.buffer);
  for (let frame = 0; frame < durationMs * 16; frame++) {
    // Distinct channels, retained initial silence, and a microphone-only mute interval.
    const value = frame < 32 ? 0 : (frame % 30000) + 1;
    view.setInt16(68 + frame * 4, frame >= 64 && frame < 96 ? 0 : value, true);
    view.setInt16(70 + frame * 4, -value, true);
  }
  return bytes;
}

async function put(index: number, bytes: Uint8Array, headers: Record<string, string> = {}) {
  const request = new Request(
    `http://localhost/v1/calls/${call.callId}/uploads/${registration.uploadId}/chunks/${index}`,
    {
      method: "PUT",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/octet-stream",
        "content-length": String(bytes.byteLength),
        "x-trigo-byte-offset": String(index * uploadPartBytes),
        "x-trigo-content-sha256": await storedByteHash(bytes),
        ...headers,
      },
      body: new Uint8Array(bytes),
    },
  );
  return localWorker.fetch(request, env);
}

async function finalInput(bytes: Uint8Array, durationMs: number): Promise<FinalizeMasterUpload> {
  const sha256 = await storedByteHash(bytes);
  const audioManifest = JSON.stringify({
    schemaVersion: 1,
    callId: call.callId,
    manifestId: id(109),
    durationMs,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
    objects:
      durationMs === 0
        ? []
        : [
            {
              objectId: registration.masterId,
              index: 0,
              contentType: "audio/x-caf",
              byteLength: bytes.byteLength,
              sha256,
              startMs: 0,
              endMs: durationMs,
              channelMap: [
                { channelIndex: 0, trackId: id(102) },
                { channelIndex: 1, trackId: id(103) },
              ],
            },
          ],
  });
  const closed = {
    ...call,
    documentVersion: 2,
    endedAt: DateTime.formatIso(DateTime.makeUnsafe(Date.parse(call.startedAt) + durationMs)),
    durationMs,
    captureState: "interrupted",
    interruptionReason: "application_terminated",
    tracks: call.tracks.map((track) => ({
      ...track,
      intervals:
        durationMs === 0
          ? []
          : [{ startMs: 0, endMs: durationMs, state: "recorded", reason: null }],
    })),
    audioManifest: {
      manifestId: id(109),
      sha256: await storedByteHash(new TextEncoder().encode(audioManifest)),
    },
  };
  return {
    schemaVersion: 1,
    uploadId: registration.uploadId,
    operationId: id(107),
    callDocument: JSON.stringify(closed),
    audioManifest,
    masterSHA256: sha256,
  };
}

const finalize = (input: FinalizeMasterUpload) =>
  jsonRequest(`/v1/calls/${call.callId}/finalize`, input);
const writers = () => Effect.runPromise(inspectUploadWriters(env.CATALOG, registration.uploadId));
const stored = () => Effect.runPromise(storedMaster(env.CATALOG, archiveId, call.callId));

it("admits a stable master identity before capture finishes and replays registration", async () => {
  const input = {
    schemaVersion: 1,
    uploadId: id(104),
    masterId: id(105),
    callDocument: JSON.stringify(call),
  };
  const request = () =>
    new Request("http://localhost/v1/calls", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(input),
    });
  const response = await localWorker.fetch(request(), env);
  expect(response.status).toBe(200);
  const receipt = await response.json();
  expect(receipt).toMatchObject({
    archiveId,
    callId: call.callId,
    uploadId: input.uploadId,
    masterId: input.masterId,
  });
  expect(await (await localWorker.fetch(request(), env)).json()).toEqual(receipt);
});

it("retains both sources and the common timeline through active-capture, out-of-order parts and final replay", async () => {
  await register();
  const bytes = masterBytes(135000);
  const final = await finalInput(bytes, 135000);
  // The first request occurs before the server has seen any closed call metadata.
  const first = await put(0, bytes.subarray(0, uploadPartBytes));
  expect(first.status).toBe(200);
  await expect(stored()).rejects.toThrow();
  expect((await finalize(final)).status).toBe(409);
  const tail = await put(1, bytes.subarray(uploadPartBytes));
  expect(tail.status).toBe(200);
  const firstReceipt = await first.json();
  expect(await (await put(0, bytes.subarray(0, uploadPartBytes))).json()).toEqual(firstReceipt);
  const response = await finalize(final);
  expect(response.status).toBe(200);
  const receipt = validateDocument("VerifiedMasterReceipt", await response.json());
  expect(receipt).toMatchObject({
    callId: call.callId,
    masterId: registration.masterId,
    durationMs: 135000,
    byteLength: bytes.byteLength,
    masterSHA256: final.masterSHA256,
    verification: "complete-master-sha256-v1",
    channelMap: [
      { channelIndex: 0, trackId: id(102) },
      { channelIndex: 1, trackId: id(103) },
    ],
  });
  const complete = await stored();
  const object = await env.LOCAL_ARCHIVE.get(complete.objectKey);
  expect(object).not.toBeNull();
  const retained = new Uint8Array(await object!.arrayBuffer());
  expect(retained.byteLength).toBe(bytes.byteLength);
  expect(await storedByteHash(retained)).toBe(await storedByteHash(bytes));
  for (const offset of [
    0,
    68,
    70,
    68 + 64 * 4,
    70 + 64 * 4,
    uploadPartBytes - 4,
    uploadPartBytes,
    bytes.length - 4,
  ]) {
    expect(Array.from(retained.subarray(offset, offset + 4))).toEqual(
      Array.from(bytes.subarray(offset, offset + 4)),
    );
  }
  expect(await (await finalize(final)).json()).toEqual(receipt);
  expect((await writers()).filter((writer) => writer.kind === "master")).toHaveLength(1);
}, 30000);

it("accepts genuinely out-of-order ranges and rejects conflicting identities and bodies", async () => {
  await register();
  const bytes = masterBytes(132000);
  expect((await put(1, bytes.subarray(uploadPartBytes))).status).toBe(200);
  expect((await finalize(await finalInput(bytes, 132000))).status).toBe(409);
  expect((await put(0, bytes.subarray(0, uploadPartBytes))).status).toBe(200);
  const tail = bytes.slice(uploadPartBytes);
  tail[0] = (tail[0] ?? 0) ^ 255;
  expect((await put(1, tail)).status).toBe(409);
  expect(
    (
      await put(1, tail, {
        "x-trigo-content-sha256": await storedByteHash(bytes.subarray(uploadPartBytes)),
      })
    ).status,
  ).toBe(400);
  expect((await writers()).filter((writer) => writer.kind === "part")).toHaveLength(2);
  expect((await finalize(await finalInput(bytes, 132000))).status).toBe(200);
}, 30000);

it("rejects oversized and malformed ranges before admitting an object writer", async () => {
  await register();
  const body = masterBytes(2);
  expect((await put(0, body, { "content-length": String(uploadPartBytes + 1) })).status).toBe(413);
  expect((await put(0, body, { "x-trigo-byte-offset": "1" })).status).toBe(400);
  expect((await put(83, body)).status).toBe(400);
  expect(await writers()).toHaveLength(0);
});

it("recovers a truncated request under the same content identity and retains the uncertain writer", async () => {
  await register();
  const bytes = masterBytes(2);
  const failed = await put(0, bytes.subarray(0, -1), {
    "content-length": String(bytes.length),
    "x-trigo-content-sha256": await storedByteHash(bytes),
  });
  expect(failed.status).not.toBe(200);
  await expect(stored()).rejects.toThrow();
  expect((await put(0, bytes)).status).toBe(200);
  expect((await writers()).map((writer) => writer.state).sort()).toEqual(["stored", "uncertain"]);
  expect((await finalize(await finalInput(bytes, 2))).status).toBe(200);
});

it("recovers a completed part when the storage acknowledgement was lost without repeating its PUT", async () => {
  await register();
  const bytes = masterBytes(2);
  const original = env.LOCAL_ARCHIVE.put.bind(env.LOCAL_ARCHIVE);
  const write = vi
    .spyOn(env.LOCAL_ARCHIVE, "put")
    .mockImplementationOnce(async (key, value, options) => {
      await original(key, value, options);
      throw new Error("Synthetic lost storage acknowledgement");
    });
  expect((await put(0, bytes)).status).toBe(503);
  expect((await writers())[0]?.state).toBe("uncertain");
  expect((await put(0, bytes)).status).toBe(200);
  expect(write).toHaveBeenCalledTimes(1);
  expect((await writers())[0]?.state).toBe("stored");
});

it("recovers the complete master after a lost final storage acknowledgement", async () => {
  await register();
  const bytes = masterBytes(2);
  expect((await put(0, bytes)).status).toBe(200);
  const input = await finalInput(bytes, 2);
  const original = env.LOCAL_ARCHIVE.put.bind(env.LOCAL_ARCHIVE);
  const write = vi
    .spyOn(env.LOCAL_ARCHIVE, "put")
    .mockImplementationOnce(async (key, value, options) => {
      await original(key, value, options);
      throw new Error("Synthetic lost final acknowledgement");
    });
  expect((await finalize(input)).status).toBe(503);
  await expect(stored()).rejects.toThrow();
  const response = await finalize(input);
  expect(response.status).toBe(200);
  expect(write).toHaveBeenCalledTimes(1);
  expect((await stored()).receipt).toEqual(await response.json());
});

it("does not publish partial, wrong-header, wrong-checksum or conflicting finalization", async () => {
  await register();
  const bytes = masterBytes(2);
  expect((await finalize(await finalInput(bytes, 2))).status).toBe(409);
  const badHeader = bytes.slice();
  badHeader[0] = 0;
  expect((await put(0, badHeader)).status).toBe(200);
  expect((await finalize(await finalInput(badHeader, 2))).status).toBe(400);
  await expect(stored()).rejects.toThrow();
  expect(
    (await finalize(Object.assign({}, await finalInput(bytes, 2), { operationId: id(117) })))
      .status,
  ).toBe(409);
});

it("checks declared master content even when every part has a valid checksum", async () => {
  await register();
  const bytes = masterBytes(2);
  const input = await finalInput(bytes, 2);
  const changed = bytes.slice();
  changed[69] = (changed[69] ?? 0) ^ 127;
  expect((await put(0, changed)).status).toBe(200);
  expect((await finalize(input)).status).not.toBe(200);
  await expect(stored()).rejects.toThrow();
});

it("fences an admitted writer while its PUT is in flight, including lost acknowledgement reconciliation", async () => {
  await register();
  const entered = Deferred.makeUnsafe<void>();
  const release = Deferred.makeUnsafe<void>();
  const original = env.LOCAL_ARCHIVE.put.bind(env.LOCAL_ARCHIVE);
  vi.spyOn(env.LOCAL_ARCHIVE, "put").mockImplementationOnce((key, value, options) =>
    Effect.runPromise(
      Effect.gen(function* () {
        yield* Deferred.succeed(entered, undefined);
        yield* Deferred.await(release);
        yield* Effect.promise(() => original(key, value, options));
        return yield* new LostStorageAcknowledgement();
      }),
    ),
  );
  const writing = put(0, masterBytes(2));
  await Effect.runPromise(Deferred.await(entered));
  expect((await writers())[0]?.state).toBe("admitted");
  await Effect.runPromise(fenceMasterUploads(env.CATALOG, archiveId, call.callId));
  await Effect.runPromise(Deferred.succeed(release, undefined));
  expect((await writing).status).toBe(503);
  const [writer] = await writers();
  expect(writer?.state).toBe("uncertain");
  expect(await env.LOCAL_ARCHIVE.head(writer!.object_key)).not.toBeNull();
  expect(await Effect.runPromise(reconcileWriter(env.CATALOG, env.LOCAL_ARCHIVE, writer!))).toBe(
    true,
  );
  expect((await writers())[0]?.state).toBe("stored");
  expect((await put(0, masterBytes(2))).status).toBe(410);
  expect((await jsonRequest("/v1/calls", registration)).status).toBe(410);
  expect((await finalize(await finalInput(masterBytes(2), 2))).status).toBe(410);
  await expect(stored()).rejects.toThrow();
});

it("stores the zero-frame interrupted master without inventing a timed audio object", async () => {
  await register();
  const bytes = masterBytes(0);
  expect((await put(0, bytes)).status).toBe(200);
  expect((await finalize(await finalInput(bytes, 0))).status).toBe(200);
  expect((await stored()).receipt).toMatchObject({ durationMs: 0, byteLength: 68 });
});

it("retains an in-flight final writer after deletion fencing and never publishes its late receipt", async () => {
  await register();
  const bytes = masterBytes(2);
  expect((await put(0, bytes)).status).toBe(200);
  const input = await finalInput(bytes, 2);
  const entered = Deferred.makeUnsafe<void>();
  const release = Deferred.makeUnsafe<void>();
  const original = env.LOCAL_ARCHIVE.put.bind(env.LOCAL_ARCHIVE);
  vi.spyOn(env.LOCAL_ARCHIVE, "put").mockImplementationOnce((key, value, options) =>
    Effect.runPromise(
      Effect.gen(function* () {
        yield* Deferred.succeed(entered, undefined);
        yield* Deferred.await(release);
        yield* Effect.promise(() => original(key, value, options));
        return yield* new LostStorageAcknowledgement();
      }),
    ),
  );
  const completing = finalize(input);
  await Effect.runPromise(Deferred.await(entered));
  expect((await writers()).find((writer) => writer.kind === "master")?.state).toBe("admitted");
  await Effect.runPromise(fenceMasterUploads(env.CATALOG, archiveId, call.callId));
  await Effect.runPromise(Deferred.succeed(release, undefined));
  expect((await completing).status).toBe(503);
  const writer = (await writers()).find((writer) => writer.kind === "master")!;
  expect(writer.state).toBe("uncertain");
  expect(await Effect.runPromise(reconcileWriter(env.CATALOG, env.LOCAL_ARCHIVE, writer))).toBe(
    true,
  );
  expect((await finalize(input)).status).toBe(410);
  await expect(stored()).rejects.toThrow();
  expect((await writers()).filter((writer) => writer.state === "stored")).toHaveLength(2);
});

it("rejects changed sources, closed duration and channel mapping before sealing finalization", async () => {
  await register();
  const bytes = masterBytes(2);
  expect((await put(0, bytes)).status).toBe(200);
  const input = await finalInput(bytes, 2);
  const closed = validateDocument("CallDocument", JSON.parse(input.callDocument));
  expect(
    (
      await finalize(
        Object.assign({}, input, {
          callDocument: JSON.stringify({
            ...closed,
            source: { ...closed.source, bundleId: "changed.source" },
          }),
        }),
      )
    ).status,
  ).toBe(400);
  expect(
    (
      await finalize(
        Object.assign({}, input, {
          callDocument: JSON.stringify({ ...closed, endedAt: "2026-09-08T00:00:00.003Z" }),
        }),
      )
    ).status,
  ).toBe(400);
  const audio = validateDocument("AudioManifest", JSON.parse(input.audioManifest));
  const swappedAudio = JSON.stringify({
    ...audio,
    objects: audio.objects.map((object) => ({
      ...object,
      channelMap: [
        { channelIndex: 0, trackId: id(103) },
        { channelIndex: 1, trackId: id(102) },
      ],
    })),
  });
  expect(
    (
      await finalize(
        Object.assign({}, input, {
          audioManifest: swappedAudio,
          callDocument: JSON.stringify({
            ...closed,
            audioManifest: {
              manifestId: audio.manifestId,
              sha256: await storedByteHash(new TextEncoder().encode(swappedAudio)),
            },
          }),
        }),
      )
    ).status,
  ).toBe(400);
  expect((await finalize(input)).status).toBe(200);
});

it("does not certify a completed part whose immutable object is missing", async () => {
  await register();
  const bytes = masterBytes(2);
  expect((await put(0, bytes)).status).toBe(200);
  const writer = (await writers())[0]!;
  await env.LOCAL_ARCHIVE.delete(writer.object_key);
  expect((await finalize(await finalInput(bytes, 2))).status).not.toBe(200);
  await expect(stored()).rejects.toThrow();
});

it("authenticates all upload routes before reading or admitting media", async () => {
  expect((await jsonRequest("/v1/calls", registration, "")).status).toBe(401);
  expect((await put(0, masterBytes(2), { authorization: "Bearer invalid" })).status).toBe(401);
  expect((await jsonRequest(`/v1/calls/${call.callId}/finalize`, {}, "")).status).toBe(401);
  expect(await writers()).toHaveLength(0);
});
