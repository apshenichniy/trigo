import { it, expect } from "@effect/vitest";
import { Effect } from "effect";
import { fakeAsr } from "../src/asr.ts";
it.effect("accepts no speech without fabricating transcript text", () =>
  Effect.gen(function* () {
    expect(yield* fakeAsr.transcribe("no-speech")).toEqual({
      fixture: "no-speech",
      turns: [],
      provider: "fake",
    });
  }),
);
