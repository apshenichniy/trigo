import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { Effect, Schema } from "effect";

import { TranscriptRevision } from "@trigo/contracts";

import { fakeAsr } from "./asr.ts";
import { errorResponse } from "./http-errors.ts";
import { noSpeechInput } from "./local-fixture.ts";
import {
  applyOwnerOperation,
  ArchiveId,
  OwnerOperationId,
  OwnerVerifierSha256,
} from "./owner-state.ts";
import { productFetch } from "./product-handler.ts";

export interface LocalEnv {
  LOCAL_ARCHIVE: R2Bucket;
  CATALOG: D1Database;
  ARCHIVE_WORKFLOW: Workflow<{ runId: string }>;
  LOCAL_RUN_ID: string;
  LOCAL_ARCHIVE_ID: string;
  LOCAL_OWNER_VERIFIER: string;
}
const encodeRevision = Schema.encodeEffect(Schema.fromJsonString(TranscriptRevision));

const storeFixture = Effect.fn("LocalProbe.storeCanonicalRevision")(function* (
  env: LocalEnv,
  runId: string,
) {
  const revision = yield* fakeAsr.normalize(noSpeechInput);
  const bytes = yield* encodeRevision(revision);
  const key = `__local/probes/${runId}.json`;
  yield* Effect.promise(() => env.LOCAL_ARCHIVE.put(key, bytes));
  return { key, adapter: revision.asr.adapter };
});

/** Offline infrastructure acceptance only; never the product archive workflow. */
export class LocalProbeWorkflow extends WorkflowEntrypoint<LocalEnv, { runId: string }> {
  run(event: WorkflowEvent<{ runId: string }>, step: WorkflowStep) {
    return step.do("store-canonical-fake-revision", () =>
      Effect.runPromise(storeFixture(this.env, event.payload.runId)),
    );
  }
}

const initialize = Effect.fn("LocalWorker.initialize")(function* (env: LocalEnv) {
  yield* applyOwnerOperation(env.CATALOG, {
    kind: "initialize",
    operationId: OwnerOperationId.make(env.LOCAL_ARCHIVE_ID),
    archiveId: ArchiveId.make(env.LOCAL_ARCHIVE_ID),
    verifierSha256: OwnerVerifierSha256.make(env.LOCAL_OWNER_VERIFIER),
    now: "2026-09-07T00:00:00.000Z",
  });
});

const localProbe = Effect.fn("LocalWorker.probe")(function* (request: Request, env: LocalEnv) {
  const url = new URL(request.url);
  if (url.pathname === "/__local/health" && request.method === "GET") {
    yield* initialize(env);
    return Response.json({ mode: "local", asr: "fake", runId: env.LOCAL_RUN_ID });
  }
  // The opaque run capability gates local-only infrastructure actions, separate from owner APIs.
  if (
    url.pathname.startsWith("/__local/probe") &&
    request.headers.get("x-trigo-local-run") !== env.LOCAL_RUN_ID
  ) {
    return errorResponse(
      401,
      "local_probe_unauthorized",
      "after_correction",
      "Use the active local runner.",
    );
  }
  if (url.pathname === "/__local/probe" && request.method === "POST") {
    const instance = yield* Effect.promise(() =>
      env.ARCHIVE_WORKFLOW.create({ id: env.LOCAL_RUN_ID, params: { runId: env.LOCAL_RUN_ID } }),
    );
    return Response.json({ id: instance.id }, { status: 201 });
  }
  if (url.pathname === "/__local/probe" && request.method === "GET") {
    const instance = yield* Effect.promise(() => env.ARCHIVE_WORKFLOW.get(env.LOCAL_RUN_ID));
    return Response.json(yield* Effect.promise(() => instance.status()));
  }
  if (url.pathname === "/__local/probe/revision" && request.method === "GET") {
    const object = yield* Effect.promise(() =>
      env.LOCAL_ARCHIVE.get(`__local/probes/${env.LOCAL_RUN_ID}.json`),
    );
    return object
      ? new Response(object.body, { headers: { "content-type": "application/json" } })
      : new Response(null, { status: 404 });
  }
  return new Response(null, { status: request.method === "GET" ? 404 : 405 });
});

export default {
  fetch(request: Request, env: LocalEnv): Promise<Response> {
    if (new URL(request.url).pathname.startsWith("/v1/")) {
      return productFetch(request, {
        CATALOG: env.CATALOG,
        ARCHIVE: env.LOCAL_ARCHIVE,
        DEPLOYMENT_STAGE: "dev",
      });
    }
    return Effect.runPromise(localProbe(request, env));
  },
};
