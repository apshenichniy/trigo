import { Schema } from "effect";

import { ExchangeUUID, SHA256, UTCDateTime } from "./document-schema.ts";

/** Playback transport is independent from upload parts and ASR submission intervals. */
export const playbackSegmentFrames = 480_000;
export const playbackSegmentMaximumBytes = 44 + playbackSegmentFrames * 4;
export const playbackGrantLifetimeMs = 90_000;

export const RequestPlayback = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
}).annotate({ identifier: "RequestPlayback" });
export interface RequestPlayback extends Schema.Schema.Type<typeof RequestPlayback> {}

export const PlaybackChannel = Schema.Struct({
  channelIndex: Schema.Literals([0, 1]),
  trackId: ExchangeUUID,
  role: Schema.Literals(["microphone", "application"]),
}).annotate({ identifier: "PlaybackChannel" });

export const PlaybackManifest = Schema.Struct({
  masterId: ExchangeUUID,
  masterSHA256: SHA256,
  profileId: Schema.Literal("wav-pcm-s16le-16000-stereo-segment-v1"),
  sampleRateHz: Schema.Literal(16_000),
  frameCount: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 172_800_000 })),
  segmentFrames: Schema.Literal(playbackSegmentFrames),
  segmentCount: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 360 })),
  channels: Schema.Array(PlaybackChannel).check(Schema.isMinLength(2), Schema.isMaxLength(2)),
}).annotate({ identifier: "PlaybackManifest" });
export interface PlaybackManifest extends Schema.Schema.Type<typeof PlaybackManifest> {}

/** The temporary capability is sent in an Authorization header, never an owner-token URL. */
export const PlaybackGrant = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
  grantId: ExchangeUUID,
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  expiresAt: UTCDateTime,
  token: Schema.String.check(Schema.isPattern(/^trigo_playback_v1_[0-9a-f]{64}$/)),
  media: PlaybackManifest,
}).annotate({ identifier: "PlaybackGrant" });
export interface PlaybackGrant extends Schema.Schema.Type<typeof PlaybackGrant> {}

export const playbackSchemas = { RequestPlayback, PlaybackManifest, PlaybackGrant };
