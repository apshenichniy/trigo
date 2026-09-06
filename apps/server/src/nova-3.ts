import { selectedMediaProfile, type TranscriptRevision, validateDocument } from "@trigo/contracts";
import { Effect, Schema } from "effect";

const Seconds = Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0));
const Confidence = Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 1 }));
const ProviderSpeaker = Schema.Union([Schema.String, Schema.Finite]);

const Nova3Word = Schema.Struct({
  word: Schema.String,
  punctuated_word: Schema.optionalKey(Schema.String),
  start: Seconds,
  end: Seconds,
  confidence: Schema.optionalKey(Confidence),
  speaker: Schema.optionalKey(ProviderSpeaker),
});

const Nova3Alternative = Schema.Struct({
  transcript: Schema.optionalKey(Schema.String),
  words: Schema.optionalKey(Schema.Array(Nova3Word)),
});

const Nova3Response = Schema.Struct({
  results: Schema.optionalKey(
    Schema.Struct({
      channels: Schema.optionalKey(
        Schema.Array(
          Schema.Struct({
            alternatives: Schema.optionalKey(Schema.Array(Nova3Alternative)),
          }),
        ),
      ),
    }),
  ),
});

type DecodedResponse = typeof Nova3Response.Type;
type DecodedWord = typeof Nova3Word.Type;

export interface Nova3ObjectResult {
  readonly objectId: string;
  readonly index: number;
  readonly startMs: number;
  readonly endMs: number;
  readonly channelMap: ReadonlyArray<{
    readonly channelIndex: number;
    readonly trackId: string;
  }>;
  readonly providerRequestId: string | null;
  readonly response: unknown;
}

export interface Nova3NormalizationInput {
  readonly callId: string;
  readonly revisionId: string;
  readonly createdAt: string;
  readonly audioManifest: TranscriptRevision["audioManifest"];
  readonly requestedLanguage: string;
  readonly detectedLanguages: ReadonlyArray<string>;
  readonly objects: ReadonlyArray<Nova3ObjectResult>;
  readonly makeId: () => string;
}

export class Nova3NormalizationError extends Schema.TaggedError<Nova3NormalizationError>()(
  "Nova3.NormalizationError",
  {
    operation: Schema.String,
    message: Schema.String,
  },
) {}
const isNova3NormalizationError = Schema.is(Nova3NormalizationError);

function failure(operation: string, message: string): Nova3NormalizationError {
  return new Nova3NormalizationError({ operation, message });
}

function labelFor(word: DecodedWord): string | null {
  return word.speaker === undefined ? null : String(word.speaker);
}

function textFor(word: DecodedWord): string {
  return word.punctuated_word ?? word.word;
}

export const normalizeNova3 = Effect.fn("Nova3.normalize")(function* (
  input: Nova3NormalizationInput,
): Effect.fn.Return<TranscriptRevision, Nova3NormalizationError> {
  const decoded = yield* Effect.forEach(input.objects, (object) =>
    Schema.decodeUnknownEffect(Nova3Response)(object.response).pipe(
      Effect.mapError(() =>
        failure("Nova3.decodeResponse", `Object ${object.index} has an invalid provider response`),
      ),
    ),
  );

  return yield* Effect.try({
    try: () => buildRevision(input, decoded),
    catch: (cause) =>
      isNova3NormalizationError(cause)
        ? cause
        : failure(
            "Nova3.normalize",
            cause instanceof Error ? cause.message : "Provider result could not be normalized",
          ),
  });
});

