import { Schema } from "effect";
import { MediaProfile } from "./media-profile.ts";

export const AsrProbeLanguage = Schema.Literals(["en", "ru", "uk"]);
export type AsrProbeLanguage = typeof AsrProbeLanguage.Type;

const CanonicalUuidV4 = Schema.String.check(Schema.isUUID(4));
const NonNegativeInt = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));
const PositiveInt = Schema.Int.check(Schema.isGreaterThan(0));

export const AsrProbeErrorEnvelope = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  error: Schema.Struct({
    code: Schema.String.check(Schema.isPattern(/^[a-z][a-z0-9_]*$/)),
    retry: Schema.Literals(["never", "after_correction", "retryable"]),
    message: Schema.String,
    requestId: CanonicalUuidV4,
  }),
});
export interface AsrProbeErrorEnvelope extends Schema.Schema.Type<typeof AsrProbeErrorEnvelope> {}

const AsrProbeEvidence = {
  fixture: Schema.NonEmptyString,
  language: AsrProbeLanguage,
  profileId: MediaProfile.fields.id,
  byteLength: PositiveInt,
  durationMs: PositiveInt,
} as const;

export const AsrProbeUploadResponse = Schema.Struct({
  ...AsrProbeEvidence,
  inputKey: Schema.NonEmptyString,
});
export interface AsrProbeUploadResponse extends Schema.Schema.Type<typeof AsrProbeUploadResponse> {}

export const AsrProbeTranscriptionResponse = Schema.Struct({
  ...AsrProbeEvidence,
  providerLatencyMs: NonNegativeInt,
  channelCount: PositiveInt,
  speakerCount: NonNegativeInt,
  turnCount: NonNegativeInt,
  retainedKeys: Schema.Array(Schema.NonEmptyString),
});
export interface AsrProbeTranscriptionResponse extends Schema.Schema.Type<
  typeof AsrProbeTranscriptionResponse
> {}
