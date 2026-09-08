import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
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

it("releases a queued request whose admitting owner generation changed without authorizing its provider work", async () => {
  const runtime = fixtureRuntime(speechRunner());
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  await env.CATALOG.prepare(
    "UPDATE trigo_owner_credential_state SET generation=generation+1",
  ).run();
  expect(
    await Effect.runPromise(admitTranscriptionAttempt(runtime, command.operationId, 0)),
  ).toBeNull();
  expect(
    await Effect.runPromise(readTranscription(env.CATALOG, command.operationId)),
  ).toMatchObject({
    state: "failed",
    failure_code: "asr_owner_changed",
    failure_retry: "after_correction",
  });
  expect(runtime.AI.run).not.toHaveBeenCalled();
  const replacement = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/transcriptions`,
    transcriptionCommand(),
  );
  expect(replacement.status).toBe(200);
});

it("surfaces an interrupted Workflow without GET side effects and restarts the same command to recover retained evidence", async () => {
  const provider = speechRunner();
  const runtime = fixtureRuntime(provider);
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  const restart = vi.fn(async () => {});
  const workflow = {
    create: vi.fn(async () => {
      throw new Error("existing Workflow");
    }),
    get: vi.fn(async () => ({ status: async () => ({ status: "errored" }), restart })),
  };
  const interrupted = { ...runtime, TRANSCRIPTION_WORKFLOW: workflow };
  const polled = await requestProduct(interrupted, `/v1/operations/${command.operationId}`);
  expect(validateDocument("TranscriptionOperation", await polled.json())).toMatchObject({
    state: "running",
    attemptCount: 1,
    failure: { code: "asr_workflow_interrupted", retry: "retryable" },
  });
  expect(workflow.create).not.toHaveBeenCalled();
  expect(restart).not.toHaveBeenCalled();
  const resumed = await requestProduct(
    interrupted,
    `/v1/calls/${call.callId}/transcriptions`,
    command,
  );
  expect(resumed.status).toBe(200);
  expect(workflow.get).toHaveBeenLastCalledWith(command.operationId);
  expect(restart).toHaveBeenCalledTimes(1);
  // Replaying the durable work after restart recovers the first attempt's exact raw result.
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id))).toEqual(
    { state: "result_available" },
  );
  expect(provider.run).toHaveBeenCalledTimes(1);
});

it.each(["paused", "terminated"])(
  "does not undo an operator's %s Workflow state",
  async (status) => {
    const runtime = fixtureRuntime(speechRunner());
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
    const restart = vi.fn(async () => {});
    const controlled = {
      ...runtime,
      TRANSCRIPTION_WORKFLOW: {
        create: vi.fn(async () => {
          throw new Error("existing Workflow");
        }),
        get: vi.fn(async () => ({ status: async () => ({ status }), restart })),
      },
    };
    const polled = await requestProduct(controlled, `/v1/operations/${command.operationId}`);
    expect(validateDocument("TranscriptionOperation", await polled.json()).failure).toMatchObject({
      code: "asr_workflow_stopped",
      retry: "after_correction",
    });
    const repeated = await requestProduct(
      controlled,
      `/v1/calls/${call.callId}/transcriptions`,
      command,
    );
    expect(repeated.status).toBe(409);
    expect(restart).not.toHaveBeenCalled();
    expect(runtime.AI.run).not.toHaveBeenCalled();
  },
);
