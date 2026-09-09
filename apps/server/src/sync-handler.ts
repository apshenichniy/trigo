import { Effect, Schema } from "effect";
import { HttpServerResponse } from "effect/unstable/http";
import { HttpApiBuilder } from "effect/unstable/httpapi";

import { CanonicalSync } from "./canonical-sync.ts";
import { errorEnvelope } from "./http-errors.ts";
import { readBoundedBody } from "./nova-3-transport.ts";
import { ProductApi } from "./product-api.ts";
import { maximumCallDocumentBytes } from "./replica-documents.ts";
import { syncError, type SyncError } from "./sync-errors.ts";

const response = <A, R>(effect: Effect.Effect<A, SyncError, R>) =>
  effect.pipe(
    Effect.catchTag("Sync.Error", (error) =>
      Effect.succeed(
        HttpServerResponse.jsonUnsafe(errorEnvelope(error.code, error.retry, error.message), {
          status: error.status,
        }),
      ),
    ),
  );

const replicaRequest = Effect.fn("SyncHandler.replicaRequest")(function* (request: Request) {
  if (
    request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json"
  ) {
    return yield* syncError("sync_invalid");
  }
  // Escaping a valid JSON document string and its declared annotation scopes adds envelope
  // bytes. The separately enforced document limit is on exact stored UTF-8 evidence.
  const bytes = yield* readBoundedBody(request.body, maximumCallDocumentBytes * 3).pipe(
    Effect.mapError(() => syncError("sync_document_too_large", 413)),
  );
  const text = yield* Effect.try({
    try: () => new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    catch: () => syncError("sync_invalid"),
  });
  return yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(text).pipe(
    Effect.mapError(() => syncError("sync_invalid")),
  );
});

const retainedResponse = (value: { bytes: Uint8Array; sha256: string }) =>
  HttpServerResponse.uint8Array(value.bytes, {
    headers: {
      "content-type": "application/json",
      "cache-control": "private, no-store",
      "content-length": String(value.bytes.byteLength),
      etag: `"${value.sha256}"`,
      "x-trigo-content-sha256": value.sha256,
    },
  });

export const syncHandlers = (request: Request) =>
  HttpApiBuilder.group(
    ProductApi,
    "sync",
    Effect.fn(function* (group) {
      const sync = yield* CanonicalSync;
      return group
        .handleRaw("publishReplica", ({ params }) =>
          response(
            replicaRequest(request).pipe(
              Effect.flatMap((input) => sync.publish(params.callId, input)),
            ),
          ),
        )
        .handleRaw("canonicalReplica", ({ params, query }) =>
          response(
            sync.document(params.callId, query.documentVersion).pipe(Effect.map(retainedResponse)),
          ),
        )
        .handleRaw("storedAudioManifest", ({ params }) =>
          response(sync.audioManifest(params.callId).pipe(Effect.map(retainedResponse))),
        )
        .handle("callCatalog", ({ query }) => response(sync.catalog(query.cursor)))
        .handle("callChanges", ({ query }) => response(sync.changes(query.cursor)))
        .handle("transcriptResults", ({ params, query }) =>
          response(sync.results(params.callId, query.cursor)),
        );
    }),
  );

export function isSyncRoute(request: Request) {
  const path = new URL(request.url).pathname;
  return (
    (request.method === "PUT" && /^\/v1\/calls\/[^/]+\/document$/.test(path)) ||
    (request.method === "GET" &&
      (path === "/v1/calls" ||
        path === "/v1/changes" ||
        /^\/v1\/calls\/[^/]+\/(?:document|audio-manifest|results)$/.test(path)))
  );
}
