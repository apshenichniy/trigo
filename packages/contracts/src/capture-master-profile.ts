import { Schema } from "effect";
import source from "../schema/capture-master-profile.v1.json";

/** Permanent media, durable checkpoints, transport ranges and extracted inputs have independent bounds. */
export const CaptureMasterProfile = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  id: Schema.Literal("caf-lpcm-s16le-16000-stereo-v1"),
  container: Schema.Literal("caf"),
  contentType: Schema.Literal("audio/x-caf"),
  codec: Schema.Literal("pcm_s16le"),
  sampleRateHz: Schema.Literal(16_000),
  bitsPerSample: Schema.Literal(16),
  interleaved: Schema.Literal(true),
  microphoneChannel: Schema.Literal(0),
  applicationChannel: Schema.Literal(1),
  headerBytes: Schema.Literal(68),
  headerPolicy: Schema.Literal("immutable-indefinite-final-data-chunk"),
  maxCallDurationMs: Schema.Literal(10_800_000),
  maxMasterBytes: Schema.Literal(691_200_068),
  maxCommitDurationMs: Schema.Literal(1_000),
  maxUncommittedTailMs: Schema.Literal(2_000),
  indexHeaderBytes: Schema.Literal(128),
  indexRecordBytes: Schema.Literal(2_120),
  maxRangeBytes: Schema.Literal(8_388_608),
  minimumMultipartPartBytes: Schema.Literal(5_242_880),
  timeline: Schema.Literal("call-relative-integer-milliseconds"),
  nonRecordedSamples: Schema.Literal("whole-millisecond-silence-before-persistence"),
  extractionTransform: Schema.Literal("identity-stereo-pcm-frame-slice-v1"),
  cleanupAuthority: Schema.Literal("durably-committed-complete-verified-server-receipt"),
}).annotate({ identifier: "CaptureMasterProfile" });
export interface CaptureMasterProfile extends Schema.Schema.Type<typeof CaptureMasterProfile> {}
export const selectedCaptureMasterProfile = Schema.decodeUnknownSync(CaptureMasterProfile)(source);
