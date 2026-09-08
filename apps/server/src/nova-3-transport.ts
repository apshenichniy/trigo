import { Effect, Schema, Stream } from "effect";

import type { AsrProbeLanguageCode } from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import type { Nova3Runner } from "./asr-probe.ts";

export class Nova3TransportError extends Schema.TaggedError<Nova3TransportError>()(
  "Nova3.TransportError",
  { operation: Schema.String, message: Schema.String },
) {}

/** Bound every materialized provider/control response, independently from streamed audio. */
export const readBoundedBody = Effect.fn("Nova3.readBoundedBody")(function* (
  body: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
) {
  const failure = () =>
    new Nova3TransportError({
      operation: "readBody",
      message: "Body is missing, unreadable, or exceeds its byte limit",
    });
  if (body === null) {
    return yield* failure();
  }
  const chunks: Uint8Array[] = [];
  let size = 0;
  yield* Stream.fromReadableStream({ evaluate: () => body, onError: failure }).pipe(
    Stream.runForEach((chunk) =>
      Effect.gen(function* () {
        size += chunk.byteLength;
        if (size > maximumBytes) {
          return yield* failure();
        }
        chunks.push(chunk);
      }),
    ),
  );
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
});

/** A stream selects workerd's binary transport; base64 selects its different JSON transport. */
export const submitNova3Stream = Effect.fn("Nova3.submitStream")(function* (
  ai: Nova3Runner,
  body: ReadableStream<Uint8Array>,
  contentType: string,
  language: AsrProbeLanguageCode,
) {
  const result = yield* Effect.tryPromise({
    try: (signal) =>
      ai.run(
        nova3StreamProfile.model,
        {
          audio: { body, contentType },
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
  return result;
});
