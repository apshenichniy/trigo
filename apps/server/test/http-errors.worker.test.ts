import { afterAll, describe, expect, it } from "vitest";
import { Effect, Layer, Schema } from "effect";
import { HttpRouter, HttpServer, HttpServerResponse } from "effect/unstable/http";
import { HttpApi, HttpApiBuilder, HttpApiEndpoint, HttpApiGroup } from "effect/unstable/httpapi";
import { validateDocument } from "@trigo/contracts";
import { httpErrorBoundary } from "../src/http-errors.ts";

// Narrow transport fixture: the supported status route has no request body to decode.
// It uses the exact production response boundary; these routes are never shipped.
const Payload = Schema.Struct({ count: Schema.Finite }).annotate({
  parseOptions: { onExcessProperty: "error" },
});
const Api = HttpApi.make("transport-fixture").add(
  HttpApiGroup.make("fixture").add(
    HttpApiEndpoint.post("decode", "/decode", { payload: Payload, success: Payload }),
    HttpApiEndpoint.get("invalidResponse", "/invalid-response", {
      success: Schema.Finite.check(Schema.isGreaterThan(0)),
    }),
    HttpApiEndpoint.post("bytes", "/bytes", { success: Schema.Uint8Array }),
  ),
);
const handlers = HttpApiBuilder.group(Api, "fixture", (group) =>
  group
    .handle("decode", ({ payload }) => Effect.succeed(payload))
    .handle("invalidResponse", () => Effect.succeed(-1))
    .handleRaw("bytes", ({ request }) =>
      request.arrayBuffer.pipe(
        Effect.map((bytes) => HttpServerResponse.uint8Array(new Uint8Array(bytes))),
        Effect.orDie,
      ),
    ),
);
const app = HttpRouter.toWebHandler(
  HttpApiBuilder.layer(Api).pipe(
    Layer.provide(handlers),
    Layer.provide(httpErrorBoundary),
    Layer.provide(HttpServer.layerServices),
  ),
  { disableLogger: true },
);
afterAll(() => app.dispose());

describe("shared HttpApi envelope boundary in workerd", () => {
  it.each([
    ["{", "application/json", 400, "request_invalid"],
    ["", "application/json", 400, "request_invalid"],
    ['{"count":"wrong"}', "application/json", 400, "request_invalid"],
    ['{"count":1,"extra":true}', "application/json", 400, "request_invalid"],
    ['{"count":1}', "text/plain", 415, "unsupported_content_type"],
  ])("maps %s / %s to %i %s", async (body, contentType, status, code) => {
    const response = await app.handler(
      new Request("http://localhost/decode", {
        method: "POST",
        headers: { "content-type": String(contentType) },
        body: String(body),
      }),
    );
    expect(response.status).toBe(status);
    expect(validateDocument("ErrorEnvelope", await response.json())).toMatchObject({
      error: { code, retry: "after_correction" },
    });
  });
  it("treats a server response encoding defect as retryable 500, not invalid client input", async () => {
    const response = await app.handler(new Request("http://localhost/invalid-response"));
    expect(response.status).toBe(500);
    expect(validateDocument("ErrorEnvelope", await response.json())).toMatchObject({
      error: { code: "response_invalid", retry: "retryable" },
    });
  });
  it("preserves accepted JSON behavior and raw immutable bytes", async () => {
    const response = await app.handler(
      new Request("http://localhost/decode", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: '{"count":7}',
      }),
    );
    expect(await response.json()).toEqual({ count: 7 });
    const bytes = new TextEncoder().encode(' { "immutable" : 1 }\n');
    const raw = await app.handler(
      new Request("http://localhost/bytes", {
        method: "POST",
        headers: { "content-type": "application/octet-stream" },
        body: bytes,
      }),
    );
    expect(new Uint8Array(await raw.arrayBuffer())).toEqual(bytes);
  });
});
