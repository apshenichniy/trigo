// oxlint-disable-next-line effecttsgo/node-builtin-import -- Incremental SHA-256 keeps streamed call audio outside whole-buffer Web Crypto APIs.
import { createHash } from "node:crypto";

import { Effect, Option, Schema, Stream } from "effect";

import { CanonicalUUIDv4, SHA256 } from "@trigo/contracts";

import { selectedCaptureMasterProfile } from "../../../packages/contracts/src/capture-master-profile.ts";
import { readBoundedBody } from "./nova-3-transport.ts";

const maximumFrames = selectedCaptureMasterProfile.maxCallDurationMs * 16;
const Frame = Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: maximumFrames }));
const MillisecondFrame = Frame.check(Schema.isMultipleOf(16));
const ByteLength = Schema.Int.check(
  Schema.isBetween({ minimum: 68, maximum: selectedCaptureMasterProfile.maxMasterBytes }),
);

/** The caller resolves this witness only from completed, verified master storage. */
export const AsrMaster = Schema.Struct({
  callId: CanonicalUUIDv4,
  masterId: CanonicalUUIDv4,
  manifestId: CanonicalUUIDv4,
  manifestSha256: SHA256,
  sha256: SHA256,
  frameCount: MillisecondFrame.check(Schema.isGreaterThan(0)),
  byteLength: ByteLength,
  mediaProfileId: Schema.Literal("caf-lpcm-s16le-16000-stereo-v1"),
  microphoneTrackId: CanonicalUUIDv4,
  applicationTrackId: CanonicalUUIDv4,
}).check(
  Schema.makeFilter(
    (master) =>
      master.byteLength === 68 + master.frameCount * 4 &&
      master.microphoneTrackId !== master.applicationTrackId,
    {
      expected:
        "a complete stereo CAF master with distinct source tracks and an exact frame/byte witness",
    },
  ),
);
export interface AsrMaster extends Schema.Schema.Type<typeof AsrMaster> {}

export const AsrSubmissionInterval = Schema.Struct({
  submissionId: CanonicalUUIDv4,
  index: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 179 })),
  startFrame: MillisecondFrame,
  endFrame: MillisecondFrame,
}).check(
  Schema.makeFilter((interval) => interval.endFrame > interval.startFrame, {
    expected: "a nonempty frame interval",
  }),
);
export interface AsrSubmissionInterval extends Schema.Schema.Type<typeof AsrSubmissionInterval> {}

export const AsrExtractionEvidence = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  master: AsrMaster,
  interval: AsrSubmissionInterval,
  transform: Schema.Literal("caf-lpcm-to-wave-pcm-frame-slice-v1"),
  contentType: Schema.Literal("audio/wav"),
  codec: Schema.Literal("pcm_s16le"),
  sampleRateHz: Schema.Literal(16_000),
  channels: Schema.Literal(2),
  microphoneChannel: Schema.Literal(0),
  applicationChannel: Schema.Literal(1),
  byteLength: Schema.Int.check(Schema.isGreaterThan(44)),
  sha256: SHA256,
  startMs: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  endMs: Schema.Int.check(Schema.isGreaterThan(0)),
}).check(
  Schema.makeFilter(
    (evidence) => {
      const { interval, master } = evidence;
      return (
        interval.endFrame <= master.frameCount &&
        interval.submissionId !== master.masterId &&
        evidence.startMs * 16 === interval.startFrame &&
        evidence.endMs * 16 === interval.endFrame &&
        evidence.byteLength === 44 + (interval.endFrame - interval.startFrame) * 4
      );
    },
    { expected: "exact source frame, channel, byte and call-time provenance" },
  ),
);
export interface AsrExtractionEvidence extends Schema.Schema.Type<typeof AsrExtractionEvidence> {}

export class AsrExtractionError extends Schema.TaggedError<AsrExtractionError>()(
  "Asr.ExtractionError",
  {
    operation: Schema.String,
    message: Schema.String,
  },
) {}

function failure(operation: string, message: string) {
  return new AsrExtractionError({ operation, message });
}

export interface AsrMasterSource {
  readonly read: (offset: number, length: number) => Effect.Effect<Uint8Array, AsrExtractionError>;
}

