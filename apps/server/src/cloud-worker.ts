import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { Effect } from "effect";

import { type AsrProbeEnvironment, AsrProbeError, asrProbeResponse } from "./asr-probe.ts";
import { assemblyAIClient } from "./assemblyai-client.ts";
import { hostedAsrProbeResponse } from "./hosted-asr-probe.ts";
import { hostedMasterProbeResponse } from "./hosted-master-probe.ts";
import { errorResponse, ownerErrorResponses } from "./http-errors.ts";
import { authenticateOwner } from "./owner-state.ts";
import { productFetch } from "./product-handler.ts";
import { runTranscriptionWorkflow } from "./transcription-workflow.ts";
import { type TranscriptionWorkflowBinding } from "./transcriptions.ts";

export interface PendingArchiveWorkflowInput {
  readonly operationId: string;
}

export interface CloudEnvironmentProbe extends AsrProbeEnvironment {
  readonly ARCHIVE: Pick<R2Bucket, "get" | "put" | "head" | "delete">;
  readonly CATALOG: Pick<D1Database, "prepare">;
  readonly ARCHIVE_WORKFLOW: TranscriptionWorkflowBinding;
  readonly DEPLOYMENT_STAGE: "dev" | "personal";
  readonly DEPLOYMENT_IDENTITY: string;
  readonly ASSEMBLYAI_API_KEY?: string;
}

export class PendingArchiveWorkflow extends WorkflowEntrypoint<
  CloudEnvironmentProbe,
  PendingArchiveWorkflowInput
> {
  run(event: WorkflowEvent<PendingArchiveWorkflowInput>, step: WorkflowStep) {
    return runTranscriptionWorkflow(
      {
        ...this.env,
        TRANSCRIPTION_MODE: "hosted",
        ASSEMBLYAI: assemblyAIClient(this.env.ASSEMBLYAI_API_KEY),
      },
      event.payload.operationId,
      step,
    );
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
    assemblyAi: env.ASSEMBLYAI_API_KEY?.trim() ? "configured-not-verified" : "missing",
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
    const hostedProbe = /^\/__trigo\/hosted-asr-probe\/([a-z0-9-]+)$/.exec(url.pathname);
    const masterProbe = /^\/__trigo\/hosted-master-probe\/([a-z0-9-]+)$/.exec(url.pathname);
    if (masterProbe && env.DEPLOYMENT_STAGE !== "dev") {
      return new Response(null, { status: 404 });
    }
    if ((asrProbe || hostedProbe || masterProbe) && env.DEPLOYMENT_STAGE === "dev") {
      const fixture = (asrProbe ?? hostedProbe ?? masterProbe)?.[1];
      if (fixture === undefined) {
        return new Response(null, { status: 404 });
      }
      return Effect.runPromise(
        authenticateOwner(env.CATALOG, request).pipe(
          Effect.flatMap(() => {
            if (masterProbe) {
              return hostedMasterProbeResponse(request, env, fixture);
            }
            return hostedProbe
              ? hostedAsrProbeResponse(request, env, fixture)
              : asrProbeResponse(request, env, fixture);
          }),
          Effect.catchTags({
            ...ownerErrorResponses,
            "AsrProbe.Error": (error: AsrProbeError) =>
              Effect.succeed(errorResponse(error.status, error.code, error.retry, error.message)),
          }),
        ),
      );
    }
    if (url.pathname.startsWith("/v1/")) {
      return productFetch(request, {
        ...env,
        TRANSCRIPTION_WORKFLOW: env.ARCHIVE_WORKFLOW,
        TRANSCRIPTION_MODE: "hosted",
        ASSEMBLYAI: assemblyAIClient(env.ASSEMBLYAI_API_KEY),
      });
    }
    if (request.method !== "GET") {
      return new Response(null, { status: 405 });
    }
    return new Response(null, { status: 404 });
  },
};
