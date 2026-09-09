import { Context, Effect, Layer } from "effect";

import { makeWaveHeader, playbackSegmentFrames, storedByteHash } from "@trigo/contracts";

import { readBoundedBody } from "./nova-3-transport.ts";
import { type PlaybackEnvironment } from "./playback-catalog.ts";
import { PlaybackError, playbackError, playbackStorage } from "./playback-errors.ts";
import { authorizePlaybackGrant, loadPlaybackMaster } from "./playback-grants.ts";
import { objectMatches } from "./upload-streams.ts";

interface ByteRange {
  readonly start: number;
  readonly length: number;
  readonly partial: boolean;
}
export const playbackByteRange = Effect.fn("Playback.byteRange")(function* (
  range: string | null,
  byteLength: number,
) {
  if (range === null) {
    return { start: 0, length: byteLength, partial: false };
  }
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (!match || (!match[1] && !match[2])) {
    return yield* playbackError("playback_range_invalid", byteLength);
  }
  let start: number;
  let end: number;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) {
      return yield* playbackError("playback_range_invalid", byteLength);
    }
    start = Math.max(0, byteLength - suffix);
    end = byteLength - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : byteLength - 1;
  }
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    start < 0 ||
    start >= byteLength ||
    end < start
  ) {
    return yield* playbackError("playback_range_invalid", byteLength);
  }
  return {
    start,
    length: Math.min(end, byteLength - 1) - start + 1,
    partial: true,
  } satisfies ByteRange;
});

const readPCM = Effect.fn("Playback.readPCM")(function* (
  env: PlaybackEnvironment,
  source: { objectKey: string; receipt: { byteLength: number; masterSHA256: string } },
  offset: number,
  length: number,
) {
  const object = yield* playbackStorage(() =>
    env.ARCHIVE.get(source.objectKey, { range: { offset, length } }),
  );
  if (
    !object ||
    !("body" in object) ||
    !objectMatches(object, {
      object_key: source.objectKey,
      byte_length: source.receipt.byteLength,
      sha256: source.receipt.masterSHA256,
    })
  ) {
    if (object && "body" in object) {
      yield* playbackStorage(() => object.body.cancel()).pipe(Effect.ignore);
    }
    return yield* playbackError("playback_storage_unavailable");
  }
  const bytes = yield* readBoundedBody(object.body, length).pipe(
    Effect.mapError(() => playbackError("playback_storage_unavailable")),
  );
  if (bytes.byteLength !== length) {
    return yield* playbackError("playback_storage_unavailable");
  }
  return bytes;
});

export interface PlaybackSegment {
  readonly bytes: Uint8Array;
  readonly sha256: string;
  readonly byteRange: ByteRange;
  readonly totalByteLength: number;
  readonly startFrame: number;
  readonly frameCount: number;
}
export const readPlaybackSegment = Effect.fn("Playback.segment")(function* (
  env: PlaybackEnvironment,
  callId: string,
  grantId: string,
  index: number,
  authorization: string | null,
  range: string | null,
) {
  const { owner } = yield* authorizePlaybackGrant(env, grantId, callId, authorization);
  const source = yield* loadPlaybackMaster(env, owner, callId);
  if (!Number.isSafeInteger(index) || index < 0 || index >= source.media.segmentCount) {
    return yield* playbackError("playback_range_invalid");
  }
  const startFrame = index * playbackSegmentFrames;
  const frameCount = Math.min(playbackSegmentFrames, source.media.frameCount - startFrame);
  const totalByteLength = 44 + frameCount * 4;
  const byteRange = yield* playbackByteRange(range, totalByteLength);
  const bytes = new Uint8Array(byteRange.length);
  const end = byteRange.start + byteRange.length;
  const headerEnd = Math.min(44, end);
  if (byteRange.start < headerEnd) {
    bytes.set(makeWaveHeader(frameCount).subarray(byteRange.start, headerEnd));
  }
  const pcmStart = Math.max(44, byteRange.start);
  if (end > pcmStart) {
    const pcm = yield* readPCM(env, source, 68 + startFrame * 4 + pcmStart - 44, end - pcmStart);
    bytes.set(pcm, pcmStart - byteRange.start);
  }
  // Check again after the asynchronous R2 read. A grant/call invalidated while loading
  // cannot deliver its buffered response; every subsequent segment repeats this check.
  const sha256 = yield* Effect.promise(() => storedByteHash(bytes));
  yield* authorizePlaybackGrant(env, grantId, callId, authorization);
  return {
    bytes,
    sha256,
    byteRange,
    totalByteLength,
    startFrame,
    frameCount,
  } satisfies PlaybackSegment;
});

export class PlaybackMedia extends Context.Service<
  PlaybackMedia,
  {
    readonly segment: (
      callId: string,
      grantId: string,
      index: number,
      authorization: string | null,
      range: string | null,
    ) => Effect.Effect<PlaybackSegment, PlaybackError>;
  }
>()("PlaybackMedia") {}
export const playbackMediaLayer = (env: PlaybackEnvironment) =>
  Layer.succeed(
    PlaybackMedia,
    PlaybackMedia.of({
      segment: (callId, grantId, index, authorization, range) =>
        readPlaybackSegment(env, callId, grantId, index, authorization, range),
    }),
  );
