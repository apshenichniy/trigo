/* oxlint-disable effecttsgo/async-function, effecttsgo/crypto-random-uuid -- Worker HTTP/SDK fixtures use isolated storage and explicit synchronization. */
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { beforeEach, expect, it, vi } from "vitest";

import {
  parseStored,
  playbackSegmentFrames,
  storedByteHash,
  validateDocument,
} from "@trigo/contracts";

import migration from "../migrations/0004_playback_grants.sql?raw";
import { requestPlayback } from "../src/playback-grants.ts";
import { productFetch } from "../src/product-handler.ts";
import { fenceMasterUploads } from "../src/upload-catalog.ts";
import {
  createUploadedCall,
  fixtureRuntime,
  owner,
  requestProduct,
  resetTranscriptionFixture,
  transcriptionToken,
} from "./transcription-fixture.ts";

beforeEach(async () => {
  await env.CATALOG.prepare("DROP TABLE IF EXISTS trigo_playback_grants").run();
  await resetTranscriptionFixture();
  await env.CATALOG.batch(
    migration
      .split(";")
      .map((sql) => sql.trim())
      .filter(Boolean)
      .map((sql) => env.CATALOG.prepare(sql)),
  );
});

const command = () => ({ schemaVersion: 1, operationId: crypto.randomUUID() });
const runtime = () =>
  fixtureRuntime({
    run: vi.fn(async () => {
      throw new Error("Playback must not invoke ASR");
    }),
  });
const readGrant = async (response: Response) => {
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  return validateDocument("PlaybackGrant", await response.json());
};
const mediaRequest = (
  server: ReturnType<typeof fixtureRuntime>,
  grant: { callId: string; grantId: string; token: string },
  index: number,
  range?: string,
) =>
  productFetch(
    new Request(
      `https://trigo.test/v1/calls/${grant.callId}/playback/${grant.grantId}/segments/${index}`,
      {
        headers: { authorization: `Bearer ${grant.token}`, ...(range ? { range } : {}) },
      },
    ),
    { ...server, DEPLOYMENT_STAGE: "dev" },
  );

it("issues replayable independent grants for verified media without requiring a transcript", async () => {
  const server = runtime();
  const { call, receipt } = await createUploadedCall(server);
  const input = command();
  const grants = await Promise.all(
    [0, 1].map(async () =>
      readGrant(await requestProduct(server, `/v1/calls/${call.callId}/playback`, input)),
    ),
  );
  expect(grants[0]).toEqual(grants[1]);
  const grant = grants[0]!;
  expect(grant.grantId).not.toBe(input.operationId);
  expect(grant.media).toMatchObject({
    masterId: receipt.masterId,
    masterSHA256: receipt.masterSHA256,
    frameCount: 16_000,
    segmentCount: 1,
  });
  expect(
    grant.media.channels.map((channel) => [channel.channelIndex, channel.trackId, channel.role]),
  ).toEqual(call.tracks.map((track, index) => [index, track.trackId, track.role]));
  expect(JSON.stringify(grant)).not.toContain(transcriptionToken);
  expect(server.AI.run).not.toHaveBeenCalled();
  const other = await createUploadedCall(server);
  expect(
    (await requestProduct(server, `/v1/calls/${other.call.callId}/playback`, input)).status,
  ).toBe(409);
  expect(
    (
      await requestProduct(server, `/v1/calls/${call.callId}/playback`, {
        ...command(),
        objectKey: "arbitrary",
      })
    ).status,
  ).toBe(400);
});

it("serves exact aligned stereo segments and bounded byte ranges with private caching", async () => {
  const server = runtime();
  const { call, bytes } = await createUploadedCall(server, 31_001, (pcm) => {
    for (const [frame, left, right] of [
      [0, 12000, -7000],
      [479999, 31000, -12000],
      [480000, -10000, 23000],
      [496015, 9000, -3000],
    ]) {
      pcm.setInt16(frame! * 4, left!, true);
      pcm.setInt16(frame! * 4 + 2, right!, true);
    }
  });
  const grant = await readGrant(
    await requestProduct(server, `/v1/calls/${call.callId}/playback`, command()),
  );
  const reads = vi.spyOn(env.LOCAL_ARCHIVE, "get");
  const first = await mediaRequest(server, grant, 0);
  expect(first.status).toBe(200);
  expect(first.headers.get("cache-control")).toBe("private, no-store");
  expect(first.headers.get("accept-ranges")).toBe("bytes");
  const firstBytes = new Uint8Array(await first.arrayBuffer());
  expect(firstBytes.byteLength).toBe(44 + playbackSegmentFrames * 4);
  expect(first.headers.get("x-trigo-content-sha256")).toBe(await storedByteHash(firstBytes));
  expect(firstBytes.subarray(44)).toEqual(bytes.subarray(68, 68 + playbackSegmentFrames * 4));
  const view = new DataView(firstBytes.buffer);
  expect([view.getUint16(22, true), view.getUint32(24, true), view.getUint32(40, true)]).toEqual([
    2,
    16000,
    playbackSegmentFrames * 4,
  ]);
  expect([view.getInt16(44, true), view.getInt16(46, true)]).toEqual([12000, -7000]);
  const second = await mediaRequest(server, grant, 1);
  expect(second.headers.get("x-trigo-start-frame")).toBe("480000");
  const secondBytes = new Uint8Array(await second.arrayBuffer());
  expect(secondBytes.subarray(44)).toEqual(bytes.subarray(68 + playbackSegmentFrames * 4));
  expect(secondBytes.byteLength).toBe(44 + 1001 * 64);
  const range = await mediaRequest(server, grant, 0, "bytes=40-51");
  expect(range.status).toBe(206);
  expect(range.headers.get("content-range")).toBe("bytes 40-51/1920044");
  expect(new Uint8Array(await range.arrayBuffer())).toEqual(firstBytes.slice(40, 52));
  const suffix = await mediaRequest(server, grant, 1, "bytes=-8");
  expect(new Uint8Array(await suffix.arrayBuffer())).toEqual(secondBytes.slice(-8));
  for (const invalid of ["bytes=1920044-", "bytes=8-4", "bytes=0-1,4-8", "bytes=-0"]) {
    const rejected = await mediaRequest(server, grant, 0, invalid);
    expect(rejected.status).toBe(416);
    expect(rejected.headers.get("content-range")).toBe("bytes */1920044");
    expect(rejected.headers.get("cache-control")).toBe("private, no-store");
  }
  expect((await mediaRequest(server, grant, 2)).status).toBe(416);
  expect(
    reads.mock.calls.every(
      ([, options]) =>
        options?.range && "length" in options.range && options.range.length! <= 1_920_000,
    ),
  ).toBe(true);
  expect(server.AI.run).not.toHaveBeenCalled();
});

