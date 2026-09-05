import { WorkflowEntrypoint } from "cloudflare:workers";
import type { ErrorEnvelope, StatusResponse } from "@trigo/contracts";
import { Effect } from "effect";
import {
  authenticateOwner,
  type OwnerContext,
  OwnerAuthenticationError,
  OwnerPersistenceError,
} from "./owner-state.ts";

export interface PendingArchiveWorkflowInput {
  readonly operationId: string;
}

export interface CloudEnvironmentProbe {
  readonly ARCHIVE: { readonly get: unknown };
  readonly CATALOG: Pick<D1Database, "prepare">;
  readonly ARCHIVE_WORKFLOW: { readonly create: unknown };
  readonly AI: { readonly run: unknown };
  readonly DEPLOYMENT_STAGE: "dev" | "personal";
  readonly DEPLOYMENT_IDENTITY: string;
}

function errorResponse(
  status: number,
  code: string,
  retry: "never" | "after_correction" | "retryable",
  message: string,
): Response {
  const body = {
    schemaVersion: 1,
    // oxlint-disable-next-line effecttsgo/crypto-random-uuid -- Web Crypto owns Worker request IDs at this platform boundary.
    error: { code, retry, message, requestId: crypto.randomUUID() },
  } satisfies ErrorEnvelope;
  return Response.json(body, { status });
}

function statusResponse(context: OwnerContext, stage: "dev" | "personal"): Response {
  const body = {
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
  } satisfies StatusResponse;
  return Response.json(body);
}

const ownerResponse = Effect.fn("CloudWorker.ownerResponse")(function* (
  request: Request,
  env: CloudEnvironmentProbe,
) {
  const context = yield* authenticateOwner(env.CATALOG, request);
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/v1/status")
    return statusResponse(context, env.DEPLOYMENT_STAGE);
  return errorResponse(
    501,
    "operation_unavailable",
    "after_correction",
    "This owner operation is not implemented yet.",
  );
});

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
    if (request.method === "GET" && url.pathname === "/__trigo/infrastructure")
      return Effect.runPromise(infrastructureResponse(env));
    if (url.pathname.startsWith("/v1/"))
      return Effect.runPromise(
        ownerResponse(request, env).pipe(
          Effect.catchTags({
            "OwnerState.OwnerAuthenticationError": (_error: OwnerAuthenticationError) =>
              Effect.succeed(
                errorResponse(
                  401,
                  "owner_unauthorized",
                  "after_correction",
                  "Provide the current Trigo owner token.",
                ),
              ),
            "OwnerState.OwnerPersistenceError": (_error: OwnerPersistenceError) =>
              Effect.succeed(
                errorResponse(
                  503,
                  "owner_setup_unavailable",
                  "retryable",
                  "Owner identity is unavailable; run the operator initialization command.",
                ),
              ),
          }),
        ),
      );
    if (request.method !== "GET") return new Response(null, { status: 405 });
    return new Response(null, { status: 404 });
  },
};
