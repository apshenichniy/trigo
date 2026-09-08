import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { parseStored } from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { fakeTranscriptionRunner } from "../src/fake-transcription.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import {
  fixtureRuntime,
  requestProduct,
  resetTranscriptionFixture,
  transcriptionCommand,
} from "./transcription-fixture.ts";
import { createVirtualLongCall } from "./transcription-long-fixture.ts";

beforeEach(resetTranscriptionFixture);

it("retains and normalizes dense multi-megabyte provider evidence through R2 with compact durable operation state", async () => {
  const rawSizes: number[] = [];
  let invocation = 0;
  const provider = {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      const durationMs = ++invocation === 1 ? 7_200_000 : 3_600_000;
      await fakeTranscriptionRunner.run(model, input);
      const channels = [0, 1].map(() => ({
        alternatives: [
          {
            words: Array.from({ length: 16_000 }, (_, index) => {
              const text = `provider-token-${String(index).padStart(5, "0")}-${"x".repeat(25)}`;
              const startMs = Math.floor((index * durationMs) / 16_000);
              return {
                word: text,
                punctuated_word: text,
                start: startMs / 1000,
                end: (startMs + 10) / 1000,
                speaker: Math.floor(index / 100) % 2,
                confidence: 0.91,
              };
            }),
          },
        ],
      }));
      const bytes = new TextEncoder().encode(
        JSON.stringify({
          metadata: { duration: durationMs / 1000, channels: 2 },
          results: { channels },
        }),
      );
      rawSizes.push(bytes.byteLength);
      expect(bytes.byteLength).toBeGreaterThan(4_000_000);
      expect(bytes.byteLength).toBeLessThan(nova3StreamProfile.maxRawResponseBytes);
      return new Response(bytes);
    }),
  };
  const runtime = fixtureRuntime(provider);
  const { call } = await createVirtualLongCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id))).toEqual(
    { state: "result_available" },
  );
  const operation = await Effect.runPromise(readTranscription(env.CATALOG, command.operationId));
  expect(JSON.stringify(operation).length).toBeLessThan(2500);
  const submissions = (await env.CATALOG.prepare("SELECT * FROM trigo_asr_submissions").all())
    .results;
  expect(JSON.stringify(submissions).length).toBeLessThan(6000);
  const result = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
  );
  const bytes = new Uint8Array(await result.arrayBuffer());
  const revision = parseStored("TranscriptRevision", bytes);
  expect(revision.turns.reduce((count, turn) => count + turn.words.length, 0)).toBe(64_000);
  expect(provider.run).toHaveBeenCalledTimes(2);
  expect(rawSizes).toHaveLength(2);
  await Effect.runPromise(
    Effect.logInfo(
      JSON.stringify({
        evidence: "dense-transcription-result",
        rawByteLengths: rawSizes,
        revisionByteLength: bytes.byteLength,
        provenanceByteLength: operation.provenance_byte_length,
        words: 64_000,
        operationMetadataBytes: JSON.stringify(operation).length,
      }),
    ),
  );
}, 60_000);
