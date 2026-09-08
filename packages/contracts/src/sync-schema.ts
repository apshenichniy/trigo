import { Schema } from "effect";

import {
  ExchangeUUID,
  NonNegativeInteger,
  PositiveInteger,
  SHA256,
  UTCDateTime,
} from "./document-schema.ts";
import { AvailableTranscript } from "./transcription-schema.ts";
import { VerifiedMasterReceipt } from "./upload-schema.ts";

export const ReplicaReference = Schema.Struct({
  documentVersion: PositiveInteger,
  schemaVersion: Schema.Literals([1, 2]),
  sha256: SHA256,
  byteLength: PositiveInteger,
}).annotate({ identifier: "ReplicaReference" });
export interface ReplicaReference extends Schema.Schema.Type<typeof ReplicaReference> {}

/** The document string is the exact immutable snapshot, never a server-authored rewrite. */
export const PublishCallReplica = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
  expectedDocumentVersion: Schema.NullOr(PositiveInteger),
  document: Schema.NonEmptyString,
  annotationRevisionIds: Schema.Array(ExchangeUUID),
}).annotate({ identifier: "PublishCallReplica" });
export interface PublishCallReplica extends Schema.Schema.Type<typeof PublishCallReplica> {}

export const ReplicaReceipt = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  documentVersion: PositiveInteger,
  sha256: SHA256,
  byteLength: PositiveInteger,
  publishedAt: UTCDateTime,
}).annotate({ identifier: "ReplicaReceipt" });
export interface ReplicaReceipt extends Schema.Schema.Type<typeof ReplicaReceipt> {}

/** A fence is visible before cleanup finishes; it never implies that admitted writers drained. */
export const CallDeletionMarker = Schema.Struct({
  callId: ExchangeUUID,
  markedAt: UTCDateTime,
  phase: Schema.Literals(["requested", "draining", "deleting", "complete"]),
}).annotate({ identifier: "CallDeletionMarker" });
export interface CallDeletionMarker extends Schema.Schema.Type<typeof CallDeletionMarker> {}

export const CallCatalogEntry = Schema.Struct({
  callId: ExchangeUUID,
  replica: Schema.NullOr(ReplicaReference),
  audio: Schema.NullOr(VerifiedMasterReceipt),
  latestTranscriptionOperationId: Schema.NullOr(ExchangeUUID),
  resultCount: NonNegativeInteger,
  deletion: Schema.NullOr(CallDeletionMarker),
}).annotate({ identifier: "CallCatalogEntry" });
export interface CallCatalogEntry extends Schema.Schema.Type<typeof CallCatalogEntry> {}

export const CallCatalogPage = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  archiveId: ExchangeUUID,
  calls: Schema.Array(CallCatalogEntry),
  nextCursor: Schema.NullOr(Schema.NonEmptyString),
  changesCursor: Schema.NonEmptyString,
}).annotate({ identifier: "CallCatalogPage" });
export interface CallCatalogPage extends Schema.Schema.Type<typeof CallCatalogPage> {}

export const CallChange = Schema.Struct({
  sequence: PositiveInteger,
  call: CallCatalogEntry,
}).annotate({ identifier: "CallChange" });
export interface CallChange extends Schema.Schema.Type<typeof CallChange> {}

export const CallChangesPage = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  archiveId: ExchangeUUID,
  changes: Schema.Array(CallChange),
  nextCursor: Schema.NonEmptyString,
  hasMore: Schema.Boolean,
}).annotate({ identifier: "CallChangesPage" });
export interface CallChangesPage extends Schema.Schema.Type<typeof CallChangesPage> {}

export const CatalogTranscriptResult = Schema.Struct({
  operationId: ExchangeUUID,
  generation: PositiveInteger,
  result: AvailableTranscript,
}).annotate({ identifier: "CatalogTranscriptResult" });
export interface CatalogTranscriptResult extends Schema.Schema.Type<
  typeof CatalogTranscriptResult
> {}

export const TranscriptResultsPage = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  results: Schema.Array(CatalogTranscriptResult),
  nextCursor: Schema.NullOr(Schema.NonEmptyString),
}).annotate({ identifier: "TranscriptResultsPage" });
export interface TranscriptResultsPage extends Schema.Schema.Type<typeof TranscriptResultsPage> {}

export const syncSchemas = {
  ReplicaReference,
  PublishCallReplica,
  ReplicaReceipt,
  CallDeletionMarker,
  CallCatalogEntry,
  CallCatalogPage,
  CallChange,
  CallChangesPage,
  CatalogTranscriptResult,
  TranscriptResultsPage,
};
