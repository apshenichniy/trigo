import { Schema } from "effect";

import { Nova3StreamProfileId } from "./asr-profile.ts";
import { CaptureMasterProfile } from "./capture-master-profile.ts";
import { MediaProfile, MediaSourceRole } from "./media-profile.ts";

/** Exchange identities deliberately accept versions other than UUID v4. */
export const ExchangeUUID = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
).annotate({ identifier: "ExchangeUUID" });
export const CanonicalUUIDv4 = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
).annotate({ identifier: "CanonicalUUIDv4" });
export const SHA256 = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)).annotate({
  identifier: "SHA256Digest",
});
export const NonNegativeInteger = Schema.Int.check(
  Schema.isBetween({ minimum: 0, maximum: Number.MAX_SAFE_INTEGER }),
).annotate({ identifier: "NonNegativeInteger" });
export const PositiveInteger = Schema.Int.check(
  Schema.isBetween({ minimum: 1, maximum: Number.MAX_SAFE_INTEGER }),
).annotate({ identifier: "PositiveInteger" });

/** Preserve the wire string, including precision and leap seconds, without Date normalization. */
export const UTCDateTime = Schema.String.check(
  Schema.isPattern(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$/),
  Schema.makeFilter(
    (value) => {
      const parts = value.split(/\D/).map(Number);
      const [year = -1, month = 0, day = 0, hour = 24, minute = 60, second = 61] = parts;
      const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
      const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
      return (
        month >= 1 &&
        month <= 12 &&
        day >= 1 &&
        day <= (days[month - 1] ?? 0) &&
        hour < 24 &&
        minute < 60 &&
        (second < 60 || (hour === 23 && minute === 59 && second === 60))
      );
    },
    { expected: "a valid UTC calendar timestamp", toJsonSchema: () => ({ format: "date-time" }) },
  ),
).annotate({ identifier: "UTCDateTime" });

export const CaptureSourceDocument = Schema.Struct({
  applicationName: Schema.String,
  bundleId: Schema.String,
  processId: NonNegativeInteger,
  windowId: Schema.NullOr(NonNegativeInteger),
  windowTitle: Schema.NullOr(Schema.String),
}).annotate({ identifier: "CaptureSourceDocument" });
export interface CaptureSourceDocument extends Schema.Schema.Type<typeof CaptureSourceDocument> {}
export const InputDevice = Schema.Struct({ id: Schema.String, name: Schema.String }).annotate({
  identifier: "InputDevice",
});
export interface InputDevice extends Schema.Schema.Type<typeof InputDevice> {}
export const TrackInterval = Schema.Struct({
  startMs: NonNegativeInteger,
  endMs: NonNegativeInteger,
  state: Schema.Literals(["recorded", "muted", "unavailable"]),
  reason: Schema.NullOr(Schema.String),
}).annotate({ identifier: "TrackInterval" });
export interface TrackInterval extends Schema.Schema.Type<typeof TrackInterval> {}
export const AudioTrack = Schema.Struct({
  trackId: ExchangeUUID,
  role: MediaSourceRole,
  inputDevice: Schema.NullOr(InputDevice),
  mediaProfileId: Schema.Literals([
    MediaProfile.fields.id.literal,
    CaptureMasterProfile.fields.id.literal,
  ]),
  intervals: Schema.Array(TrackInterval),
}).annotate({ identifier: "AudioTrack" });
export interface AudioTrack extends Schema.Schema.Type<typeof AudioTrack> {}
export const AudioManifestReference = Schema.Struct({
  manifestId: ExchangeUUID,
  sha256: SHA256,
}).annotate({ identifier: "AudioManifestReference" });
export interface AudioManifestReference extends Schema.Schema.Type<typeof AudioManifestReference> {}
export const RevisionReference = Schema.Struct({
  revisionId: ExchangeUUID,
  createdAt: UTCDateTime,
  sha256: SHA256,
}).annotate({ identifier: "RevisionReference" });
export interface RevisionReference extends Schema.Schema.Type<typeof RevisionReference> {}
const SpeakerNames = Schema.Record(
  Schema.String,
  Schema.Record(Schema.String, Schema.String).check(Schema.isPropertyNames(ExchangeUUID)),
).check(Schema.isPropertyNames(ExchangeUUID));
export const LegacyCallDocument = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  documentVersion: PositiveInteger,
  startedAt: UTCDateTime,
  endedAt: Schema.NullOr(UTCDateTime),
  durationMs: Schema.NullOr(NonNegativeInteger),
  captureState: Schema.Literals(["recording", "stopped", "interrupted"]),
  interruptionReason: Schema.NullOr(Schema.String),
  source: CaptureSourceDocument,
  tracks: Schema.Array(AudioTrack).check(Schema.isMinLength(2), Schema.isMaxLength(2)),
  audioManifest: Schema.NullOr(AudioManifestReference),
  revisions: Schema.Array(RevisionReference),
  activeRevisionId: Schema.NullOr(ExchangeUUID),
  speakerNames: SpeakerNames,
}).annotate({ identifier: "LegacyCallDocument" });
export interface LegacyCallDocument extends Schema.Schema.Type<typeof LegacyCallDocument> {}

