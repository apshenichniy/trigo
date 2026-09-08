import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import {
  createUploadedCall,
  fixtureRuntime,
  requestProduct,
  resetTranscriptionFixture,
  speechRunner,
  transcriptionCommand,
} from "./transcription-fixture.ts";

beforeEach(resetTranscriptionFixture);

it("resumes an admitted replacement in the real Workflow after its intermediate history is cleared", async () => {
  const runtime = fixtureRuntime({
    run: async () => {
      throw new Error("original outcome unknown");
    },
  });
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const original = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, original.attempt_id));
  const failed = await Effect.runPromise(recoverTranscriptionAttempt(runtime, original.attempt_id));
  if (failed.state !== "failed") {
    throw new Error("Expected uncertain original");
  }
  await Effect.runPromise(failTranscriptionAttempt(runtime, original.attempt_id, failed, false));
  const recoveredRuntime = { ...runtime, AI: speechRunner() };
  const replacement = (await Effect.runPromise(
    admitTranscriptionAttempt(recoveredRuntime, command.operationId, 1),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(recoveredRuntime, replacement.attempt_id));
  // A fresh Workflow history models restart() after the replacement's raw write.
  const instance = await env.TRANSCRIPTION_WORKFLOW.create({
    id: command.operationId,
    params: { operationId: command.operationId },
  });
  await vi.waitFor(async () => expect((await instance.status()).status).toBe("complete"), {
    timeout: 5000,
    interval: 50,
  });
  const available = await Effect.runPromise(readTranscription(env.CATALOG, command.operationId));
  expect(available.state).toBe("result_available");
  const before = await (
    await requestProduct(runtime, `/v1/calls/${call.callId}/revisions/${command.revisionId}`)
  ).text();
  await instance.restart();
  await vi.waitFor(async () => expect((await instance.status()).status).toBe("complete"), {
    timeout: 5000,
    interval: 50,
  });
  expect(
    await (
      await requestProduct(runtime, `/v1/calls/${call.callId}/revisions/${command.revisionId}`)
    ).text(),
  ).toBe(before);
  expect(
    await env.CATALOG.prepare(
      "SELECT COUNT(*) AS count FROM trigo_transcription_attempts WHERE operation_id=?",
    )
      .bind(command.operationId)
      .first(),
  ).toEqual({ count: 2 });
  expect(recoveredRuntime.AI.run).toHaveBeenCalledTimes(1);
});

it("rejects altered retained audio-manifest bytes before a provider submission", async () => {
  const runtime = fixtureRuntime(speechRunner());
  const { call, uploadId } = await createUploadedCall(runtime);
  await env.CATALOG.prepare(
    "UPDATE trigo_master_finalizations SET audio_manifest=audio_manifest || ' ' WHERE upload_id=?",
  )
    .bind(uploadId)
    .run();
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id)),
  ).toMatchObject({
    state: "failed",
    code: "asr_catalog_invalid",
    retry: "after_correction",
  });
  expect(runtime.AI.run).not.toHaveBeenCalled();
});
