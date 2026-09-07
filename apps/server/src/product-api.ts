import { ErrorEnvelopeSchema, StatusResponse } from "@trigo/contracts";
import { HttpApi, HttpApiEndpoint, HttpApiGroup } from "effect/unstable/httpapi";

/** The supported product surface; upload/transcription/sync remain unavailable. */
export const ProductApi = HttpApi.make("trigo").add(
  HttpApiGroup.make("owner").add(
    HttpApiEndpoint.get("status", "/v1/status", {
      success: StatusResponse,
      error: [401, 503].map((httpApiStatus) => ErrorEnvelopeSchema.annotate({ httpApiStatus })),
    }),
  ),
);
