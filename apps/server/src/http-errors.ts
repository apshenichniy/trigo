import { ErrorEnvelopeSchema, type ErrorEnvelope } from "@trigo/contracts";
import { Cause, Effect, Result } from "effect";
import { HttpRouter, HttpServerResponse } from "effect/unstable/http";
import { HttpApiSchemaError } from "effect/unstable/httpapi/HttpApiError";

export function errorEnvelope(
  code: string,
  retry: ErrorEnvelope["error"]["retry"],
  message: string,
) {
  return ErrorEnvelopeSchema.make({
    schemaVersion: 1,
    // oxlint-disable-next-line effecttsgo/crypto-random-uuid -- Web Crypto owns request IDs at the Worker boundary.
    error: { code, retry, message, requestId: crypto.randomUUID() },
  });
}
export function errorResponse(
  status: number,
  code: string,
  retry: ErrorEnvelope["error"]["retry"],
  message: string,
) {
  return Response.json(errorEnvelope(code, retry, message), { status });
}
export const ownerErrorResponses = {
  "OwnerState.OwnerAuthenticationError": () =>
    Effect.succeed(
      errorResponse(
        401,
        "owner_unauthorized",
        "after_correction",
        "Provide the current Trigo owner token.",
      ),
    ),
  "OwnerState.OwnerPersistenceError": () =>
    Effect.succeed(
      errorResponse(
        503,
        "owner_persistence_unavailable",
        "retryable",
        "Owner authentication storage is temporarily unavailable; retry the request.",
      ),
    ),
};

/** HttpApi schema failures become defects; unsupported media type is a direct response. */
export const httpErrorBoundary = HttpRouter.middleware((httpEffect) =>
  httpEffect.pipe(
    Effect.map((response) =>
      response.status === 415
        ? HttpServerResponse.jsonUnsafe(
            errorEnvelope(
              "unsupported_content_type",
              "after_correction",
              "Use a supported request content type.",
            ),
            { status: 415 },
          )
        : response,
    ),
    Effect.catchCause((cause) => {
      if (Cause.hasInterrupts(cause)) return Effect.failCause(cause);
      const defect = Cause.findDefect(cause);
      if (Result.isSuccess(defect) && HttpApiSchemaError.is(defect.success)) {
        const isResponse =
          defect.success.kind === "Body" || defect.success.kind === "ResponseHeaders";
        return Effect.succeed(
          HttpServerResponse.jsonUnsafe(
            errorEnvelope(
              isResponse ? "response_invalid" : "request_invalid",
              isResponse ? "retryable" : "after_correction",
              isResponse
                ? "The server could not encode its response."
                : "The request does not match the API contract.",
            ),
            { status: isResponse ? 500 : 400 },
          ),
        );
      }
      return Effect.failCause(cause);
    }),
  ),
).layer;
