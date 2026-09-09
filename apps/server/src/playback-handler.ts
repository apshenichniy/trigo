import { Effect, Layer, Schema } from "effect";
import { HttpRouter, HttpServer, HttpServerResponse } from "effect/unstable/http";
import { HttpApiBuilder } from "effect/unstable/httpapi";

import { errorEnvelope, httpErrorBoundary } from "./http-errors.ts";
import { readBoundedBody } from "./nova-3-transport.ts";
import { type PlaybackEnvironment } from "./playback-catalog.ts";
import { type PlaybackError, playbackError } from "./playback-errors.ts";
import { PlaybackGrants } from "./playback-grants.ts";
import { PlaybackMedia, type PlaybackSegment, playbackMediaLayer } from "./playback-media.ts";
import { PlaybackMediaApi, ProductApi } from "./product-api.ts";

const privateHeaders = { "cache-control": "private, no-store", vary: "Authorization" };
const response = <A, R>(effect: Effect.Effect<A, PlaybackError, R>) =>
  effect.pipe(
    Effect.catchTag("Playback.Error", (error) =>
      Effect.succeed(
        HttpServerResponse.jsonUnsafe(errorEnvelope(error.code, error.retry, error.message), {
          status: error.status,
          headers: {
            ...privateHeaders,
            ...(error.totalByteLength === undefined
              ? {}
              : { "content-range": `bytes */${error.totalByteLength}` }),
          },
        }),
      ),
    ),
  );
const requestBody = Effect.fn("PlaybackHandler.requestBody")(function* (request: Request) {
  if (
    request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json"
  ) {
    return yield* playbackError("playback_invalid");
  }
  const bytes = yield* readBoundedBody(request.body, 4096).pipe(
    Effect.mapError(() => playbackError("playback_invalid")),
  );
  const json = yield* Effect.try({
    try: () => new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    catch: () => playbackError("playback_invalid"),
  });
  return yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(json).pipe(
    Effect.mapError(() => playbackError("playback_invalid")),
  );
});

export function playbackGrantHandlers(request: Request) {
  return HttpApiBuilder.group(
    ProductApi,
    "playbackGrants",
    Effect.fn(function* (group) {
      const service = yield* PlaybackGrants;
      return group.handleRaw("requestPlayback", ({ params }) =>
        response(
          requestBody(request).pipe(
            Effect.flatMap((body) => service.request(params.callId, body)),
            Effect.map((grant) =>
              HttpServerResponse.jsonUnsafe(grant, { headers: privateHeaders }),
            ),
          ),
        ),
      );
    }),
  );
}

const segmentResponse = (segment: PlaybackSegment) =>
  HttpServerResponse.uint8Array(segment.bytes, {
    status: segment.byteRange.partial ? 206 : 200,
    headers: {
      ...privateHeaders,
      "content-type": "audio/wav",
      "content-length": String(segment.bytes.byteLength),
      "accept-ranges": "bytes",
      "x-trigo-content-sha256": segment.sha256,
      "x-trigo-start-frame": String(segment.startFrame),
      "x-trigo-frame-count": String(segment.frameCount),
      ...(segment.byteRange.partial
        ? {
            "content-range": `bytes ${segment.byteRange.start}-${segment.byteRange.start + segment.byteRange.length - 1}/${segment.totalByteLength}`,
          }
        : {}),
    },
  });

export const playbackMediaResponse = Effect.fn("PlaybackHandler.mediaResponse")(function* (
  request: Request,
  env: PlaybackEnvironment,
) {
  const handlers = HttpApiBuilder.group(
    PlaybackMediaApi,
    "playbackMedia",
    Effect.fn(function* (group) {
      const service = yield* PlaybackMedia;
      return group.handleRaw("segment", ({ params }) =>
        response(
          service
            .segment(
              params.callId,
              params.grantId,
              params.index,
              request.headers.get("authorization"),
              request.headers.get("range"),
            )
            .pipe(Effect.map(segmentResponse)),
        ),
      );
    }),
  );
  const routes = HttpApiBuilder.layer(PlaybackMediaApi).pipe(
    Layer.provide(handlers.pipe(Layer.provide(playbackMediaLayer(env)))),
    Layer.provide(httpErrorBoundary),
    Layer.provide(HttpServer.layerServices),
  );
  return yield* Effect.acquireUseRelease(
    Effect.sync(() => HttpRouter.toWebHandler(routes, { disableLogger: true })),
    ({ handler }) => Effect.promise(() => handler(request)),
    ({ dispose }) => Effect.promise(dispose),
  );
});

export function isPlaybackGrantRoute(request: Request) {
  return (
    request.method === "POST" &&
    /^\/v1\/calls\/[^/]+\/playback$/.test(new URL(request.url).pathname)
  );
}
export function isPlaybackMediaRoute(request: Request) {
  return (
    request.method === "GET" &&
    /^\/v1\/calls\/[^/]+\/playback\/[^/]+\/segments\/[^/]+$/.test(new URL(request.url).pathname)
  );
}
