import { Effect } from "effect";
export interface LocalTranscript {
  fixture: string;
  turns: readonly [];
  provider: "fake";
}
export interface Asr {
  transcribe(fixture: string): Effect.Effect<LocalTranscript, Error>;
}
/** Local-only injection; the real Cloudflare Nova-3 adapter belongs to #13. */
export const fakeAsr: Asr = {
  transcribe: (fixture) =>
    fixture === "no-speech"
      ? Effect.succeed({ fixture, turns: [], provider: "fake" })
      : Effect.fail(new Error("Unknown local fixture")),
};