/** Two bounded passes over a three-hour master stay below 1,000 internal subrequests. */
export const asrReadRangeBytes = 2_097_152;

/** Matches the native immutable CAF header, including its indefinite last data chunk. */
export function makeAsrMasterHeader(): Uint8Array {
  const bytes = new Uint8Array(68);
  const view = new DataView(bytes.buffer);
  const text = (offset: number, value: string) =>
    bytes.set(new TextEncoder().encode(value), offset);
  text(0, "caff");
  view.setUint16(4, 1);
  text(8, "desc");
  view.setBigInt64(12, 32n);
  view.setFloat64(20, 16_000);
  text(28, "lpcm");
  for (const [index, value] of [2, 4, 1, 2, 16].entries()) {
    view.setUint32(32 + index * 4, value);
  }
  text(52, "data");
  view.setBigInt64(56, -1n);
  return bytes;
}

/** Submission WAVE limits are independent of the historical 60-second storage profile. */
export function makeAsrWaveHeader(frameCount: number): Uint8Array {
  Schema.decodeSync(MillisecondFrame.check(Schema.isGreaterThan(0)))(frameCount);
  const bytes = new Uint8Array(44);
  const view = new DataView(bytes.buffer);
  const text = (offset: number, value: string) =>
    bytes.set(new TextEncoder().encode(value), offset);
  text(0, "RIFF");
  view.setUint32(4, 36 + frameCount * 4, true);
  text(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 2, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 64_000, true);
  view.setUint16(32, 4, true);
  view.setUint16(34, 16, true);
  text(36, "data");
  view.setUint32(40, frameCount * 4, true);
  return bytes;
}

/** This is a coverage plan; only hosted evidence can establish a supported interval size. */
export const planMasterSubmissions = Effect.fn("Asr.planMasterSubmissions")(function* (
  unknownMaster: unknown,
  intervalDurationMs: number,
  makeId: () => string,
) {
  const master = yield* Schema.decodeUnknownEffect(AsrMaster)(unknownMaster).pipe(
    Effect.mapError(() => failure("plan", "Invalid completed master witness")),
  );
  const duration = yield* Schema.decodeEffect(
    Schema.Int.check(
      Schema.isBetween({
        minimum: 60_000,
        maximum: selectedCaptureMasterProfile.maxCallDurationMs,
      }),
    ),
  )(intervalDurationMs).pipe(
    Effect.mapError(() =>
      failure("plan", "An interval plan must use one minute through three hours"),
    ),
  );
  const count = Math.ceil(master.frameCount / (duration * 16));
  const intervals = yield* Effect.forEach(
    Array.from({ length: count }, (_, index) => index),
    (index) =>
      Schema.decodeEffect(AsrSubmissionInterval)({
        submissionId: makeId(),
        index,
        startFrame: index * duration * 16,
        endFrame: Math.min((index + 1) * duration * 16, master.frameCount),
      }).pipe(Effect.mapError(() => failure("plan", "Invalid submission identity or interval"))),
  );
  if (
    new Set(intervals.map((interval) => interval.submissionId)).size !== intervals.length ||
    intervals.some((interval) => interval.submissionId === master.masterId)
  ) {
    return yield* failure(
      "plan",
      "Each submission needs its own identity, distinct from the retained master",
    );
  }
  return intervals;
});

/** R2 object version is fenced on every bounded range. The key comes from server admission. */
export const r2MasterSource = (
  bucket: Pick<R2Bucket, "get">,
  objectKey: string,
  master: AsrMaster,
): AsrMasterSource => {
  let etag: string | undefined;
  return {
    read: Effect.fn("Asr.R2Master.read")(function* (offset: number, length: number) {
      if (
        !Number.isSafeInteger(offset) ||
        !Number.isSafeInteger(length) ||
        length <= 0 ||
        length > asrReadRangeBytes ||
        offset < 0 ||
        offset + length > master.byteLength
      ) {
        return yield* failure(
          "readRange",
          "Range is outside the completed master or exceeds the bounded read size",
        );
      }
      const object = yield* Effect.tryPromise({
        try: () =>
          bucket.get(objectKey, {
            range: { offset, length },
            ...(etag === undefined ? {} : { onlyIf: { etagMatches: etag } }),
          }),
        catch: () => failure("readRange", "Private master range is unavailable"),
      });
      if (
        object === null ||
        !("body" in object) ||
        object.size !== master.byteLength ||
        (etag !== undefined && object.etag !== etag)
      ) {
        return yield* failure(
          "readRange",
          "Private master is missing, changed, or has an unexpected length",
        );
      }
      etag = object.etag;
      const bytes = yield* readBoundedBody(object.body, length).pipe(
        Effect.mapError(() =>
          failure("readRange", "Private master range is unreadable or exceeds the requested size"),
        ),
      );
      if (bytes.byteLength !== length) {
        return yield* failure("readRange", "Private master returned an incomplete range");
      }
      return bytes;
    }),
  };
};

