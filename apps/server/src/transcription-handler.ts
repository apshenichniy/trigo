import { Effect, Schema } from "effect";
import { HttpServerResponse } from "effect/unstable/http";
import { HttpApiBuilder } from "effect/unstable/httpapi";

import { errorEnvelope } from "./http-errors.ts";
import { readBoundedBody } from "./nova-3-transport.ts";
import { ProductApi } from "./product-api.ts";
import { type TranscriptionError, transcriptionError } from "./transcription-errors.ts";
import { Transcriptions } from "./transcriptions.ts";

const response = <A, R>(effect: Effect.Effect<A, TranscriptionError, R>) =>
  effect.pipe(
    Effect.catchTag("Transcription.Error", (error) =>
      Effect.succeed(
        HttpServerResponse.jsonUnsafe(errorEnvelope(error.code, error.retry, error.message), {
          status: error.status,
        }),
      ),
    ),
  );

const transcriptionRequest = Effect.fn("TranscriptionHandler.request")(function* (
  request: Request,
) {
  if (
    request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json"
  ) {
    return yield* transcriptionError("asr_invalid");
  }
  const bytes = yield* readBoundedBody(request.body, 4096).pipe(
    Effect.mapError(() => transcriptionError("asr_invalid")),
  );
  const text = yield* Effect.try({
    try: () => new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    catch: () => transcriptionError("asr_invalid"),
  });
  return yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(text).pipe(
    Effect.mapError(() => transcriptionError("asr_invalid")),
  );
});
const retainedResponse = (result: { bytes: Uint8Array; sha256: string }) =>
  HttpServerResponse.uint8Array(result.bytes, {
    headers: {
      "content-type": "application/json",
      "cache-control": "private, no-store",
      "content-length": String(result.bytes.byteLength),
      etag: `"${result.sha256}"`,
      "x-trigo-content-sha256": result.sha256,
    },
  });

export function transcriptionHandlers(request: Request) {
  return HttpApiBuilder.group(
    ProductApi,
    "transcriptions",
    Effect.fn(function* (group) {
      const service = yield* Transcriptions;
      return group
        .handleRaw("requestTranscription", ({ params }) =>
          response(
            transcriptionRequest(request).pipe(
              Effect.flatMap((value) => service.request(params.callId, value)),
            ),
          ),
        )
        .handle("transcriptionOperation", ({ params }) =>
          response(service.operation(params.operationId)),
        )
        .handleRaw("transcriptRevision", ({ params }) =>
          response(
            service
              .revision(params.callId, params.revisionId, false)
              .pipe(Effect.map(retainedResponse)),
          ),
        )
        .handleRaw("transcriptProvenance", ({ params }) =>
          response(
            service
              .revision(params.callId, params.revisionId, true)
              .pipe(Effect.map(retainedResponse)),
          ),
        );
    }),
  );
}

export function isTranscriptionRoute(request: Request) {
  const path = new URL(request.url).pathname;
  return (
    (request.method === "POST" && /^\/v1\/calls\/[^/]+\/transcriptions$/.test(path)) ||
    (request.method === "GET" &&
      (/^\/v1\/operations\/[^/]+$/.test(path) ||
        /^\/v1\/calls\/[^/]+\/revisions\/[^/]+(?:\/provenance)?$/.test(path)))
  );
}