export const SpeakerGroup = Schema.Struct({
  groupId: ExchangeUUID,
  displayName: Schema.String.check(Schema.isPattern(/\S/)),
  speakerIds: Schema.Array(ExchangeUUID).check(Schema.isMinLength(2)),
}).annotate({ identifier: "SpeakerGroup" });
export interface SpeakerGroup extends Schema.Schema.Type<typeof SpeakerGroup> {}

/** A new closed shape; legacy input has a deliberate read path rather than optional fields. */
export const CallDocument = Schema.Struct({
  ...LegacyCallDocument.fields,
  schemaVersion: Schema.Literal(2),
  speakerGroups: Schema.Record(Schema.String, Schema.Array(SpeakerGroup)).check(
    Schema.isPropertyNames(ExchangeUUID),
  ),
}).annotate({ identifier: "CallDocument" });
export interface CallDocument extends Schema.Schema.Type<typeof CallDocument> {}

/** Provider options are intentionally a dictionary of JSON scalars, never nested arbitrary JSON. */
export const ProviderOption = Schema.Union([
  Schema.String,
  Schema.Finite,
  Schema.Boolean,
  Schema.Null,
]).annotate({ identifier: "ProviderOption" });
export const ASRMetadata = Schema.Struct({
  adapter: Schema.String,
  model: Schema.String,
  profileId: Schema.Union([MediaProfile.fields.id, Nova3StreamProfileId]),
  requestedLanguage: Schema.String,
  detectedLanguages: Schema.Array(Schema.String),
  effectiveOptions: Schema.Record(Schema.String, ProviderOption),
  returnedModelVersion: Schema.NullOr(Schema.String),
  providerRequestIds: Schema.Array(Schema.String),
}).annotate({ identifier: "ASRMetadata" });
export interface ASRMetadata extends Schema.Schema.Type<typeof ASRMetadata> {}
export const Speaker = Schema.Struct({
  speakerId: ExchangeUUID,
  trackId: ExchangeUUID,
  diarizationScopeId: ExchangeUUID,
  providerLabel: Schema.NullOr(Schema.String),
}).annotate({ identifier: "Speaker" });
export interface Speaker extends Schema.Schema.Type<typeof Speaker> {}
export const Word = Schema.Struct({
  text: Schema.String,
  startMs: NonNegativeInteger,
  endMs: NonNegativeInteger,
  confidence: Schema.NullOr(Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 1 }))),
  timingUncertain: Schema.optionalKey(Schema.Literal(true)),
}).annotate({ identifier: "Word" });
export interface Word extends Schema.Schema.Type<typeof Word> {}
export const Turn = Schema.Struct({
  turnId: ExchangeUUID,
  trackId: ExchangeUUID,
  speakerId: Schema.NullOr(ExchangeUUID),
  startMs: NonNegativeInteger,
  endMs: NonNegativeInteger,
  text: Schema.String,
  words: Schema.Array(Word),
}).annotate({ identifier: "Turn" });
export interface Turn extends Schema.Schema.Type<typeof Turn> {}
export const TranscriptRevision = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  callId: ExchangeUUID,
  revisionId: ExchangeUUID,
  createdAt: UTCDateTime,
  audioManifest: AudioManifestReference,
  normalizationVersion: Schema.Literals([1, 2]),
  asr: ASRMetadata,
  speakers: Schema.Array(Speaker),
  turns: Schema.Array(Turn),
}).annotate({ identifier: "TranscriptRevision" });
export interface TranscriptRevision extends Schema.Schema.Type<typeof TranscriptRevision> {}

