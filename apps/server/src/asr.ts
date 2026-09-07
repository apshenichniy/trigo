import { DateTime, Effect, Schema } from "effect";

import { selectedMediaProfile, TranscriptRevision } from "@trigo/contracts";

import { Nova3NormalizationInput, normalizeNova3, Nova3NormalizationError } from "./nova-3.ts";

/** Canonical adapter result boundary shared by the dev probe and offline composition. */
export interface Asr {
  readonly normalize: (
    input: unknown,
  ) => Effect.Effect<TranscriptRevision, Nova3NormalizationError>;
}
export const nova3Asr: Asr = { normalize: normalizeNova3 };

/** Deterministic no-speech adapter. It never invokes a provider or claims ASR readiness. */
export const fakeAsr: Asr = {
  normalize: Effect.fn("Asr.fake.normalize")(function* (input: unknown) {
    const context = yield* Schema.decodeUnknownEffect(Nova3NormalizationInput)(input).pipe(
      Effect.mapError(
        () =>
          new Nova3NormalizationError({
            operation: "Asr.fake.normalize",
            message: "Invalid fixture context",
          }),
      ),
    );
    return TranscriptRevision.make({
      schemaVersion: 1,
      callId: context.callId,
      revisionId: context.revisionId,
      createdAt: DateTime.formatIso(context.createdAt),
      audioManifest: context.audioManifest,
      normalizationVersion: 1,
      asr: {
        adapter: "fake",
        model: "no-speech",
        profileId: selectedMediaProfile.id,
        requestedLanguage: context.requestedLanguage,
        detectedLanguages: [],
        effectiveOptions: { fixture: "no-speech" },
        returnedModelVersion: null,
        providerRequestIds: [],
      },
      speakers: [],
      turns: [],
    });
  }),
};
