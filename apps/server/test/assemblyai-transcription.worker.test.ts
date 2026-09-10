/* oxlint-disable effecttsgo/async-function -- Integration tests exercise real D1/R2 with a disposable HTTP provider double. */
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import { cleanupAssemblyAIResults } from "../src/assemblyai-submissions.ts";
import { assemblyAIWorkflow } from "../src/assemblyai-workflow.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import { transcriptionError } from "../src/transcription-errors.ts";
import { recoverFailedNormalization } from "../src/transcription-results.ts";
import { attemptSubmissions } from "../src/transcription-submissions.ts";
import type { TranscriptionWorkflowStep } from "../src/transcription-workflow-steps.ts";
import { inspectTranscriptionWriters } from "../src/transcription-writers.ts";
import {
  assemblyAIBytes,
  assemblyAICommand,
  assemblyAIFixture,
  assemblyAIResponse,
} from "./assemblyai-fixture.ts";
import {
  createUploadedCall,
  requestProduct,
  resetTranscriptionFixture,
} from "./transcription-fixture.ts";
import { createVirtualLongCall } from "./transcription-long-fixture.ts";

beforeEach(resetTranscriptionFixture);

it("reuses a retained two-hour interval and replaces only the failed final hour", async () => {
  const { client, runtime } = assemblyAIFixture();
  const { call } = await createVirtualLongCall(runtime);
  const command = assemblyAICommand();
  client.get.mockImplementation((id) =>
    Effect.succeed(
      assemblyAIBytes({
        ...assemblyAIResponse(id, id === "provider-2" ? "error" : "completed"),
        audio_duration: id === "provider-1" ? 7200 : 3600,
      }),
    ),
  );
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  expect(
    await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step)),
  ).toMatchObject({ state: "result_available" });
  const attempts = await runtime.CATALOG.prepare(
    "SELECT attempt_id FROM trigo_transcription_attempts WHERE operation_id=? ORDER BY attempt_index",
  )
    .bind(command.operationId)
    .all<{ attempt_id: string }>();
  const first = await Effect.runPromise(
    attemptSubmissions(runtime, attempts.results[0]!.attempt_id),
  );
  const second = await Effect.runPromise(
    attemptSubmissions(runtime, attempts.results[1]!.attempt_id),
  );
  expect(first[0]?.submission_id).toBe(second[0]?.submission_id);
  expect(first[1]?.submission_id).not.toBe(second[1]?.submission_id);
  const response = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
  );
  const revision = validateDocument("TranscriptRevision", await response.json());
  expect(revision.turns.map((turn) => turn.startMs)).toEqual([100, 400, 7_200_100, 7_200_400]);
  expect(new Set(revision.speakers.map((speaker) => speaker.diarizationScopeId)).size).toBe(4);
  expect(client.submit).toHaveBeenCalledTimes(3);
  expect(client.upload).toHaveBeenCalledTimes(3);
  expect(client.delete).toHaveBeenCalledTimes(3);
}, 30_000);

async function started() {
  const fixture = assemblyAIFixture();
  const { call } = await createUploadedCall(fixture.runtime);
  const command = assemblyAICommand();
  const response = await requestProduct(
    fixture.runtime,
    `/v1/calls/${call.callId}/transcriptions`,
    command,
  );
  expect(response.status).toBe(200);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(fixture.runtime, command.operationId, 0),
  ))!;
  return { ...fixture, call, command, attempt };
}

function steps() {
  const sleep = vi.fn<TranscriptionWorkflowStep["sleep"]>(async () => {});
  const step: TranscriptionWorkflowStep = { do: (_name, _config, callback) => callback(), sleep };
  return { step, sleep };
}

it("retains and publishes one stereo result and replays without another upload or POST", async () => {
  const { client, runtime, call, command, attempt } = await started();
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id))).toEqual(
    { state: "result_available" },
  );
  const response = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
  );
  const revision = validateDocument("TranscriptRevision", await response.json());
  expect(revision.asr).toMatchObject({
    adapter: "assemblyai",
    model: "universal-2",
    profileId: command.profileId,
  });
  expect(revision.turns.map((turn) => turn.text)).toEqual(["Hello.", "Reply."]);
  expect(revision.speakers).toHaveLength(2);
  expect(client.upload).toHaveBeenCalledTimes(1);
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.get).toHaveBeenCalledTimes(1);
  await Effect.runPromise(cleanupAssemblyAIResults(runtime, command.operationId));
  await Effect.runPromise(cleanupAssemblyAIResults(runtime, command.operationId));
  expect(client.delete).toHaveBeenCalledExactlyOnceWith("provider-1");
});

