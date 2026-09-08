import { Effect, Schema, Stream } from "effect";

import { type Nova3Runner } from "./asr-probe.ts";
import { transcriptionError } from "./transcription-errors.ts";

const StreamBody = Schema.declare(
  (value): value is ReadableStream<Uint8Array> => value instanceof ReadableStream,
);
const FakeInput = Schema.Struct({ audio: Schema.Struct({ body: StreamBody }) });

const fakeSubmission = Effect.fn("Transcription.fakeSubmission")(function* (input: unknown) {
  const value = yield* Schema.decodeUnknownEffect(FakeInput)(input).pipe(
    Effect.mapError(() => transcriptionError("asr_invalid")),
  );
  // Consume the exact production stream and exercise its consumer EOF witness without an AI binding.
  yield* Stream.fromReadableStream({
    evaluate: () => value.audio.body,
    onError: () => transcriptionError("asr_input_rejected"),
  }).pipe(Stream.runDrain);
  return Response.json(
    {
      results: {
        channels: [
          { alternatives: [{ transcript: "", words: [] }] },
          { alternatives: [{ transcript: "", words: [] }] },
        ],
      },
    },
    { headers: { "cf-ai-req-id": "offline-fake" } },
  );
});

export const fakeTranscriptionRunner: Nova3Runner = {
  run: (_model, input) => Effect.runPromise(fakeSubmission(input)),
};