/** Hash evidence covers every produced byte; the transport owns the separate consumer EOF witness. */
export const extractMasterWave = Effect.fn("Asr.extractMasterWave")(function* (
  source: AsrMasterSource,
  unknownMaster: unknown,
  unknownInterval: unknown,
) {
  const master = yield* Schema.decodeUnknownEffect(AsrMaster)(unknownMaster).pipe(
    Effect.mapError(() => failure("extract", "Invalid master witness")),
  );
  const interval = yield* Schema.decodeUnknownEffect(AsrSubmissionInterval)(unknownInterval).pipe(
    Effect.mapError(() => failure("extract", "Invalid submission interval")),
  );
  if (interval.endFrame > master.frameCount || interval.submissionId === master.masterId) {
    return yield* failure(
      "extract",
      "Submission exceeds or reuses the identity of its parent master",
    );
  }
  const sourceHeader = yield* source.read(0, 68);
  const expectedHeader = makeAsrMasterHeader();
  if (
    sourceHeader.byteLength !== expectedHeader.byteLength ||
    sourceHeader.some((byte, index) => byte !== expectedHeader[index])
  ) {
    return yield* failure("extract", "Master bytes do not match the native CAF profile");
  }
  const start = 68 + interval.startFrame * 4;
  const end = 68 + interval.endFrame * 4;
  const header = makeAsrWaveHeader(interval.endFrame - interval.startFrame);
  const digest = createHash("sha256");
  let completed: AsrExtractionEvidence | undefined;
  let consumed = false;
  const pcm = Stream.paginate(start, (offset) =>
    Effect.gen(function* () {
      const length = Math.min(asrReadRangeBytes, end - offset);
      const chunk = yield* source.read(offset, length);
      if (chunk.byteLength !== length) {
        return yield* failure("extract", "Source did not return the exact requested PCM interval");
      }
      const next = offset + length;
      return [[chunk], next === end ? Option.none() : Option.some(next)] as const;
    }),
  );
  let writtenBytes = 0;
  const hashChunk = (chunk: Uint8Array) =>
    Effect.sync(() => {
      digest.update(chunk);
      writtenBytes += chunk.byteLength;
      if (writtenBytes !== 44 + end - start) {
        return;
      }
      completed = AsrExtractionEvidence.make({
        schemaVersion: 1,
        master,
        interval,
        transform: "caf-lpcm-to-wave-pcm-frame-slice-v1",
        contentType: "audio/wav",
        codec: "pcm_s16le",
        sampleRateHz: 16_000,
        channels: 2,
        microphoneChannel: 0,
        applicationChannel: 1,
        byteLength: 44 + end - start,
        sha256: digest.digest("hex"),
        startMs: interval.startFrame / 16,
        endMs: interval.endFrame / 16,
      });
    });
  const stream = Stream.unwrap(
    Effect.gen(function* () {
      if (consumed) {
        return yield* failure("extract", "A submission stream may be consumed only once");
      }
      consumed = true;
      return Stream.concat(Stream.make(header), pcm).pipe(Stream.tap(hashChunk));
    }),
  );
  const evidence = Effect.fn("Asr.extractionEvidence")(function* () {
    if (completed === undefined) {
      return yield* failure("extract", "Complete extraction has not been produced");
    }
    return completed;
  });
  return { stream, evidence, byteLength: 44 + end - start };
});
