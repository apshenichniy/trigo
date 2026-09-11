/* oxlint-disable effecttsgo/async-function -- Probe the production Web Stream bridge inside workerd. */
import { Effect, Option, Stream } from "effect";
import { expect, it } from "vitest";

import { assemblyAIClient, type AssemblyAIUploadEvent } from "../src/assemblyai-client.ts";

it.each([0, 1])(
  "drains an Effect source through the upload adapter (highWaterMark=%i)",
  async (highWaterMark) => {
    let produced = 0;
    let received = 0;
    const source = Stream.range(0, 3).pipe(
      Stream.mapEffect(() =>
        Effect.sync(() => {
          produced++;
          return new Uint8Array(16384);
        }),
      ),
    );
    const body = await Effect.runPromise(
      Stream.toReadableStreamEffect(source, { strategy: { highWaterMark } }),
    );
    const client = assemblyAIClient("fixture", async (_url, init) => {
      received = (await new Response(init.body).arrayBuffer()).byteLength;
      return Response.json({ upload_url: "https://cdn.eu.assemblyai.com/upload/fixture" });
    });
    await Effect.runPromise(client.upload(body, 4 * 16384));
    expect({ produced, received }).toEqual({ produced: 4, received: 4 * 16384 });
  },
  2500,
);

it("distinguishes a complete request body from waiting for provider response headers", async () => {
  const events: string[] = [];
  const details: AssemblyAIUploadEvent[] = [];
  const bodyComplete = Promise.withResolvers<void>();
  const providerResponse = Promise.withResolvers<Response>();
  const client = assemblyAIClient(
    "fixture",
    async (_url, init) => {
      expect((await new Response(init.body).arrayBuffer()).byteLength).toBe(65536);
      return providerResponse.promise;
    },
    (event) => {
      events.push(event.stage);
      details.push(event);
      if (event.stage === "body_complete") {
        bodyComplete.resolve();
      }
    },
  );
  const body = await Effect.runPromise(
    Stream.toReadableStreamEffect(Stream.make(new Uint8Array(65536)), {
      strategy: { highWaterMark: 0 },
    }),
  );
  const upload = Effect.runPromise(client.upload(body, 65536));
  await bodyComplete.promise;
  expect(events).toEqual(["start", "request", "body_complete"]);
  providerResponse.resolve(
    Response.json({ upload_url: "https://cdn.eu.assemblyai.com/upload/fixture" }),
  );
  await upload;
  expect(events).toEqual(["start", "request", "body_complete", "response", "transport_complete"]);
  for (const event of details) {
    expect(
      Object.keys(event).every((key) =>
        ["stage", "elapsedMs", "expectedBytes", "status"].includes(key),
      ),
    ).toBe(true);
    expect(event.expectedBytes).toBe(65536);
    expect(event.elapsedMs).toBeGreaterThanOrEqual(0);
  }
});

it("keeps the upload intact when a diagnostic observer throws", async () => {
  const body = await Effect.runPromise(
    Stream.toReadableStreamEffect(Stream.make(new Uint8Array(64))),
  );
  const client = assemblyAIClient(
    "fixture",
    async (_url, init) => {
      expect((await new Response(init.body).arrayBuffer()).byteLength).toBe(64);
      return Response.json({ upload_url: "https://cdn.eu.assemblyai.com/upload/fixture" });
    },
    () => {
      throw new Error("Diagnostic observer unavailable");
    },
  );
  expect(await Effect.runPromise(client.upload(body, 64))).toBe(
    "https://cdn.eu.assemblyai.com/upload/fixture",
  );
});

it.each(["throw", "reject", "redirect", "configuration"])(
  "cancels the source promptly when transport fails before consuming it (%s)",
  async (failure) => {
    let finalized = false;
    const source = Stream.range(0, 100).pipe(
      Stream.map(() => new Uint8Array(16384)),
      Stream.ensuring(
        Effect.sync(() => {
          finalized = true;
        }),
      ),
    );
    const body = await Effect.runPromise(
      Stream.toReadableStreamEffect(source, { strategy: { highWaterMark: 0 } }),
    );
    const client = assemblyAIClient("fixture", (_url, init) => {
      if (failure === "throw") {
        throw new Error("Transport unavailable");
      }
      if (failure === "reject") {
        return Promise.reject(new Error("Transport unavailable"));
      }
      if (failure === "redirect") {
        return Promise.resolve(new Response(null, { status: 302 }));
      }
      // Reproduce workerd detaching the request body before rejecting unsupported options.
      return fetch("https://assemblyai-upload-fixture.invalid", { ...init, redirect: "error" });
    });
    expect((await Effect.runPromise(Effect.result(client.upload(body, 65536))))._tag).toBe(
      "Failure",
    );
    await expect.poll(() => finalized).toBe(true);
  },
  2500,
);

it("uploads a paginated source through workerd native fetch", async () => {
  const source = Stream.concat(
    Stream.make(new Uint8Array(44)),
    Stream.paginate(0, (page) =>
      Effect.succeed([
        [new Uint8Array(16384)],
        page === 3 ? Option.none<number>() : Option.some(page + 1),
      ] as const),
    ),
  );
  const body = await Effect.runPromise(
    Stream.toReadableStreamEffect(source, { strategy: { highWaterMark: 0 } }),
  );
  const client = assemblyAIClient("fixture", (_url, init) =>
    fetch("https://assemblyai-upload-fixture.invalid", init),
  );
  expect(await Effect.runPromise(client.upload(body, 65580))).toBe(
    "https://cdn.eu.assemblyai.com/upload/fixture-65580",
  );
}, 2500);

it("uses a workerd-supported redirect policy for job requests", async () => {
  const client = assemblyAIClient("fixture", (_url, init) =>
    fetch("https://assemblyai-upload-fixture.invalid", init),
  );
  expect((await Effect.runPromise(client.get("fixture-id"))).complete).toBe(true);
});

it.each([63, 65])(
  "rejects a native upload whose source length is %i instead of 64",
  async (actual) => {
    const body = await Effect.runPromise(
      Stream.toReadableStreamEffect(Stream.make(new Uint8Array(actual))),
    );
    const client = assemblyAIClient("fixture", (_url, init) =>
      fetch("https://assemblyai-upload-fixture.invalid", init),
    );
    expect(await Effect.runPromise(Effect.result(client.upload(body, 64)))).toMatchObject({
      _tag: "Failure",
      failure: { code: "asr_provider_unavailable" },
    });
  },
  2500,
);
