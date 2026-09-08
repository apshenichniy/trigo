import { Schema } from "effect";

import { AsrProbeLanguage } from "./asr-probe.ts";
import { Nova3StreamProfileId } from "./asr-profile.ts";
import { ExchangeUUID, PositiveInteger, SHA256, UTCDateTime } from "./document-schema.ts";

/** Command identity survives transport retries; a candidate is separate from a published result. */
export const RequestTranscription = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
  revisionId: ExchangeUUID,
  requestedLanguage: AsrProbeLanguage,
  profileId: Nova3StreamProfileId,
}).annotate({ identifier: "RequestTranscription" });
export interface RequestTranscription extends Schema.Schema.Type<typeof RequestTranscription> {}

export const TranscriptionFailure = Schema.Struct({
  code: Schema.NonEmptyString,
  retry: Schema.Literals(["never", "after_correction", "retryable"]),
  message: Schema.NonEmptyString,
}).annotate({ identifier: "TranscriptionFailure" });
export interface TranscriptionFailure extends Schema.Schema.Type<typeof TranscriptionFailure> {}

/** These hashes describe exact retained bytes. Availability does not acknowledge local import. */
export const AvailableTranscript = Schema.Struct({
  revisionId: ExchangeUUID,
  createdAt: UTCDateTime,
  sha256: SHA256,
  byteLength: PositiveInteger,
  provenanceSHA256: SHA256,
  provenanceByteLength: PositiveInteger,
}).annotate({ identifier: "AvailableTranscript" });
export interface AvailableTranscript extends Schema.Schema.Type<typeof AvailableTranscript> {}

export const TranscriptionOperation = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  revisionId: ExchangeUUID,
  state: Schema.Literals(["queued", "running", "result_available", "failed"]),
  attemptCount: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 2 })),
  createdAt: UTCDateTime,
  updatedAt: UTCDateTime,
  result: Schema.NullOr(AvailableTranscript),
  failure: Schema.NullOr(TranscriptionFailure),
}).annotate({ identifier: "TranscriptionOperation" });
export interface TranscriptionOperation extends Schema.Schema.Type<typeof TranscriptionOperation> {}

export const transcriptionSchemas = {
  RequestTranscription,
  AvailableTranscript,
  TranscriptionOperation,
};
