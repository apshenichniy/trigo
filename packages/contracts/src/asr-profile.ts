import { Schema } from "effect";

/** Identifies the adapter/transform contract; evidence records each actual interval separately. */
export const Nova3StreamProfileId = Schema.Literal("nova3-wav-s16le-16000-stereo-stream-v1");

export const nova3StreamProfile = {
  id: Nova3StreamProfileId.make("nova3-wav-s16le-16000-stereo-stream-v1"),
  model: "@cf/deepgram/nova-3",
  transport: "workers-ai-binding-stream",
  contentType: "audio/wav",
  sourceProfileId: "caf-lpcm-s16le-16000-stereo-v1",
  transform: "caf-lpcm-to-wave-pcm-frame-slice-v1",
  sampleRateHz: 16_000,
  channels: 2,
  microphoneChannel: 0,
  applicationChannel: 1,
  multichannel: true,
  diarize: true,
  punctuate: true,
  smart_format: true,
  speakerScope: "submission-channel",
  /** Hosted on 2026-09-08: a 2h interval succeeds; a single 3h input is not complete. */
  maxSubmissionDurationMs: 7_200_000,
  maxSubmissionByteLength: 460_800_044,
  verifiedLanguages: ["en", "ru"],
  /** Local retention bound, not a claimed provider limit; incomplete prefixes never normalize. */
  maxRawResponseBytes: 8_000_000,
} as const;

export const AssemblyAIStereoProfileId = Schema.Literal("assemblyai-u2-wav-s16le-16000-stereo-v1");
export const TranscriptionProfileId = Schema.Union([
  Nova3StreamProfileId,
  AssemblyAIStereoProfileId,
]);

/** Direct asynchronous API profile selected in #92. The interval cap is an application
 * bound; local tests and earlier short-call experiments are not a hosted long-call proof. */
export const assemblyAIStereoProfile = {
  id: AssemblyAIStereoProfileId.make("assemblyai-u2-wav-s16le-16000-stereo-v1"),
  model: "universal-2",
  apiBase: "https://api.eu.assemblyai.com/v2",
  transport: "assemblyai-upload-and-poll-v1",
  sampleRateHz: 16_000,
  channels: 2,
  microphoneChannel: 0,
  applicationChannel: 1,
  speakerScope: "submission-channel",
  maxSubmissionDurationMs: 7_200_000,
  maxSubmissionByteLength: 460_800_044,
  maxRawResponseBytes: 8_000_000,
  requestedLanguages: ["en", "ru", "uk"],
} as const;
