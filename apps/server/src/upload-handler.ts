import { Effect } from "effect";
import { HttpServerResponse } from "effect/unstable/http";
import { HttpApiBuilder } from "effect/unstable/httpapi";

import { uploadPartBytes } from "@trigo/contracts";

import { errorEnvelope } from "./http-errors.ts";
import { MasterUploads } from "./master-uploads.ts";
import { ProductApi } from "./product-api.ts";
import { invalidUpload, uploadStorage, type UploadError } from "./upload-errors.ts";
import { boundedJson, oversizedUpload } from "./upload-streams.ts";

const response = <A, R>(effect: Effect.Effect<A, UploadError, R>) =>
  effect.pipe(
    Effect.catchTag("MasterUpload.Error", (error) =>
      Effect.succeed(
        HttpServerResponse.jsonUnsafe(errorEnvelope(error.code, error.retry, error.message), {
          status: error.status,
        }),
      ),
    ),
  );

/** Raw handlers preserve streaming and bound JSON before materializing metadata. */
export function uploadHandlers(request: Request) {
  return HttpApiBuilder.group(
    ProductApi,
    "uploads",
    Effect.fn(function* (group) {
      const uploads = yield* MasterUploads;
      return group
        .handleRaw("registerMaster", () =>
          response(
            uploadStorage("request metadata", () => boundedJson(request)).pipe(
              Effect.flatMap(uploads.register),
            ),
          ),
        )
        .handleRaw("uploadPart", ({ params, headers }) =>
          response(
            Effect.gen(function* () {
              const length = Number(headers["content-length"]);
              if (length > uploadPartBytes) {
                return yield* oversizedUpload();
              }
              if (!request.body) {
                return yield* invalidUpload("The admitted part requires a binary body.");
              }
              return yield* uploads.part(
                params.callId,
                params.uploadId,
                {
                  index: params.index,
                  byteOffset: Number(headers["x-trigo-byte-offset"]),
                  byteLength: length,
                  sha256: headers["x-trigo-content-sha256"],
                },
                request.body,
              );
            }),
          ),
        )
        .handleRaw("finalizeMaster", ({ params }) =>
          response(
            uploadStorage("request metadata", () => boundedJson(request)).pipe(
              Effect.flatMap((input) => uploads.finalize(params.callId, input)),
            ),
          ),
        );
    }),
  );
}

export function isImplementedProductRoute(request: Request) {
  const path = new URL(request.url).pathname;
  return (
    (request.method === "GET" && path === "/v1/status") ||
    (request.method === "POST" &&
      (path === "/v1/calls" || /^\/v1\/calls\/[^/]+\/finalize$/.test(path))) ||
    (request.method === "PUT" && /^\/v1\/calls\/[^/]+\/uploads\/[^/]+\/chunks\/[^/]+$/.test(path))
  );
}
