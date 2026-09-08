import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { fakeTranscriptionRunner } from "../src/fake-transcription.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import { inspectTranscriptionWriters } from "../src/transcription-writers.ts";
import {
  createUploadedCall,
  fixtureRuntime,
  requestProduct,
  resetTranscriptionFixture,
  speechResponse,
  speechRunner,
  transcriptionCommand,
} from "./transcription-fixture.ts";

beforeEach(resetTranscriptionFixture);

it("retains a response admitted before owner rotation but rejects publication under the old generation", async () => {
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  const provider = {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      await fakeTranscriptionRunner.run(model, input);
      started.resolve();
      await release.promise;
      return Response.json(speechResponse());
    }),
  };
  const runtime = fixtureRuntime(provider);
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  const execution = Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  await started.promise;
  await env.CATALOG.prepare(
    "UPDATE trigo_owner_credential_state SET generation=generation+1",
  ).run();
  release.resolve();
  await execution;
  const recovered = await Effect.runPromise(
    recoverTranscriptionAttempt(runtime, attempt.attempt_id),
  );
  expect(recovered).toMatchObject({
    state: "failed",
    code: "asr_owner_changed",
    retry: "after_correction",
  });
  expect(
    (await Effect.runPromise(readTranscription(env.CATALOG, command.operationId))).result_key,
  ).toBeNull();
  expect(
    (await Effect.runPromise(inspectTranscriptionWriters(runtime, command.operationId))).map(
      (writer) => [writer.kind, writer.state],
    ),
  ).toEqual([["raw", "stored"]]);
  expect(provider.run).toHaveBeenCalledTimes(1);
});

it("keeps the replacement revision immutable when the original provider response arrives late", async () => {
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  let calls = 0;
  const provider = {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      const original = ++calls === 1;
      await fakeTranscriptionRunner.run(model, input);
      if (original) {
        started.resolve();
        await release.promise;
      }
      const response = speechResponse();
      response.metadata.request_id = original ? "late-original" : "current-replacement";
      return Response.json(response);
    }),
  };
  const runtime = fixtureRuntime(provider);
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const original = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  const inFlight = Effect.runPromise(executeTranscriptionAttempt(runtime, original.attempt_id));
  await started.promise;
  await Effect.runPromise(
    failTranscriptionAttempt(
      runtime,
      original.attempt_id,
      { code: "asr_submission_uncertain", retry: "retryable" },
      false,
    ),
  );
  const replacement = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 1),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, replacement.attempt_id));
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, replacement.attempt_id)),
  ).toEqual({ state: "result_available" });
  const published = await Effect.runPromise(readTranscription(env.CATALOG, command.operationId));
  release.resolve();
  await inFlight;
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, original.attempt_id)),
  ).toEqual({ state: "result_available" });
  expect(await Effect.runPromise(readTranscription(env.CATALOG, command.operationId))).toEqual(
    published,
  );
  expect(provider.run).toHaveBeenCalledTimes(2);
});

it("keeps a previous successful revision available when a later logical request fails", async () => {
  const runtime = fixtureRuntime(speechRunner());
  const { call } = await createUploadedCall(runtime);
  const first = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, first);
  const success = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, first.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, success.attempt_id));
  await Effect.runPromise(recoverTranscriptionAttempt(runtime, success.attempt_id));
  const before = await (
    await requestProduct(runtime, `/v1/calls/${call.callId}/revisions/${first.revisionId}`)
  ).text();
  const failedRuntime = {
    ...runtime,
    AI: { run: async () => Response.json({ error: "bad configuration" }, { status: 401 }) },
  };
  const next = transcriptionCommand();
  await requestProduct(failedRuntime, `/v1/calls/${call.callId}/transcriptions`, next);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(failedRuntime, next.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(failedRuntime, attempt.attempt_id));
  const failed = await Effect.runPromise(
    recoverTranscriptionAttempt(failedRuntime, attempt.attempt_id),
  );
  if (failed.state !== "failed") {
    throw new Error("Expected controlled failure");
  }
  await Effect.runPromise(
    failTranscriptionAttempt(failedRuntime, attempt.attempt_id, failed, true),
  );
  expect(
    await (
      await requestProduct(runtime, `/v1/calls/${call.callId}/revisions/${first.revisionId}`)
    ).text(),
  ).toBe(before);
  expect(
    (await Effect.runPromise(readTranscription(env.CATALOG, next.operationId))).result_key,
  ).toBeNull();
});
