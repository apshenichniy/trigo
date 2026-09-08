import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import { fakeTranscriptionRunner } from "../src/fake-transcription.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { attemptSubmissions } from "../src/transcription-submissions.ts";
import {
  fixtureRuntime,
  requestProduct,
  resetTranscriptionFixture,
  speechResponse,
  transcriptionCommand,
} from "./transcription-fixture.ts";
import { createVirtualLongCall } from "./transcription-long-fixture.ts";

beforeEach(resetTranscriptionFixture);

it("reuses a successful two-hour interval and replaces only the uncertain hour while keeping repeated voices and labels independently scoped", async () => {
  let invocation = 0;
  const provider = {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      const current = ++invocation;
      await fakeTranscriptionRunner.run(model, input);
      if (current === 2) {
        throw new Error("second interval acknowledgement lost");
      }
      const response = speechResponse();
      response.metadata.duration = current === 1 ? 7200 : 3600;
      response.metadata.request_id = `independent-provider-${current}`;
      // The local voice repeats; the remote voice changes. Both provider responses reuse 0.
      response.results.channels[0]!.alternatives[0]!.words[1]!.word = "same-local-voice";
      response.results.channels[1]!.alternatives[0]!.words[1]!.word =
        current === 1 ? "remote-alpha" : "remote-beta";
      return Response.json(response);
    }),
  };
  const runtime = fixtureRuntime(provider);
  const { call } = await createVirtualLongCall(runtime);
  const command = transcriptionCommand();
  await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
  const original = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, original.attempt_id));
  const failure = await Effect.runPromise(
    recoverTranscriptionAttempt(runtime, original.attempt_id),
  );
  expect(failure).toMatchObject({ state: "failed", retry: "retryable" });
  if (failure.state !== "failed") {
    throw new Error("Missing uncertain interval");
  }
  await Effect.runPromise(failTranscriptionAttempt(runtime, original.attempt_id, failure, false));
  const replacement = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 1),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, replacement.attempt_id));
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, replacement.attempt_id)),
  ).toEqual({ state: "result_available" });
  const firstPlan = await Effect.runPromise(attemptSubmissions(runtime, original.attempt_id));
  const secondPlan = await Effect.runPromise(attemptSubmissions(runtime, replacement.attempt_id));
  expect(secondPlan[0]!.submission_id).toBe(firstPlan[0]!.submission_id);
  expect(secondPlan[1]!.submission_id).not.toBe(firstPlan[1]!.submission_id);
  expect(provider.run).toHaveBeenCalledTimes(3);
  const result = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
  );
  const revision = validateDocument("TranscriptRevision", await result.json());
  expect(revision.turns).toHaveLength(4);
  expect(revision.turns.map((turn) => turn.startMs)).toEqual([100, 100, 7_200_100, 7_200_100]);
  expect(revision.speakers.every((speaker) => speaker.providerLabel === "0")).toBe(true);
  expect(new Set(revision.speakers.map((speaker) => speaker.diarizationScopeId)).size).toBe(4);
  expect(new Set(revision.speakers.map((speaker) => speaker.speakerId)).size).toBe(4);
  const late = await Effect.runPromise(recoverTranscriptionAttempt(runtime, original.attempt_id));
  expect(late).toEqual({ state: "result_available" });
  expect(
    await env.CATALOG.prepare(
      "SELECT state FROM trigo_transcription_operations WHERE operation_id=?",
    )
      .bind(command.operationId)
      .first(),
  ).toEqual({ state: "result_available" });
}, 30_000);

it("rejects an incomplete reported interval before paying for its sibling", async () => {
  const provider = {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      await fakeTranscriptionRunner.run(model, input);
      return Response.json(speechResponse()); // Reports one second for the two-hour submission.
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
  expect(
    await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id)),
  ).toMatchObject({
    state: "failed",
    code: "asr_result_invalid",
    retry: "after_correction",
  });
  expect(provider.run).toHaveBeenCalledTimes(1);
}, 30_000);
