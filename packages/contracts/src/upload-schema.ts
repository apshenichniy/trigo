import { Schema } from "effect";

import { CaptureMasterProfile } from "./capture-master-profile.ts";
import {
  AudioManifestReference,
  ExchangeUUID,
  NonNegativeInteger,
  SHA256,
  UTCDateTime,
} from "./document-schema.ts";

/** Transport identity and boundaries never identify an ASR submission. */
export const uploadPartBytes = 8_388_608;
export const maximumMasterBytes = 691_200_068;
export const maximumUploadParts = Math.ceil(maximumMasterBytes / uploadPartBytes);

const MasterByteLength = Schema.Int.check(
  Schema.isBetween({ minimum: 68, maximum: maximumMasterBytes }),
);
const PartIndex = Schema.Int.check(
  Schema.isBetween({ minimum: 0, maximum: maximumUploadParts - 1 }),
);
const PartByteLength = Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: uploadPartBytes }));
const DocumentBytes = Schema.String.check(
  Schema.isMinLength(1),
  Schema.isMaxLength(uploadPartBytes),
);
const identity = {
  schemaVersion: Schema.Literal(1),
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  uploadId: ExchangeUUID,
  masterId: ExchangeUUID,
};

export const RegisterMasterUpload = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  uploadId: ExchangeUUID,
  masterId: ExchangeUUID,
  // Exact published UTF-8 content, not a server reserialization of a document.
  callDocument: DocumentBytes,
}).annotate({ identifier: "RegisterMasterUpload" });
export interface RegisterMasterUpload extends Schema.Schema.Type<typeof RegisterMasterUpload> {}

export const MasterUploadSession = Schema.Struct({
  ...identity,
  partBytes: Schema.Literal(uploadPartBytes),
  mediaProfileId: CaptureMasterProfile.fields.id,
}).annotate({ identifier: "MasterUploadSession" });
export interface MasterUploadSession extends Schema.Schema.Type<typeof MasterUploadSession> {}

export const UploadPartDescriptor = Schema.Struct({
  index: PartIndex,
  byteOffset: NonNegativeInteger,
  byteLength: PartByteLength,
  sha256: SHA256,
}).annotate({ identifier: "UploadPartDescriptor" });
export interface UploadPartDescriptor extends Schema.Schema.Type<typeof UploadPartDescriptor> {}

export const UploadPartReceipt = Schema.Struct({
  ...identity,
  ...UploadPartDescriptor.fields,
  receiptId: ExchangeUUID,
}).annotate({ identifier: "UploadPartReceipt" });
export interface UploadPartReceipt extends Schema.Schema.Type<typeof UploadPartReceipt> {}

export const FinalizeMasterUpload = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  operationId: ExchangeUUID,
  uploadId: ExchangeUUID,
  callDocument: DocumentBytes,
  audioManifest: DocumentBytes,
  masterSHA256: SHA256,
}).annotate({ identifier: "FinalizeMasterUpload" });
export interface FinalizeMasterUpload extends Schema.Schema.Type<typeof FinalizeMasterUpload> {}

export const VerifiedMasterChannel = Schema.Struct({
  channelIndex: Schema.Literals([0, 1]),
  trackId: ExchangeUUID,
}).annotate({ identifier: "VerifiedMasterChannel" });
export interface VerifiedMasterChannel extends Schema.Schema.Type<typeof VerifiedMasterChannel> {}

/** Only this complete receipt, durably committed locally, authorizes media cleanup. */
export const VerifiedMasterReceipt = Schema.Struct({
  ...identity,
  operationId: ExchangeUUID,
  receiptId: ExchangeUUID,
  verification: Schema.Literal("complete-master-sha256-v1"),
  mediaProfileId: CaptureMasterProfile.fields.id,
  masterSHA256: SHA256,
  byteLength: MasterByteLength,
  durationMs: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 10_800_000 })),
  channelMap: Schema.Array(VerifiedMasterChannel).check(
    Schema.isMinLength(2),
    Schema.isMaxLength(2),
  ),
  audioManifest: AudioManifestReference,
  storedAt: UTCDateTime,
}).annotate({ identifier: "VerifiedMasterReceipt" });
export interface VerifiedMasterReceipt extends Schema.Schema.Type<typeof VerifiedMasterReceipt> {}

export const uploadSchemas = {
  RegisterMasterUpload,
  MasterUploadSession,
  UploadPartDescriptor,
  UploadPartReceipt,
  FinalizeMasterUpload,
  VerifiedMasterReceipt,
};
