import { Schema } from "effect";
import source from "../schema/media-profile.v1.json";

export const MediaSourceRole = Schema.Literals(["microphone", "application"]);
export type MediaSourceRole = typeof MediaSourceRole.Type;

const Channel = Schema.Struct({
  index: Schema.Int,
  role: MediaSourceRole,
});

export const MediaProfile = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  id: Schema.String,
  container: Schema.Literal("wave"),
  contentType: Schema.Literal("audio/wav"),
  codec: Schema.Literal("pcm_s16le"),
  sampleRateHz: Schema.Int,
  bitsPerSample: Schema.Int,
  interleaved: Schema.Boolean,
  objectDurationMs: Schema.Int,
  checkpointDurationMs: Schema.Int,
  waveHeaderBytes: Schema.Int,
  maxObjectBytes: Schema.Int,
  maxCallDurationMs: Schema.Int,
  maxObjectsPerCall: Schema.Int,
  limits: Schema.Struct({
    uploadRequestBytes: Schema.Int,
    batchEnvelopeBytes: Schema.Int,
    base64ObjectBytes: Schema.Int,
  }),
  channels: Schema.Array(Channel),
  assembly: Schema.Struct({
    ordering: Schema.Literal("object-index"),
    timeline: Schema.Literal("manifest-start-end-ms"),
    missingFrames: Schema.Literal("silence"),
    playback: Schema.Literal("decode-ordered-wave-objects-and-mix-at-output"),
  }),
  asr: Schema.Struct({
    model: Schema.Literal("@cf/deepgram/nova-3"),
    requestContentType: Schema.Literal("audio/wav"),
    encoding: Schema.Null,
    channels: Schema.Int,
    multichannel: Schema.Boolean,
    diarize: Schema.Boolean,
    submission: Schema.Literal("one-object-per-request"),
    timestampOrigin: Schema.Literal("object"),
    speakerScope: Schema.Literal("object-channel"),
  }),
});

export interface MediaProfile extends Schema.Schema.Type<typeof MediaProfile> {}

/** The selected #13 profile is a checked repository artifact, not runtime configuration. */
export const selectedMediaProfile = Schema.decodeUnknownSync(MediaProfile)(source);

export function waveByteLength(frameCount: number): number {
  return (
    selectedMediaProfile.waveHeaderBytes +
    frameCount * selectedMediaProfile.channels.length * (selectedMediaProfile.bitsPerSample / 8)
  );
}

export function frameCountForDuration(durationMs: number): number {
  return Math.ceil((durationMs * selectedMediaProfile.sampleRateHz) / 1000);
}

export function objectCountForDuration(durationMs: number): number {
  return Math.ceil(durationMs / selectedMediaProfile.objectDurationMs);
}

export interface WaveObjectInspection {
  readonly frameCount: number;
  readonly durationMs: number;
  readonly byteLength: number;
}

function fourCC(bytes: Uint8Array, offset: number): string {
  return new TextDecoder("ascii").decode(bytes.subarray(offset, offset + 4));
}

export function inspectWaveObject(bytes: Uint8Array): WaveObjectInspection {
  if (bytes.byteLength < selectedMediaProfile.waveHeaderBytes)
    throw new Error("media_profile: truncated WAVE header");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (
    fourCC(bytes, 0) !== "RIFF" ||
    fourCC(bytes, 8) !== "WAVE" ||
    fourCC(bytes, 12) !== "fmt " ||
    fourCC(bytes, 36) !== "data"
  )
    throw new Error("media_profile: expected canonical RIFF/WAVE chunks");

  const channels = selectedMediaProfile.channels.length;
  const bytesPerSample = selectedMediaProfile.bitsPerSample / 8;
  const blockAlign = channels * bytesPerSample;
  const expectedByteRate = selectedMediaProfile.sampleRateHz * blockAlign;
  const dataBytes = view.getUint32(40, true);
  if (
    view.getUint32(4, true) !== bytes.byteLength - 8 ||
    view.getUint32(16, true) !== 16 ||
    view.getUint16(20, true) !== 1 ||
    view.getUint16(22, true) !== channels ||
    view.getUint32(24, true) !== selectedMediaProfile.sampleRateHz ||
    view.getUint32(28, true) !== expectedByteRate ||
    view.getUint16(32, true) !== blockAlign ||
    view.getUint16(34, true) !== selectedMediaProfile.bitsPerSample ||
    dataBytes !== bytes.byteLength - selectedMediaProfile.waveHeaderBytes ||
    dataBytes % blockAlign !== 0 ||
    bytes.byteLength > selectedMediaProfile.maxObjectBytes
  )
    throw new Error("media_profile: WAVE object does not match the selected profile");

  const frameCount = dataBytes / blockAlign;
  return {
    frameCount,
    durationMs: Math.round((frameCount * 1000) / selectedMediaProfile.sampleRateHz),
    byteLength: bytes.byteLength,
  };
}

function writeFourCC(bytes: Uint8Array, offset: number, value: string): void {
  bytes.set(new TextEncoder().encode(value), offset);
}

export function makeWaveHeader(frameCount: number): Uint8Array {
  if (!Number.isSafeInteger(frameCount) || frameCount < 0)
    throw new Error("media_profile: frame count must be a nonnegative safe integer");
  const byteLength = waveByteLength(frameCount);
  if (byteLength > selectedMediaProfile.maxObjectBytes)
    throw new Error("media_profile: WAVE object exceeds the selected object duration");

  const channels = selectedMediaProfile.channels.length;
  const bytesPerSample = selectedMediaProfile.bitsPerSample / 8;
  const blockAlign = channels * bytesPerSample;
  const bytes = new Uint8Array(selectedMediaProfile.waveHeaderBytes);
  const view = new DataView(bytes.buffer);
  writeFourCC(bytes, 0, "RIFF");
  view.setUint32(4, byteLength - 8, true);
  writeFourCC(bytes, 8, "WAVE");
  writeFourCC(bytes, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, selectedMediaProfile.sampleRateHz, true);
  view.setUint32(28, selectedMediaProfile.sampleRateHz * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, selectedMediaProfile.bitsPerSample, true);
  writeFourCC(bytes, 36, "data");
  view.setUint32(40, frameCount * blockAlign, true);
  return bytes;
}