it("waits durably for processing and resumes the admitted job on workflow replay", async () => {
  const { client, runtime, command } = await started();
  client.get
    .mockReturnValueOnce(
      Effect.succeed(assemblyAIBytes(assemblyAIResponse("provider-1", "processing"))),
    )
    .mockReturnValueOnce(
      Effect.succeed(assemblyAIBytes(assemblyAIResponse("provider-1", "processing"))),
    );
  const { step, sleep } = steps();
  expect(
    await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, step)),
  ).toMatchObject({ state: "result_available" });
  expect(sleep).toHaveBeenCalledWith("assemblyai-wait-0-0", "30 seconds");
  await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, step));
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.upload).toHaveBeenCalledTimes(1);
  expect(client.delete).toHaveBeenCalledTimes(1);
});

it("recovers a lost POST acknowledgment by exact upload lookup without a second paid admission", async () => {
  const { client, runtime, attempt } = await started();
  client.submit.mockReturnValueOnce(Effect.fail(transcriptionError("asr_admission_uncertain")));
  client.find.mockReturnValueOnce(Effect.succeed(null));
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id))).toEqual(
    { state: "pending" },
  );
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id))).toEqual(
    { state: "result_available" },
  );
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.upload).toHaveBeenCalledTimes(1);
  expect(client.find).toHaveBeenCalledWith(assemblyAIResponse().audio_url);
});

it("limits definite provider failures to the original and one replacement", async () => {
  const { client, runtime, command } = await started();
  client.get.mockImplementation((id) =>
    Effect.succeed(
      assemblyAIBytes({ ...assemblyAIResponse(id, "error"), error: "Provider processing failed" }),
    ),
  );
  expect(
    await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step)),
  ).toMatchObject({ state: "failed" });
  expect(
    await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId)),
  ).toMatchObject({ failure_code: "asr_attempt_limit" });
  await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step));
  expect(client.submit).toHaveBeenCalledTimes(2);
  expect(client.upload).toHaveBeenCalledTimes(2);
  expect(client.delete).toHaveBeenCalledTimes(2);
});

it.each(["asr_configuration", "asr_funds", "asr_input_rejected"] as const)(
  "stops on %s without replacement",
  async (code) => {
    const { client, runtime, command } = await started();
    client.submit.mockReturnValue(Effect.fail(transcriptionError(code)));
    expect(
      await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step)),
    ).toMatchObject({ state: "failed" });
    expect(
      await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId)),
    ).toMatchObject({ failure_code: code });
    expect(client.submit).toHaveBeenCalledTimes(1);
  },
);

it("retains malformed provider evidence before refusing publication and cleanup", async () => {
  const { client, runtime, command, attempt } = await started();
  client.get.mockReturnValue(
    Effect.succeed({ bytes: new TextEncoder().encode("broken JSON"), complete: true }),
  );
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id)),
  ).toMatchObject({ state: "failed", code: "asr_result_invalid" });
  const writers = await Effect.runPromise(
    inspectTranscriptionWriters(runtime, command.operationId),
  );
  expect(writers).toHaveLength(1);
  expect(writers[0]).toMatchObject({ kind: "raw", state: "stored", byte_length: 11 });
  await Effect.runPromise(cleanupAssemblyAIResults(runtime, command.operationId));
  expect(client.delete).toHaveBeenCalledTimes(1);
});

it("repairs failed normalization from retained bytes with no provider access", async () => {
  const { client, runtime, command, attempt } = await started();
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  await Effect.runPromise(
    failTranscriptionAttempt(
      runtime,
      attempt.attempt_id,
      { code: "asr_result_invalid", retry: "after_correction" },
      true,
    ),
  );
  const unavailable = () => Effect.fail(transcriptionError("asr_configuration"));
  client.upload.mockImplementation(unavailable);
  client.submit.mockImplementation(unavailable);
  client.get.mockImplementation(unavailable);
  client.find.mockImplementation(unavailable);
  client.delete.mockImplementation(unavailable);
  await Effect.runPromise(recoverFailedNormalization(runtime, command.operationId));
  expect(
    await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId)),
  ).toMatchObject({ state: "result_available" });
  expect(client.get).toHaveBeenCalledTimes(1);
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.delete).not.toHaveBeenCalled();
});

