import { Schema } from "effect";
import { MediaProfile } from "./media-profile.ts";

export const AsrProbeLanguage = Schema.Literals(["en", "ru", "uk"]);
export type AsrProbeLanguage = typeof AsrProbeLanguage.Type;

const NonNegativeInt = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));
const PositiveInt = Schema.Int.check(Schema.isGreaterThan(0));

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
}).check(
  Schema.makeFilter(
    (evidence) =>
      evidence.fixture === `two-source-${evidence.language}` &&
      evidence.inputKey === `acceptance/issue-13/${evidence.fixture}/input.wav`,
    { expected: "the canonical ASR upload evidence path" },
  ),
);
export interface AsrProbeUploadResponse extends Schema.Schema.Type<typeof AsrProbeUploadResponse> {}

export const AsrProbeTranscriptionResponse = Schema.Struct({
  ...AsrProbeEvidence,
  providerLatencyMs: NonNegativeInt,
  channelCount: Schema.Literal(2),
  speakerCount: NonNegativeInt,
  turnCount: NonNegativeInt,
  retained: Schema.Struct({
    inputKey: Schema.NonEmptyString,
    manifestKey: Schema.NonEmptyString,
    rawProviderKey: Schema.NonEmptyString,
    normalizedRevisionKey: Schema.NonEmptyString,
  }),
}).check(
  Schema.makeFilter(
    (evidence) => {
      const root = `acceptance/issue-13/${evidence.fixture}`;
      const languageRoot = `${root}/${evidence.language}`;
      return (
        evidence.fixture === `two-source-${evidence.language}` &&
        evidence.retained.inputKey === `${root}/input.wav` &&
        evidence.retained.manifestKey === `${languageRoot}/audio-manifest.json` &&
        evidence.retained.rawProviderKey === `${languageRoot}/provider-result.json` &&
        evidence.retained.normalizedRevisionKey === `${languageRoot}/normalized-revision.json`
      );
    },
    { expected: "the complete canonical ASR evidence artifact set" },
  ),
);
export interface AsrProbeTranscriptionResponse extends Schema.Schema.Type<
  typeof AsrProbeTranscriptionResponse
> {}
