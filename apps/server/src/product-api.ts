import { Schema } from "effect";
import { HttpApi, HttpApiEndpoint, HttpApiGroup } from "effect/unstable/httpapi";

import {
  ErrorEnvelopeSchema,
  ExchangeUUID,
  FinalizeMasterUpload,
  MasterUploadSession,
  PlaybackGrant,
  RegisterMasterUpload,
  RequestTranscription,
  RequestPlayback,
  SHA256,
  StatusResponse,
  TranscriptionOperation,
  TranscriptRevision,
  UploadPartReceipt,
  VerifiedMasterReceipt,
} from "@trigo/contracts";

const uploadErrors = [400, 401, 404, 409, 410, 413, 503].map((httpApiStatus) =>
  ErrorEnvelopeSchema.annotate({ httpApiStatus }),
);
const transcriptionErrors = [400, 401, 404, 409, 410, 413, 422, 501, 503].map((httpApiStatus) =>
  ErrorEnvelopeSchema.annotate({ httpApiStatus }),
);
const playbackErrors = [400, 401, 404, 409, 410, 416, 503].map((httpApiStatus) =>
  ErrorEnvelopeSchema.annotate({ httpApiStatus }),
);

/** Media requests use their short-lived capability instead of owner authentication. */
export const PlaybackMediaApi = HttpApi.make("trigo-playback-media").add(
  HttpApiGroup.make("playbackMedia").add(
    HttpApiEndpoint.get("segment", "/v1/calls/:callId/playback/:grantId/segments/:index", {
      params: { callId: ExchangeUUID, grantId: ExchangeUUID, index: Schema.Int },
      success: Schema.Uint8Array,
      error: playbackErrors,
    }),
  ),
);

/** Shared authenticated product handlers; transcription and sync remain separate tasks. */
export const ProductApi = HttpApi.make("trigo").add(
  HttpApiGroup.make("owner").add(
    HttpApiEndpoint.get("status", "/v1/status", {
      success: StatusResponse,
      error: [401, 503].map((httpApiStatus) => ErrorEnvelopeSchema.annotate({ httpApiStatus })),
    }),
  ),
  HttpApiGroup.make("uploads").add(
    HttpApiEndpoint.post("registerMaster", "/v1/calls", {
      payload: RegisterMasterUpload,
      success: MasterUploadSession,
      error: uploadErrors,
    }),
    HttpApiEndpoint.put("uploadPart", "/v1/calls/:callId/uploads/:uploadId/chunks/:index", {
      params: { callId: ExchangeUUID, uploadId: ExchangeUUID, index: Schema.Int },
      headers: {
        "content-length": Schema.String.check(Schema.isPattern(/^[0-9]+$/)),
        "content-type": Schema.Literal("application/octet-stream"),
        "x-trigo-byte-offset": Schema.String.check(Schema.isPattern(/^[0-9]+$/)),
        "x-trigo-content-sha256": SHA256,
      },
      // The handler admits and streams this binary body; it never uses JSON body decoding.
      success: UploadPartReceipt,
      error: uploadErrors,
    }),
    HttpApiEndpoint.post("finalizeMaster", "/v1/calls/:callId/finalize", {
      params: { callId: ExchangeUUID },
      payload: FinalizeMasterUpload,
      success: VerifiedMasterReceipt,
      error: uploadErrors,
    }),
  ),
  HttpApiGroup.make("transcriptions").add(
    HttpApiEndpoint.post("requestTranscription", "/v1/calls/:callId/transcriptions", {
      params: { callId: ExchangeUUID },
      payload: RequestTranscription,
      success: TranscriptionOperation,
      error: transcriptionErrors,
    }),
    HttpApiEndpoint.get("transcriptionOperation", "/v1/operations/:operationId", {
      params: { operationId: ExchangeUUID },
      success: TranscriptionOperation,
      error: transcriptionErrors,
    }),
    HttpApiEndpoint.get("transcriptRevision", "/v1/calls/:callId/revisions/:revisionId", {
      params: { callId: ExchangeUUID, revisionId: ExchangeUUID },
      success: TranscriptRevision,
      error: transcriptionErrors,
    }),
    HttpApiEndpoint.get(
      "transcriptProvenance",
      "/v1/calls/:callId/revisions/:revisionId/provenance",
      {
        params: { callId: ExchangeUUID, revisionId: ExchangeUUID },
        success: Schema.Unknown,
        error: transcriptionErrors,
      },
    ),
  ),
  HttpApiGroup.make("playbackGrants").add(
    HttpApiEndpoint.post("requestPlayback", "/v1/calls/:callId/playback", {
      params: { callId: ExchangeUUID },
      payload: RequestPlayback,
      success: PlaybackGrant,
      error: playbackErrors,
    }),
  ),
);