export const ChannelMapping = Schema.Struct({
  channelIndex: NonNegativeInteger,
  trackId: ExchangeUUID,
}).annotate({ identifier: "ChannelMapping" });
export interface ChannelMapping extends Schema.Schema.Type<typeof ChannelMapping> {}
export const AudioObject = Schema.Struct({
  objectId: ExchangeUUID,
  index: NonNegativeInteger,
  contentType: Schema.Literals([
    MediaProfile.fields.contentType.literal,
    CaptureMasterProfile.fields.contentType.literal,
  ]),
  byteLength: PositiveInteger,
  sha256: SHA256,
  startMs: NonNegativeInteger,
  endMs: NonNegativeInteger,
  channelMap: Schema.Array(ChannelMapping).check(Schema.isMinLength(1)),
}).annotate({ identifier: "AudioObject" });
export interface AudioObject extends Schema.Schema.Type<typeof AudioObject> {}
export const AudioManifest = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  callId: ExchangeUUID,
  manifestId: ExchangeUUID,
  durationMs: NonNegativeInteger,
  mediaProfileId: Schema.Literals([
    MediaProfile.fields.id.literal,
    CaptureMasterProfile.fields.id.literal,
  ]),
  objects: Schema.Array(AudioObject),
}).annotate({ identifier: "AudioManifest" });
export interface AudioManifest extends Schema.Schema.Type<typeof AudioManifest> {}

export const ErrorCode = Schema.String.check(Schema.isPattern(/^[a-z][a-z0-9_]*$/));
export const RetryClassification = Schema.Literals(["never", "after_correction", "retryable"]);
export const StatusReadiness = Schema.Struct({
  archive: Schema.Literal("ready"),
  ownerAuthentication: Schema.Literal("ready"),
  transcription: Schema.Literals(["ready", "not_verified", "unavailable"]),
  callOperations: Schema.Literals(["ready", "unavailable"]),
}).annotate({ identifier: "StatusReadiness" });
export interface StatusReadiness extends Schema.Schema.Type<typeof StatusReadiness> {}
export const StatusNotice = Schema.Struct({
  code: ErrorCode,
  retry: RetryClassification,
  message: Schema.String.check(Schema.isMinLength(1)),
}).annotate({ identifier: "StatusNotice" });
export interface StatusNotice extends Schema.Schema.Type<typeof StatusNotice> {}
export const StatusResponse = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  apiVersion: Schema.Literal(1),
  archiveId: ExchangeUUID,
  stage: Schema.Literals(["dev", "personal"]),
  readiness: StatusReadiness,
  errors: Schema.Array(StatusNotice),
}).annotate({ identifier: "StatusResponse" });
export interface StatusResponse extends Schema.Schema.Type<typeof StatusResponse> {}
export const CommandIdentity = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
}).annotate({ identifier: "CommandIdentity" });
export interface CommandIdentity extends Schema.Schema.Type<typeof CommandIdentity> {}
export const ErrorDetail = Schema.Struct({
  code: ErrorCode,
  retry: RetryClassification,
  message: Schema.String,
  requestId: CanonicalUUIDv4,
}).annotate({ identifier: "ErrorDetail" });
export interface ErrorDetail extends Schema.Schema.Type<typeof ErrorDetail> {}
export const ErrorEnvelope = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  error: ErrorDetail,
}).annotate({ identifier: "ErrorEnvelope" });
export interface ErrorEnvelope extends Schema.Schema.Type<typeof ErrorEnvelope> {}
export const ErrorEnvelopeSchema = ErrorEnvelope;

/** Private CLI-to-native exchange; filesystem ownership and current-worktree policy stay contextual. */
export const LocalDevelopmentBridge = Schema.Struct({
  formatVersion: Schema.Literal(1),
  worktreeId: Schema.String.check(Schema.isPattern(/^[0-9a-f]{12}$/)),
  namespaceId: CanonicalUUIDv4,
  serverURL: Schema.String.check(Schema.isPattern(/^http:\/\/127\.0\.0\.1:[0-9]+$/)),
  ownerToken: Schema.String.check(Schema.isPattern(/^trigo_v1_[0-9a-f]{64}$/)),
}).annotate({ identifier: "LocalDevelopmentBridge" });
export interface LocalDevelopmentBridge extends Schema.Schema.Type<typeof LocalDevelopmentBridge> {}
