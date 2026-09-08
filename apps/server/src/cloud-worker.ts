import { WorkflowEntrypoint } from "cloudflare:workers";
import { Effect } from "effect";

import { type AsrProbeEnvironment, AsrProbeError, asrProbeResponse } from "./asr-probe.ts";
import { errorResponse, ownerErrorResponses } from "./http-errors.ts";
import { authenticateOwner } from "./owner-state.ts";
import { productFetch } from "./product-handler.ts";

export interface PendingArchiveWorkflowInput {
  readonly operationId: string;
}

export interface CloudEnvironmentProbe extends AsrProbeEnvironment {
  readonly ARCHIVE: Pick<R2Bucket, "get" | "put" | "head" | "delete">;
  readonly CATALOG: Pick<D1Database, "prepare">;
  readonly ARCHIVE_WORKFLOW: { readonly create: unknown };
  readonly DEPLOYMENT_STAGE: "dev" | "personal";
  readonly DEPLOYMENT_IDENTITY: string;
}

export class PendingArchiveWorkflow extends WorkflowEntrypoint<
  CloudEnvironmentProbe,
  PendingArchiveWorkflowInput
> {
  run(): Promise<never> {
    return Promise.reject(new Error("Archive workflow execution is unavailable until Trigo #18"));
  }
}

const infrastructureResponse = Effect.fn("CloudWorker.infrastructure")((
  env: CloudEnvironmentProbe,
) => {
  const bindings = {
    archive: typeof env.ARCHIVE.get === "function" ? "configured" : "missing",
    catalog: typeof env.CATALOG.prepare === "function" ? "configured" : "missing",
    workflow: typeof env.ARCHIVE_WORKFLOW.create === "function" ? "configured" : "missing",
    workersAi: typeof env.AI.run === "function" ? "configured-not-verified" : "missing",
  } as const;
  const configured = Object.values(bindings).every((value) => value !== "missing");
  return Effect.succeed(
    Response.json(
      { stage: env.DEPLOYMENT_STAGE, identity: env.DEPLOYMENT_IDENTITY, bindings },
      { status: configured ? 200 : 503 },
    ),
  );
});

export default {
  fetch(request: Request, env: CloudEnvironmentProbe): Response | Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/__trigo/infrastructure") {
      return Effect.runPromise(infrastructureResponse(env));
    }
    const asrProbe = /^\/__trigo\/asr-probe\/([a-z0-9-]+)$/.exec(url.pathname);
    if (asrProbe && env.DEPLOYMENT_STAGE === "dev") {
      const fixture = asrProbe[1];
      if (fixture === undefined) {
        return new Response(null, { status: 404 });
      }
      return Effect.runPromise(
        authenticateOwner(env.CATALOG, request).pipe(
          Effect.flatMap(() => asrProbeResponse(request, env, fixture)),
          Effect.catchTags({
            ...ownerErrorResponses,
            "AsrProbe.Error": (error: AsrProbeError) =>
              Effect.succeed(errorResponse(error.status, error.code, error.retry, error.message)),
          }),
        ),
      );
    }
    if (url.pathname.startsWith("/v1/")) {
      return productFetch(request, env);
    }
    if (request.method !== "GET") {
      return new Response(null, { status: 405 });
    }
    return new Response(null, { status: 404 });
  },
};
