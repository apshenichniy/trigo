import { Effect, Layer } from "effect";
import { HttpRouter, HttpServer } from "effect/unstable/http";
import { HttpApiBuilder } from "effect/unstable/httpapi";

import { type StatusResponse } from "@trigo/contracts";

import { canonicalSyncLayer } from "./canonical-sync.ts";
import { errorResponse, httpErrorBoundary, ownerErrorResponses } from "./http-errors.ts";
import { masterUploadsLayer } from "./master-uploads.ts";
import { authenticateOwner, type OwnerContext } from "./owner-state.ts";
import { playbackGrantsLayer } from "./playback-grants.ts";
import {
  isPlaybackGrantRoute,
  isPlaybackMediaRoute,
  playbackGrantHandlers,
  playbackMediaResponse,
} from "./playback-handler.ts";
import { ProductApi } from "./product-api.ts";
import { isSyncRoute, syncHandlers } from "./sync-handler.ts";
import { isTranscriptionRoute, transcriptionHandlers } from "./transcription-handler.ts";
import { transcriptionsLayer, type TranscriptionEnvironment } from "./transcriptions.ts";
import { isImplementedProductRoute, uploadHandlers } from "./upload-handler.ts";

export interface ProductEnvironment extends TranscriptionEnvironment {
  readonly DEPLOYMENT_STAGE: "dev" | "personal";
}
export function ownerStatus(
  context: OwnerContext,
  stage: "dev" | "personal",
  mode?: "hosted" | "fake",
): StatusResponse {
  return {
    schemaVersion: 1,
    apiVersion: 1,
    archiveId: context.archiveId,
    stage,
    readiness: {
      archive: "ready",
      ownerAuthentication: "ready",
      transcription: mode === "hosted" ? "ready" : "not_verified",
      callOperations: "ready",
    },
    errors:
      mode === "hosted"
        ? []
        : [
            {
              code: "asr_not_verified",
              retry: "after_correction",
              message:
                mode === "fake"
                  ? "Local development uses deterministic fake transcription."
                  : "Hosted transcription is not configured for this server.",
            },
          ],
  };
}

const productResponse = Effect.fn("ProductApi.respond")(function* (
  request: Request,
  env: ProductEnvironment,
) {
  if (isPlaybackMediaRoute(request)) {
    return yield* playbackMediaResponse(request, env);
  }
  // Keep the exact bearer grammar and authentication-before-disclosure for unavailable routes.
  const owner = yield* authenticateOwner(env.CATALOG, request);
  if (
    !isImplementedProductRoute(request) &&
    !isTranscriptionRoute(request) &&
    !isSyncRoute(request) &&
    !isPlaybackGrantRoute(request)
  ) {
    return errorResponse(
      501,
      "operation_unavailable",
      "after_correction",
      "This owner operation is not implemented yet.",
    );
  }
  const handlers = HttpApiBuilder.group(ProductApi, "owner", (group) =>
    group.handle("status", () =>
      Effect.succeed(ownerStatus(owner, env.DEPLOYMENT_STAGE, env.TRANSCRIPTION_MODE)),
    ),
  );
  const routes = HttpApiBuilder.layer(ProductApi).pipe(
    Layer.provide([
      handlers,
      uploadHandlers(request).pipe(Layer.provide(masterUploadsLayer(env, owner))),
      transcriptionHandlers(request).pipe(Layer.provide(transcriptionsLayer(env, owner))),
      syncHandlers(request).pipe(Layer.provide(canonicalSyncLayer(env, owner))),
      playbackGrantHandlers(request).pipe(Layer.provide(playbackGrantsLayer(env, owner))),
    ]),
    Layer.provide(httpErrorBoundary),
    Layer.provide(HttpServer.layerServices),
  );
  // Per-request lifetime prevents D1 bindings/owner context leaking between Worker invocations.
  return yield* Effect.acquireUseRelease(
    Effect.sync(() => HttpRouter.toWebHandler(routes, { disableLogger: true })),
    ({ handler }) => Effect.promise(() => handler(request)),
    ({ dispose }) => Effect.promise(dispose),
  );
});
export function productFetch(request: Request, env: ProductEnvironment): Promise<Response> {
  return Effect.runPromise(
    productResponse(request, env).pipe(
      Effect.catchTags(ownerErrorResponses),
      Effect.map((response) => {
        if (isPlaybackGrantRoute(request) || isPlaybackMediaRoute(request)) {
          response.headers.set("cache-control", "private, no-store");
          response.headers.set("vary", "Authorization");
        }
        return response;
      }),
    ),
  );
}