it("keeps available bytes readable while failed provider deletion is retried separately", async () => {
  const { client, runtime, call, command } = await started();
  client.delete.mockReturnValueOnce(
    Effect.fail(transcriptionError("asr_cleanup_pending", "retryable", 503)),
  );
  expect(
    await Effect.runPromise(
      assemblyAIWorkflow(runtime, command.operationId, steps().step).pipe(Effect.result),
    ),
  ).toMatchObject({ _tag: "Failure", failure: { code: "asr_cleanup_pending" } });
  expect(
    (await requestProduct(runtime, `/v1/calls/${call.callId}/revisions/${command.revisionId}`))
      .status,
  ).toBe(200);
  const restart = vi.fn(async () => {});
  const interrupted = {
    ...runtime,
    TRANSCRIPTION_WORKFLOW: {
      create: vi.fn(async () => {
        throw new Error("exists");
      }),
      get: vi.fn(async () => ({ status: async () => ({ status: "errored" }), restart })),
    },
  };
  await requestProduct(interrupted, `/v1/calls/${call.callId}/transcriptions`, command);
  expect(restart).toHaveBeenCalledTimes(1);
  await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step));
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.delete).toHaveBeenCalledTimes(2);
});

it("fences paid admission when the owner changes during upload", async () => {
  const { client, runtime, attempt } = await started();
  const original = client.upload.getMockImplementation()!;
  client.upload.mockImplementation((body, length) =>
    original(body, length).pipe(
      Effect.tap(() =>
        Effect.promise(() =>
          runtime.CATALOG.prepare(
            "UPDATE trigo_owner_credential_state SET generation=generation+1",
          ).run(),
        ),
      ),
    ),
  );
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(client.upload).toHaveBeenCalledTimes(1);
  expect(client.submit).not.toHaveBeenCalled();
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id)),
  ).toMatchObject({ state: "failed", code: "asr_owner_changed" });
});

it("recovers an upload whose acknowledgment was not persisted without duplicating paid work", async () => {
  const { client, runtime, command, attempt } = await started();
  const prepare = runtime.CATALOG.prepare.bind(runtime.CATALOG);
  let crash = true;
  vi.spyOn(runtime.CATALOG, "prepare").mockImplementation((sql) => {
    if (crash && sql.includes("SET phase='uploaded'")) {
      crash = false;
      throw new Error("crashed before upload acknowledgment commit");
    }
    return prepare(sql);
  });
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  expect(client.submit).not.toHaveBeenCalled();
  await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step));
  expect(client.upload).toHaveBeenCalledTimes(2);
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.get).toHaveBeenCalledWith("provider-2");
});

it("retains the active attempt when admission remains unknown and resumes lookup on the same command", async () => {
  const { client, runtime, command } = await started();
  client.submit.mockReturnValueOnce(Effect.fail(transcriptionError("asr_admission_uncertain")));
  client.find.mockReturnValue(Effect.succeed(null));
  expect(
    await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step)),
  ).toMatchObject({ state: "running", waitingExpired: true });
  expect(
    await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId)),
  ).toMatchObject({ state: "running", failure_code: "asr_admission_uncertain" });
  client.find.mockReturnValue(Effect.succeed("provider-1"));
  expect(
    await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step)),
  ).toMatchObject({ state: "result_available" });
  expect(client.upload).toHaveBeenCalledTimes(1);
  expect(client.submit).toHaveBeenCalledTimes(1);
}, 30_000);

it("cleans up a known provider job cancelled by an owner fence before result retention", async () => {
  const { client, runtime, command } = await started();
  const submit = client.submit.getMockImplementation()!;
  client.submit.mockImplementation((url, language) =>
    submit(url, language).pipe(
      Effect.tap(() =>
        Effect.promise(() =>
          runtime.CATALOG.prepare(
            "UPDATE trigo_owner_credential_state SET generation=generation+1",
          ).run(),
        ),
      ),
    ),
  );
  expect(
    await Effect.runPromise(assemblyAIWorkflow(runtime, command.operationId, steps().step)),
  ).toMatchObject({ state: "failed" });
  expect(client.submit).toHaveBeenCalledTimes(1);
  expect(client.get).not.toHaveBeenCalled();
  expect(client.delete).toHaveBeenCalledExactlyOnceWith("provider-1");
});
