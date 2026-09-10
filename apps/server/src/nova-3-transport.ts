import { Effect, Schema, Stream } from "effect";

import type { AsrProbeLanguageCode } from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import type { Nova3Runner } from "./asr-probe.ts";

export class Nova3TransportError extends Schema.TaggedError<Nova3TransportError>()(
  "Nova3.TransportError",
  { operation: Schema.String, message: Schema.String },
) {}

/** Keep a bounded prefix and a truthful completion marker even if a response body fails. */
export const captureBoundedBody = Effect.fn("Nova3.captureBoundedBody")(function* (
  body: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
) {
  const failure = (message = "Body stream failed before EOF") =>
    new Nova3TransportError({
      operation: "readBody",
      message,
    });
  if (body === null) {
    return { bytes: new Uint8Array(), complete: false, problem: "Body is missing" };
  }
  const chunks: Uint8Array[] = [];
  let size = 0;
  const read = yield* Stream.fromReadableStream({
    evaluate: () => body,
    onError: () => failure(),
  }).pipe(
    Stream.runForEach((chunk) =>
      Effect.gen(function* () {
        const remaining = maximumBytes - size;
        if (chunk.byteLength > remaining) {
          chunks.push(new Uint8Array(chunk.subarray(0, remaining)));
          size += remaining;
          return yield* failure(
            `Body exceeds ${maximumBytes} bytes; retained bytes are only a prefix`,
          );
        }
        chunks.push(chunk);
        size += chunk.byteLength;
      }),
    ),
    Effect.result,
  );
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return {
    bytes,
    complete: read._tag === "Success",
    problem: read._tag === "Failure" ? read.failure.message : null,
  };
});

/** Controls and source ranges require all bytes; partial provider bodies are retained separately. */
export const readBoundedBody = Effect.fn("Nova3.readBoundedBody")(function* (
  body: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
) {
  const captured = yield* captureBoundedBody(body, maximumBytes);
  if (!captured.complete) {
    return yield* new Nova3TransportError({
      operation: "readBody",
      message: captured.problem ?? "Incomplete body",
    });
  }
  return captured.bytes;
});

/** A zero-prefetch delivery boundary distinguishes produced bytes from consumer-observed EOF. */
function observedRequestBody(source: ReadableStream<Uint8Array>, expectedBytes: number) {
  const reader = source.getReader();
  let deliveredBytes = 0;
  let reachedEnd = false;
  let cancelled = false;
  let released = false;
  const release = () => {
    if (!released) {
      released = true;
      reader.releaseLock();
    }
  };
  // oxlint-disable-next-line effecttsgo/async-function -- Native Web Streams cancellation owns this reader and must return a Promise to the platform.
  const cancel = async () => {
    if (released) {
      return;
    }
    cancelled = true;
    try {
      await reader.cancel();
    } finally {
      release();
    }
  };
  const body = new ReadableStream<Uint8Array>(
    {
      // oxlint-disable-next-line effecttsgo/async-function -- This demand-driven native callback must resolve only after one reader operation.
      async pull(controller) {
        try {
          const next = await reader.read();
          if (next.done) {
            reachedEnd = !cancelled;
            release();
            controller.close();
          } else {
            controller.enqueue(next.value);
            deliveredBytes += next.value.byteLength;
          }
        } catch (cause) {
          controller.error(cause);
        }
      },
      cancel,
    },
    { highWaterMark: 0 },
  );
  return {
    body,
    cancel,
    delivery: () => ({
      byteLength: deliveredBytes,
      complete: reachedEnd && !cancelled && deliveredBytes === expectedBytes,
    }),
  };
}

/** Own audio-stream lifetime and preserve acknowledged HTTP metadata even when body capture fails. */
export const submitNova3Stream = Effect.fn("Nova3.submitStream")(function* (
  ai: Nova3Runner,
  body: ReadableStream<Uint8Array>,
  contentType: string,
  language: AsrProbeLanguageCode,
  expectedByteLength: number,
) {
  return yield* Effect.acquireUseRelease(
    Effect.sync(() => observedRequestBody(body, expectedByteLength)),
    (observed) =>
      Effect.gen(function* () {
        const result = yield* Effect.tryPromise({
          try: (signal) =>
            ai.run(
              nova3StreamProfile.model,
              {
                audio: { body: observed.body, contentType },
                language,
                channels: nova3StreamProfile.channels,
                multichannel: nova3StreamProfile.multichannel,
                diarize: nova3StreamProfile.diarize,
                punctuate: nova3StreamProfile.punctuate,
                smart_format: nova3StreamProfile.smart_format,
              },
              { returnRawResponse: true, signal },
            ),
          catch: () =>
            new Nova3TransportError({
              operation: "submit",
              message: "Provider acknowledgement is unavailable; inference may have been billed",
            }),
        });
        if (!(result instanceof Response)) {
          return yield* new Nova3TransportError({
            operation: "submit",
            message: "Binding did not return the requested raw HTTP response",
          });
        }
        const status = result.status;
        const requestId = result.headers.get("cf-ai-req-id") ?? "";
        const captured = yield* captureBoundedBody(
          result.body,
          nova3StreamProfile.maxRawResponseBytes,
        );
        return {
          status,
          requestId,
          bytes: captured.bytes,
          responseBodyComplete: captured.complete,
          responseBodyProblem: captured.problem,
          requestBody: observed.delivery(),
        };
      }),
    (observed) =>
      Effect.tryPromise({
        try: () => observed.cancel(),
        catch: () =>
          new Nova3TransportError({ operation: "cancel", message: "Audio stream cleanup failed" }),
      }).pipe(Effect.ignore),
  );
});
