import { expect, it } from "@effect/vitest";
import { Effect, Stream } from "effect";

import { storedByteHash } from "@trigo/contracts";

import {
  AsrMaster,
  asrReadRangeBytes,
  extractMasterWave,
  makeAsrMasterHeader,
  makeAsrWaveHeader,
  planMasterSubmissions,
  type AsrMasterSource,
} from "../src/asr-master.ts";

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const nativeHeaderHex =
  "636166660001000064657363000000000000002040cf4000000000006c70636d000000020000000400000001000000020000001064617461ffffffffffffffff00000000";

function master(durationMs: number): AsrMaster {
  return AsrMaster.make({
    callId: id(1),
    masterId: id(2),
    manifestId: id(3),
    manifestSha256: "a".repeat(64),
    sha256: "b".repeat(64),
    frameCount: durationMs * 16,
    byteLength: 68 + durationMs * 64,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
    microphoneTrackId: id(4),
    applicationTrackId: id(5),
  });
}

it.effect(
  "matches the native CAF witness and extracts exact interleaved source bytes at the original time",
  () =>
    Effect.gen(function* () {
      expect(
        Array.from(makeAsrMasterHeader(), (n) => n.toString(16).padStart(2, "0")).join(""),
      ).toBe(nativeHeaderHex);
      const witness = master(3);
      const caf = new Uint8Array(witness.byteLength);
      caf.set(makeAsrMasterHeader());
      for (let i = 68; i < caf.length; i++) {
        caf[i] = i % 251;
      }
      const source: AsrMasterSource = {
        read: (_offset, _length) => Effect.succeed(caf.slice(_offset, _offset + _length)),
      };
      const interval = { submissionId: id(6), index: 0, startFrame: 16, endFrame: 48 };
      const extraction = yield* extractMasterWave(source, witness, interval);
      const chunks = yield* Stream.runCollect(extraction.stream);
      const actual = new Uint8Array(chunks.flatMap((chunk) => [...chunk]));
      const expected = new Uint8Array(44 + 32 * 4);
      expected.set(makeAsrWaveHeader(32));
      expected.set(caf.slice(68 + 16 * 4), 44);
      expect(actual).toEqual(expected);
      const evidence = yield* extraction.evidence();
      expect(evidence).toMatchObject({
        master: witness,
        interval,
        startMs: 1,
        endMs: 3,
        microphoneChannel: 0,
        applicationChannel: 1,
        byteLength: expected.length,
      });
      expect(evidence.sha256).toBe(yield* Effect.promise(() => storedByteHash(expected)));
    }),
);

it.effect(
  "covers one and three hours without depending on upload parts or buffering the master",
  () =>
    Effect.gen(function* () {
      const zeros = new Uint8Array(asrReadRangeBytes);
      for (const durationMs of [3_600_000, 10_800_000]) {
        const witness = master(durationMs);
        let sequence = 100;
        const intervals = yield* planMasterSubmissions(witness, 900_000, () => id(sequence++));
        expect(intervals.length).toBe(durationMs / 900_000);
        let expectedOffset = 68;
        let totalPcmBytes = 0;
        let maximumRead = 0;
        for (const interval of intervals) {
          const source: AsrMasterSource = {
            read: (offset, length) =>
              Effect.sync(() => {
                maximumRead = Math.max(maximumRead, length);
                if (offset === 0) {
                  return makeAsrMasterHeader();
                }
                expect(offset).toBe(expectedOffset);
                expectedOffset += length;
                totalPcmBytes += length;
                return zeros.subarray(0, length);
              }),
          };
          const extraction = yield* extractMasterWave(source, witness, interval);
          let emitted = 0;
          yield* extraction.stream.pipe(
            Stream.runForEach((chunk) =>
              Effect.sync(() => {
                emitted += chunk.length;
              }),
            ),
          );
          expect((yield* extraction.evidence()).byteLength).toBe(emitted);
        }
        expect(maximumRead).toBeLessThanOrEqual(asrReadRangeBytes);
        expect(expectedOffset).toBe(witness.byteLength);
        expect(totalPcmBytes).toBe(witness.frameCount * 4);
        expect(intervals.at(-1)?.endFrame).toBe(witness.frameCount);
      }
    }),
);

it.effect("rejects corrupt headers, partial extraction, replay and master identity reuse", () =>
  Effect.gen(function* () {
    const witness = master(1000);
    const interval = { submissionId: id(6), index: 0, startFrame: 0, endFrame: 16_000 };
    const bad = {
      read: (_offset: number, length: number) => Effect.succeed(new Uint8Array(length)),
    };
    expect((yield* Effect.result(extractMasterWave(bad, witness, interval)))._tag).toBe("Failure");
    const source = {
      read: (offset: number, length: number) =>
        Effect.succeed(offset === 0 ? makeAsrMasterHeader() : new Uint8Array(length)),
    };
    const extraction = yield* extractMasterWave(source, witness, interval);
    yield* extraction.stream.pipe(Stream.take(1), Stream.runDrain);
    expect((yield* Effect.result(extraction.evidence()))._tag).toBe("Failure");
    expect((yield* extraction.stream.pipe(Stream.runDrain, Effect.result))._tag).toBe("Failure");
    expect(
      (yield* Effect.result(planMasterSubmissions(witness, 60_000, () => witness.masterId)))._tag,
    ).toBe("Failure");
  }),
);
