import { Effect, Layer } from "effect";
import { HttpRouter, HttpServer } from "effect/unstable/http";
import { HttpApiBuilder } from "effect/unstable/httpapi";

import { type StatusResponse } from "@trigo/contracts";

import { errorResponse, httpErrorBoundary, ownerErrorResponses } from "./http-errors.ts";
import { authenticateOwner, type OwnerContext } from "./owner-state.ts";
import { ProductApi } from "./product-api.ts";

export interface ProductEnvironment {
  readonly CATALOG: Pick<D1Database, "prepare">;
  readonly DEPLOYMENT_STAGE: "dev" | "personal";
}
export function ownerStatus(context: OwnerContext, stage: "dev" | "personal"): StatusResponse {
  return {
    schemaVersion: 1,
    apiVersion: 1,
    archiveId: context.archiveId,
    stage,
    readiness: {
      archive: "ready",
      ownerAuthentication: "ready",
      transcription: "not_verified",
      callOperations: "unavailable",
    },
    errors: [
      {
        code: "asr_not_verified",
        retry: "after_correction",
        message: "Nova-3 readiness has not been verified; complete issue #13 before transcription.",
      },
      {
        code: "call_operations_unavailable",
        retry: "after_correction",
        message: "Call operations are unavailable until issue #17.",
      },
    ],
  };
}

const productResponse = Effect.fn("ProductApi.respond")(function* (
  request: Request,
  env: ProductEnvironment,
) {
  // Keep the exact bearer grammar and authentication-before-disclosure for unavailable routes.
  const owner = yield* authenticateOwner(env.CATALOG, request);
  if (request.method !== "GET" || new URL(request.url).pathname !== "/v1/status") {
    return errorResponse(
      501,
      "operation_unavailable",
      "after_correction",
      "This owner operation is not implemented yet.",
    );
  }
  const handlers = HttpApiBuilder.group(ProductApi, "owner", (group) =>
    group.handle("status", () => Effect.succeed(ownerStatus(owner, env.DEPLOYMENT_STAGE))),
  );
  const routes = HttpApiBuilder.layer(ProductApi).pipe(
    Layer.provide(handlers),
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
    productResponse(request, env).pipe(Effect.catchTags(ownerErrorResponses)),
  );
}
