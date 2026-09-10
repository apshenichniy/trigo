import { Effect, Schema } from "effect";

import { AsrProbeLanguage } from "@trigo/contracts";

import { assemblyAIStereoProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { type AsrExtractionEvidence } from "./asr-master.ts";
import { transcriptionError } from "./transcription-errors.ts";

export const AssemblyAIJobId = Schema.NonEmptyString.check(
  Schema.isMaxLength(128),
  Schema.isPattern(/^[A-Za-z0-9_-]+$/),
);
export const AssemblyAIJob = Schema.Struct({
  id: AssemblyAIJobId,
  status: Schema.Literals(["queued", "processing", "completed", "error"]),
  audio_url: Schema.NonEmptyString,
  error: Schema.optionalKey(Schema.NullOr(Schema.String)),
  is_deleted: Schema.optionalKey(Schema.NullOr(Schema.Boolean)),
});
export interface AssemblyAIJob extends Schema.Schema.Type<typeof AssemblyAIJob> {}

const Word = Schema.Struct({
  text: Schema.String,
  start: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  end: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  confidence: Schema.NullOr(Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 1 }))),
  speaker: Schema.optionalKey(Schema.NullOr(Schema.String)),
  channel: Schema.Literals([1, 2, "1", "2"]),
});

const CompletedResponse = Schema.Struct({
  ...AssemblyAIJob.fields,
  status: Schema.Literal("completed"),
  audio_duration: Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0)),
  audio_channels: Schema.Literal(2),
  multichannel: Schema.Literal(true),
  speaker_labels: Schema.Literal(true),
  language_code: AsrProbeLanguage,
  language_detection: Schema.Literal(false),
  speech_model_used: Schema.Literal("universal-2"),
  punctuate: Schema.Literal(true),
  format_text: Schema.Literal(true),
  text: Schema.NullOr(Schema.String),
  words: Schema.NullOr(Schema.Array(Word)),
});

export const decodeAssemblyAIJSON = Effect.fn("AssemblyAI.decodeJSON")(function* (
  bytes: Uint8Array,
) {
  const text = yield* Effect.try({
    try: () => new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    catch: () => transcriptionError("asr_result_invalid"),
  });
  return yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(text).pipe(
    Effect.mapError(() => transcriptionError("asr_result_invalid")),
  );
});

/** The provider reports seconds, sometimes rounded. Exact source/byte coverage belongs to
 * the upload/extraction witness, not to word timestamps or this coarse duration check. */
export const inspectAssemblyAIResult = Effect.fn("AssemblyAI.inspectResult")(function* (
  bytes: Uint8Array,
  extraction: AsrExtractionEvidence,
  expected: { readonly providerId: string; readonly uploadURL: string; readonly language: string },
) {
  if (bytes.byteLength > assemblyAIStereoProfile.maxRawResponseBytes) {
    return yield* transcriptionError("asr_result_too_large");
  }
  const value = yield* decodeAssemblyAIJSON(bytes);
  const result = yield* Schema.decodeUnknownEffect(CompletedResponse)(value).pipe(
    Effect.mapError(() => transcriptionError("asr_result_invalid")),
  );
  if (
    result.id !== expected.providerId ||
    result.audio_url !== expected.uploadURL ||
    result.language_code !== expected.language ||
    result.is_deleted === true ||
    Math.abs(result.audio_duration * 1_000 - (extraction.endMs - extraction.startMs)) > 1_000 ||
    ((result.words?.length ?? 0) === 0 && (result.text ?? "").trim() !== "")
  ) {
    return yield* transcriptionError("asr_result_invalid");
  }
  return result;
});
