// oxlint-disable effecttsgo/async-function -- These Promise-based AI binding fakes exercise native Web Streams consumption and cancellation boundaries.
import { expect, it } from "@effect/vitest";
import { Effect, Stream } from "effect";
import { vi } from "vitest";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { submitNova3Stream } from "../src/nova-3-transport.ts";

function audioBody(input: Record<string, unknown>): ReadableStream<Uint8Array> {
  const audio = input.audio;
  if (
    typeof audio !== "object" ||
    audio === null ||
    !("body" in audio) ||
    !(audio.body instanceof ReadableStream)
  ) {
    throw new Error("The binding requires binary streamed audio");
  }
  return audio.body;
}

it.effect(
  "requires consumer EOF even when every byte is already produced or the final block is prefetched",
  () =>
    Effect.gen(function* () {
      for (const reads of [0, 1, 2]) {
        let cleaned = false;
        const stream = Stream.concat(
          Stream.make(new Uint8Array(44)),
          Stream.make(new Uint8Array(64_000)),
        ).pipe(
          Stream.ensuring(
            Effect.sync(() => {
              cleaned = true;
            }),
          ),
        );
        const input = yield* Stream.toReadableStreamEffect(stream);
        const run = vi.fn(async (_model: string, values: Record<string, unknown>) => {
          const reader = audioBody(values).getReader();
          for (let index = 0; index < reads; index += 1) {
            await reader.read();
          }
          reader.releaseLock();
          return Response.json({ results: { channels: [] } });
        });
        const result = yield* submitNova3Stream({ run }, input, "audio/wav", "en", 64_044);
        expect(result.requestBody.complete).toBe(false);
        expect(result.requestBody.byteLength).toBe([0, 44, 64_044][reads]);
        expect(cleaned).toBe(true);
      }
    }),
);

it.effect(
  "records complete local delivery only after consuming EOF and cleans up a rejected invocation",
  () =>
    Effect.gen(function* () {
      let cancelled = 0;
      const rejected = new ReadableStream<Uint8Array>(
        {
          cancel() {
            cancelled += 1;
          },
        },
        { highWaterMark: 0 },
      );
      const unavailable = yield* Effect.result(
        submitNova3Stream(
          { run: vi.fn().mockRejectedValue(new Error("No acknowledgement")) },
          rejected,
          "audio/wav",
          "en",
          64,
        ),
      );
      expect(unavailable._tag).toBe("Failure");
      expect(cancelled).toBe(1);

      const run = vi.fn(async (_model: string, values: Record<string, unknown>) => {
        await new Response(audioBody(values)).arrayBuffer();
        return Response.json({ results: { channels: [] } });
      });
      const body = Stream.toReadableStream(Stream.make(new Uint8Array(44), new Uint8Array(64_000)));
      const completed = yield* submitNova3Stream({ run }, body, "audio/wav", "en", 64_044);
      expect(completed.requestBody).toEqual({ byteLength: 64_044, complete: true });
    }),
);

it.effect("does not count a pending chunk when cancellation closes the delivery boundary", () =>
  Effect.gen(function* () {
    const pulled = Promise.withResolvers<ReadableStreamDefaultController<Uint8Array>>();
    const source = new ReadableStream<Uint8Array>(
      { pull: (controller) => pulled.resolve(controller) },
      { highWaterMark: 0 },
    );
    const run = vi.fn(async (_model: string, values: Record<string, unknown>) => {
      const reader = audioBody(values).getReader();
      const pending = reader.read();
      const controller = await pulled.promise;
      controller.enqueue(new Uint8Array(64));
      await Promise.all([pending, reader.cancel()]);
      reader.releaseLock();
      return Response.json({ results: { channels: [] } });
    });
    const result = yield* submitNova3Stream({ run }, source, "audio/wav", "en", 64);
    expect(result.requestBody).toEqual({ byteLength: 0, complete: false });
  }),
);

it.effect(
  "retains acknowledged status, request identity and available body prefix when response streaming fails",
  () =>
    Effect.gen(function* () {
      let pulls = 0;
      const run = vi.fn(async (_model: string, values: Record<string, unknown>) => {
        await new Response(audioBody(values)).arrayBuffer();
        return new Response(
          new ReadableStream<Uint8Array>(
            {
              pull(controller) {
                if (pulls++ === 0) {
                  controller.enqueue(new TextEncoder().encode('{"results":'));
                } else {
                  controller.error(new Error("Provider response connection interrupted"));
                }
              },
            },
            { highWaterMark: 0 },
          ),
          { status: 200, headers: { "cf-ai-req-id": "ack-before-body-failure" } },
        );
      });
      const result = yield* submitNova3Stream(
        { run },
        Stream.toReadableStream(Stream.make(new Uint8Array(64))),
        "audio/wav",
        "en",
        64,
      );
      expect(result.status).toBe(200);
      expect(result.requestId).toBe("ack-before-body-failure");
      expect(result.responseBodyComplete).toBe(false);
      expect(new TextDecoder().decode(result.bytes)).toBe('{"results":');
      expect(result.responseBodyProblem).toBe("Body stream failed before EOF");
    }),
);

it.effect("distinguishes the local response cap from an unknown provider acknowledgement", () =>
  Effect.gen(function* () {
    const run = vi.fn(async (_model: string, values: Record<string, unknown>) => {
      await new Response(audioBody(values)).arrayBuffer();
      return new Response(new Uint8Array(nova3StreamProfile.maxRawResponseBytes + 1), {
        status: 200,
        headers: { "cf-ai-req-id": "bounded-response" },
      });
    });
    const result = yield* submitNova3Stream(
      { run },
      Stream.toReadableStream(Stream.make(new Uint8Array(64))),
      "audio/wav",
      "en",
      64,
    );
    expect(result.bytes.byteLength).toBe(nova3StreamProfile.maxRawResponseBytes);
    expect(result.responseBodyComplete).toBe(false);
    expect(result.requestId).toBe("bounded-response");
    expect(result.responseBodyProblem).toContain("only a prefix");
  }),
);
