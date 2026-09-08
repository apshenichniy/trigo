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
} as const;
