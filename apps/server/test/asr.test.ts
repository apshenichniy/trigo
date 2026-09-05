import { it, expect } from "@effect/vitest";
import { Effect } from "effect";
import { fakeAsr, UnknownLocalFixture } from "../src/asr.ts";

it.effect("accepts no speech without fabricating transcript text", () =>
  Effect.gen(function* () {
    expect(yield* fakeAsr.transcribe("no-speech")).toEqual({
      fixture: "no-speech",
      turns: [],
      provider: "fake",
    });
  }),
);

it.effect("reports an unknown local fixture as a typed failure", () =>
  Effect.gen(function* () {
    const error = yield* fakeAsr.transcribe("conversation").pipe(Effect.flip);
    expect(error).toBeInstanceOf(UnknownLocalFixture);
    expect(error.fixture).toBe("conversation");
  }),
);
