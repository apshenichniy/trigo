import { Effect, Schema } from "effect";

export const LocalTranscript = Schema.Struct({
  fixture: Schema.String,
  turns: Schema.Tuple([]),
  provider: Schema.Literal("fake"),
});

export interface LocalTranscript extends Schema.Schema.Type<typeof LocalTranscript> {}

export class UnknownLocalFixture extends Schema.TaggedError<UnknownLocalFixture>()(
  "Asr.UnknownLocalFixture",
  { fixture: Schema.String },
) {}

export interface Asr {
  readonly transcribe: (fixture: string) => Effect.Effect<LocalTranscript, UnknownLocalFixture>;
}

const noSpeechTranscript = LocalTranscript.make({
  fixture: "no-speech",
  turns: [],
  provider: "fake",
});

/** Local-only injection; the real Cloudflare Nova-3 adapter belongs to #13. */
export const fakeAsr: Asr = {
  transcribe: Effect.fn("Asr.transcribe")(function* (fixture: string) {
    if (fixture !== "no-speech") return yield* new UnknownLocalFixture({ fixture });
    return noSpeechTranscript;
  }),
};