it("keeps authentication and schema rejection responses out of public caches", async () => {
  const server = runtime();
  for (const request of [
    new Request(`https://trigo.test/v1/calls/${crypto.randomUUID()}/playback`, { method: "POST" }),
    new Request("https://trigo.test/v1/calls/malformed/playback/malformed/segments/0"),
  ]) {
    const response = await productFetch(request, { ...server, DEPLOYMENT_STAGE: "dev" });
    expect(response.status).toBeGreaterThanOrEqual(400);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("vary")).toBe("Authorization");
  }
});

it("expires a real signed grant without sleeping and renews with the same media timeline", async () => {
  const server = runtime();
  const { call } = await createUploadedCall(server);
  const expired = await Effect.runPromise(
    requestPlayback(server, owner, call.callId, command()).pipe(Effect.provide(TestClock.layer())),
  );
  const denied = await mediaRequest(server, expired, 0);
  expect(denied.status).toBe(401);
  expect(parseStored("ErrorEnvelope", new Uint8Array(await denied.arrayBuffer())).error.code).toBe(
    "playback_grant_expired",
  );
  const fresh = await readGrant(
    await requestProduct(server, `/v1/calls/${call.callId}/playback`, command()),
  );
  expect(fresh.media).toEqual(expired.media);
  expect((await mediaRequest(server, fresh, 0)).status).toBe(200);
  expect(fresh.grantId).not.toBe(expired.grantId);
});

it("rejects forged, cross-call, owner-token and rotated capabilities before reading media", async () => {
  const server = runtime();
  const { call } = await createUploadedCall(server);
  const grant = await readGrant(
    await requestProduct(server, `/v1/calls/${call.callId}/playback`, command()),
  );
  const reads = vi.spyOn(env.LOCAL_ARCHIVE, "get");
  const altered = grant.token.slice(0, -1) + (grant.token.endsWith("0") ? "1" : "0");
  for (const invalid of [
    { ...grant, token: altered },
    { ...grant, token: transcriptionToken },
    { ...grant, callId: crypto.randomUUID() },
  ]) {
    expect((await mediaRequest(server, invalid, 0)).status).toBe(401);
  }
  await env.CATALOG.prepare(
    "UPDATE trigo_owner_credential_state SET generation=generation+1",
  ).run();
  expect((await mediaRequest(server, grant, 0)).status).toBe(401);
  expect(reads).not.toHaveBeenCalled();
});

it("discards an in-flight segment after deletion and rejects subsequent grants", async () => {
  const server = runtime();
  const { call } = await createUploadedCall(server);
  const grant = await readGrant(
    await requestProduct(server, `/v1/calls/${call.callId}/playback`, command()),
  );
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  const original = env.LOCAL_ARCHIVE.get.bind(env.LOCAL_ARCHIVE);
  vi.spyOn(env.LOCAL_ARCHIVE, "get").mockImplementation(async (key, options) => {
    const object = await original(key, options);
    started.resolve();
    await release.promise;
    return object;
  });
  const loading = mediaRequest(server, grant, 0);
  await started.promise;
  await Effect.runPromise(fenceMasterUploads(env.CATALOG, owner.archiveId, call.callId));
  release.resolve();
  const response = await loading;
  expect(response.status).toBe(410);
  expect(response.headers.get("content-type")).toContain("application/json");
  expect(
    (await requestProduct(server, `/v1/calls/${call.callId}/playback`, command())).status,
  ).toBe(410);
});

it("reports missing storage and no-audio calls without inventing available media", async () => {
  const server = runtime();
  const empty = await createUploadedCall(server, 0);
  expect(
    (await requestProduct(server, `/v1/calls/${empty.call.callId}/playback`, command())).status,
  ).toBe(409);
  const { call } = await createUploadedCall(server);
  const grant = await readGrant(
    await requestProduct(server, `/v1/calls/${call.callId}/playback`, command()),
  );
  vi.spyOn(env.LOCAL_ARCHIVE, "get").mockResolvedValue(null);
  expect((await mediaRequest(server, grant, 0)).status).toBe(503);
});
