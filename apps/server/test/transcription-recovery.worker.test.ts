import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { fakeTranscriptionRunner } from "../src/fake-transcription.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import { recoverAndPublishTranscription } from "../src/transcription-results.ts";
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

it("recovers after immutable writes but before publication without changing revision identity or bytes", async () => {
  const provider = speechRunner();
  const runtime = fixtureRuntime(provider);
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  const prepare = runtime.CATALOG.prepare.bind(runtime.CATALOG);
  let crash = true;
  vi.spyOn(runtime.CATALOG, "prepare").mockImplementation((sql) => {
    if (crash && sql.includes("SET state='result_available'")) {
      crash = false;
      throw new Error("crash before catalog publication");
    }
    return prepare(sql);
  });
  expect(
    await Effect.runPromise(
      recoverAndPublishTranscription(runtime, command.operationId, attempt).pipe(Effect.result),
    ),
  ).toMatchObject({ _tag: "Failure", failure: { code: "asr_storage_unavailable" } });
  const before = await Effect.runPromise(inspectTranscriptionWriters(runtime, command.operationId));
  expect(before).toHaveLength(3);
  const available = await Effect.runPromise(
    recoverAndPublishTranscription(runtime, command.operationId, attempt),
  );
  const after = await Effect.runPromise(inspectTranscriptionWriters(runtime, command.operationId));
  expect(after).toEqual(before);
  expect(available.result_sha256).toBe(before.find((writer) => writer.kind === "revision")!.sha256);
  expect(provider.run).toHaveBeenCalledTimes(1);
});

it("recovers a retained response when persisting its normalized-readiness marker fails", async () => {
  const provider = speechRunner();
  const runtime = fixtureRuntime(provider);
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  const prepare = runtime.CATALOG.prepare.bind(runtime.CATALOG);
  let crash = true;
  vi.spyOn(runtime.CATALOG, "prepare").mockImplementation((sql) => {
    if (crash && sql.includes("UPDATE trigo_asr_submissions SET state='retained'")) {
      crash = false;
      throw new Error("lost catalog write");
    }
    return prepare(sql);
  });
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id))).toEqual(
    { state: "result_available" },
  );
  expect(provider.run).toHaveBeenCalledTimes(1);
});

it.each([
  [401, "asr_configuration"],
  [402, "asr_funds"],
  [422, "asr_input_rejected"],
] as const)(
  "classifies provider HTTP %i as actionable correction without automatic replacement",
  async (status, code) => {
    const provider = {
      run: vi.fn(async (model: string, input: Record<string, unknown>) => {
        await fakeTranscriptionRunner.run(model, input);
        return Response.json({ error: "controlled provider rejection" }, { status });
      }),
    };
    const runtime = fixtureRuntime(provider);
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
    const attempt = (await Effect.runPromise(
      admitTranscriptionAttempt(runtime, command.operationId, 0),
    ))!;
    await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
    const recovered = await Effect.runPromise(
      recoverTranscriptionAttempt(runtime, attempt.attempt_id),
    );
    expect(recovered).toMatchObject({ state: "failed", code, retry: "after_correction" });
    if (recovered.state === "failed") {
      await Effect.runPromise(
        failTranscriptionAttempt(runtime, attempt.attempt_id, recovered, true),
      );
    }
    expect(
      await Effect.runPromise(admitTranscriptionAttempt(runtime, command.operationId, 1)),
    ).toBeNull();
    expect(provider.run).toHaveBeenCalledTimes(1);
  },
);

it("never normalizes a partial input or a truncated provider result", async () => {
  for (const kind of ["input-not-consumed", "response-truncated"] as const) {
    const provider = {
      run: vi.fn(async (model: string, input: Record<string, unknown>) => {
        if (kind === "input-not-consumed") {
          return Response.json(speechResponse());
        }
        await fakeTranscriptionRunner.run(model, input);
        return new Response(new Uint8Array(nova3StreamProfile.maxRawResponseBytes + 1).fill(32));
      }),
    };
    const runtime = fixtureRuntime(provider);
    const { call } = await createUploadedCall(runtime);
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
      code: kind === "input-not-consumed" ? "asr_submission_uncertain" : "asr_result_too_large",
    });
    expect(
      (await Effect.runPromise(readTranscription(env.CATALOG, command.operationId))).result_key,
    ).toBeNull();
    const writers = await Effect.runPromise(
      inspectTranscriptionWriters(runtime, command.operationId),
    );
    expect(writers).toHaveLength(1);
    expect(writers[0]!.byte_length).toBeLessThanOrEqual(nova3StreamProfile.maxRawResponseBytes);
  }
});

it("rejects unsupported language and unknown execution options before admitting work", async () => {
  const runtime = fixtureRuntime(speechRunner());
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  const unsupported = await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, {
    ...command,
    requestedLanguage: "uk",
  });
  expect(unsupported.status).toBe(422);
  expect(await unsupported.json()).toMatchObject({
    error: { code: "asr_language_unsupported", retry: "after_correction" },
  });
  const arbitrary = await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, {
    ...command,
    model: "anything",
  });
  expect(arbitrary.status).toBe(400);
  expect(runtime.TRANSCRIPTION_WORKFLOW!.create).not.toHaveBeenCalled();
  expect(runtime.AI.run).not.toHaveBeenCalled();
  expect(
    (await env.CATALOG.prepare("SELECT * FROM trigo_transcription_operations").all()).results,
  ).toEqual([]);
});

it("runs the real local product Workflow and exposes only the independently available result", async () => {
  const runtime = {
    ...fixtureRuntime(),
    TRANSCRIPTION_MODE: "fake" as const,
    TRANSCRIPTION_WORKFLOW: env.TRANSCRIPTION_WORKFLOW,
  };
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  const started = await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  expect(started.status).toBe(200);
  await vi.waitFor(
    async () => {
      const operation = await Effect.runPromise(
        readTranscription(env.CATALOG, command.operationId),
      );
      expect(operation.state).toBe("result_available");
    },
    { timeout: 5000, interval: 50 },
  );
  const instance = await env.TRANSCRIPTION_WORKFLOW.get(command.operationId);
  await vi.waitFor(async () => expect((await instance.status()).status).toBe("complete"), {
    timeout: 5000,
    interval: 50,
  });
  expect((await instance.status()).output).toEqual({
    operationId: command.operationId,
    state: "result_available",
  });
  const response = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
  );
  expect(validateDocument("TranscriptRevision", await response.json()).asr.adapter).toBe("fake");
});