function buildRevision(
  input: Nova3NormalizationInput,
  responses: ReadonlyArray<DecodedResponse>,
): TranscriptRevision {
  if (input.objects.length !== responses.length)
    throw failure("Nova3.normalize", "Every media object must have one provider result");

  const speakers: TranscriptRevision["speakers"] = [];
  const turns: TranscriptRevision["turns"] = [];
  const speakerIds = new Map<string, string>();
  const scopeIds = new Map<string, string>();
  let previousObjectEndMs = 0;

  for (const [position, object] of input.objects.entries()) {
    const response = responses[position];
    if (response === undefined) throw failure("Nova3.normalize", "Provider result is missing");
    if (
      object.index !== position ||
      object.startMs !== previousObjectEndMs ||
      object.endMs <= object.startMs
    )
      throw failure("Nova3.normalize", `Object ${object.index} breaks the media timeline`);
    previousObjectEndMs = object.endMs;

    const channels = response.results?.channels;
    if (channels === undefined || channels.length !== selectedMediaProfile.channels.length)
      throw failure(
        "Nova3.normalize",
        `Object ${object.index} must return ${selectedMediaProfile.channels.length} channels`,
      );
    if (object.channelMap.length !== selectedMediaProfile.channels.length)
      throw failure("Nova3.normalize", `Object ${object.index} has an invalid channel map`);

    for (const expectedChannel of selectedMediaProfile.channels) {
      const channelMapping = object.channelMap.find(
        (mapping) => mapping.channelIndex === expectedChannel.index,
      );
      const channel = channels[expectedChannel.index];
      const alternative = channel?.alternatives?.[0];
      if (channelMapping === undefined || alternative === undefined)
        throw failure(
          "Nova3.normalize",
          `Object ${object.index} is missing channel ${expectedChannel.index}`,
        );

      const words = alternative.words ?? [];
      if (words.length === 0) {
        if ((alternative.transcript ?? "").trim() !== "")
          throw failure(
            "Nova3.normalize",
            `Object ${object.index} channel ${expectedChannel.index} has text without word timing`,
          );
        continue;
      }

      const firstProviderWord = words[0];
      if (firstProviderWord === undefined)
        throw failure("Nova3.normalize", "Provider word list changed during normalization");
      let currentWords: TranscriptRevision["turns"][number]["words"] = [];
      let currentLabel = labelFor(firstProviderWord);
      let previousWordEndMs = object.startMs;

      const finishTurn = () => {
        const firstWord = currentWords[0];
        const lastWord = currentWords[currentWords.length - 1];
        if (firstWord === undefined || lastWord === undefined) return;
        const scopeKey = `${object.objectId}:${expectedChannel.index}`;
        const speakerKey = `${scopeKey}:${currentLabel ?? "unknown"}`;
        let speakerId: string | null = null;
        if (currentLabel !== null) {
          let scopeId = scopeIds.get(scopeKey);
          if (scopeId === undefined) {
            scopeId = input.makeId();
            scopeIds.set(scopeKey, scopeId);
          }
          speakerId = speakerIds.get(speakerKey) ?? null;
          if (speakerId === null) {
            speakerId = input.makeId();
            speakerIds.set(speakerKey, speakerId);
            speakers.push({
              speakerId,
              trackId: channelMapping.trackId,
              diarizationScopeId: scopeId,
              providerLabel: currentLabel,
            });
          }
        }
        turns.push({
          turnId: input.makeId(),
          trackId: channelMapping.trackId,
          speakerId,
          startMs: firstWord.startMs,
          endMs: lastWord.endMs,
          text: currentWords.map((word) => word.text).join(" "),
          words: currentWords,
        });
        currentWords = [];
      };

      for (const word of words) {
        const startMs = object.startMs + Math.round(word.start * 1000);
        const endMs = object.startMs + Math.round(word.end * 1000);
        if (
          endMs < startMs ||
          startMs < previousWordEndMs ||
          startMs < object.startMs ||
          endMs > object.endMs
        )
          throw failure(
            "Nova3.normalize",
            `Object ${object.index} channel ${expectedChannel.index} has invalid word timing`,
          );
        const label = labelFor(word);
        if (label !== currentLabel) {
          finishTurn();
          currentLabel = label;
        }
        currentWords.push({
          text: textFor(word),
          startMs,
          endMs,
          confidence: word.confidence ?? null,
        });
        previousWordEndMs = endMs;
      }
      finishTurn();
    }
  }

  turns.sort(
    (left, right) =>
      left.startMs - right.startMs ||
      left.endMs - right.endMs ||
      left.trackId.localeCompare(right.trackId),
  );

  const revision = {
    schemaVersion: 1,
    callId: input.callId,
    revisionId: input.revisionId,
    createdAt: input.createdAt,
    audioManifest: input.audioManifest,
    normalizationVersion: 1,
    asr: {
      adapter: "cloudflare-workers-ai",
      model: selectedMediaProfile.asr.model,
      profileId: selectedMediaProfile.id,
      requestedLanguage: input.requestedLanguage,
      detectedLanguages: [...input.detectedLanguages],
      effectiveOptions: {
        channels: selectedMediaProfile.asr.channels,
        diarize: selectedMediaProfile.asr.diarize,
        multichannel: selectedMediaProfile.asr.multichannel,
        punctuate: true,
        smart_format: true,
      },
      returnedModelVersion: null,
      providerRequestIds: input.objects.flatMap((object) =>
        object.providerRequestId === null ? [] : [object.providerRequestId],
      ),
    },
    speakers,
    turns,
  };
  return validateDocument("TranscriptRevision", revision);
}
