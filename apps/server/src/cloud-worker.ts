import { WorkflowEntrypoint } from "cloudflare:workers";
import { Effect } from "effect";

export interface PendingArchiveWorkflowInput {
  readonly operationId: string;
}

export interface CloudEnvironmentProbe {
  readonly ARCHIVE: { readonly get: unknown };
  readonly CATALOG: { readonly prepare: unknown };
  readonly ARCHIVE_WORKFLOW: { readonly create: unknown };
  readonly AI: { readonly run: unknown };
  readonly DEPLOYMENT_STAGE: string;
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
    if (request.method !== "GET") return new Response(null, { status: 405 });
    if (url.pathname === "/__trigo/infrastructure")
      return Effect.runPromise(infrastructureResponse(env));
    if (url.pathname.startsWith("/v1/"))
      return Response.json({ error: "owner_setup_unavailable", issue: 30 }, { status: 503 });
    return new Response(null, { status: 404 });
  },
};
