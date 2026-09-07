import { it, expect } from "@effect/vitest";
import { Effect } from "effect";

import { validateDocument } from "@trigo/contracts";

import { fakeAsr, type Asr } from "../src/asr.ts";
import { noSpeechInput } from "../src/local-fixture.ts";
import { Nova3NormalizationError } from "../src/nova-3.ts";

it.effect("returns a deterministic canonical no-speech revision through the shared adapter", () =>
  Effect.gen(function* () {
    const adapter: Asr = fakeAsr;
    const first = yield* adapter.normalize(noSpeechInput);
    expect(validateDocument("TranscriptRevision", first)).toEqual(first);
    expect(yield* adapter.normalize(noSpeechInput)).toEqual(first);
    expect(first).toMatchObject({
      callId: noSpeechInput.callId,
      revisionId: noSpeechInput.revisionId,
      audioManifest: noSpeechInput.audioManifest,
      turns: [],
      speakers: [],
      asr: { adapter: "fake", model: "no-speech", providerRequestIds: [] },
    });
  }),
);
it.effect("rejects missing or malformed immutable context instead of inventing identifiers", () =>
  Effect.gen(function* () {
    const error = yield* fakeAsr.normalize({ fixture: "live-model" }).pipe(Effect.flip);
    expect(error).toBeInstanceOf(Nova3NormalizationError);
  }),
);
