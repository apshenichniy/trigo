import { expect, it } from "@effect/vitest";
import { env } from "cloudflare:workers";
import { Effect, Stream } from "effect";

import {
  AsrMaster,
  extractMasterWave,
  makeAsrMasterHeader,
  r2MasterSource,
} from "../src/asr-master.ts";

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

it.effect(
  "reads a private master through bounded R2 ranges and rejects a version change between ranges",
  () =>
    Effect.gen(function* () {
      const master = AsrMaster.make({
        callId: id(1),
        masterId: id(2),
        manifestId: id(3),
        manifestSha256: "a".repeat(64),
        sha256: "b".repeat(64),
        frameCount: 16_000,
        byteLength: 64_068,
        mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
        microphoneTrackId: id(4),
        applicationTrackId: id(5),
      });
      const key = "asr-master-range-proof.caf";
      const caf = new Uint8Array(master.byteLength);
      caf.set(makeAsrMasterHeader());
      yield* Effect.promise(() => env.LOCAL_ARCHIVE.put(key, caf));
      const source = r2MasterSource(env.LOCAL_ARCHIVE, key, master);
      const interval = { submissionId: id(6), index: 0, startFrame: 0, endFrame: 16_000 };
      const extraction = yield* extractMasterWave(source, master, interval);
      yield* Stream.runDrain(extraction.stream);
      expect((yield* extraction.evidence()).byteLength).toBe(64_044);

      const changed = new Uint8Array(caf);
      changed[100] = 1;
      yield* Effect.promise(() => env.LOCAL_ARCHIVE.put(key, changed));
      expect((yield* Effect.result(source.read(68, 100)))._tag).toBe("Failure");
    }),
);
