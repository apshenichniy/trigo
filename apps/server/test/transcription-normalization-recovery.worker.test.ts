import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import { fakeTranscriptionRunner } from "../src/fake-transcription.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import { recoverFailedNormalization } from "../src/transcription-results.ts";
import {
  createUploadedCall,
  fixtureRuntime,
  requestProduct,
  resetTranscriptionFixture,
  speechResponse,
  transcriptionCommand,
} from "./transcription-fixture.ts";

beforeEach(resetTranscriptionFixture);

async function retainedFailure() {
  const provider = {
    run: vi.fn(async (model: string, input: Record<string, unknown>) => {
      await fakeTranscriptionRunner.run(model, input);
      const response = speechResponse();
      for (const channel of response.results.channels) {
        channel.alternatives[0]!.words[1]!.start = 0.15;
        channel.alternatives[0]!.words[1]!.end = 1.2;
      }
      return Response.json(response);
    }),
  };
  const runtime = fixtureRuntime(provider);
  const { call } = await createUploadedCall(runtime);
  const command = transcriptionCommand();
  const path = `/v1/calls/${call.callId}/transcriptions`;
  await requestProduct(runtime, path, command);
  const attempt = (await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  ))!;
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  // Reproduce the durable terminal state written by the old strict normalizer.
  await Effect.runPromise(
    failTranscriptionAttempt(
      runtime,
      attempt.attempt_id,
      { code: "asr_result_invalid", retry: "after_correction" },
      true,
    ),
  );
  return { runtime, provider, call, command, path, attempt };
}

it("repairs the same failed command from retained evidence without provider or Workflow admission", async () => {
  const { runtime, provider, call, command, path } = await retainedFailure();
  const repaired = await requestProduct(runtime, path, command);
  expect(repaired.status).toBe(200);
  expect(await repaired.json()).toMatchObject({
    state: "result_available",
    operationId: command.operationId,
  });
  const result = await requestProduct(
    runtime,
    `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
  );
  const revision = validateDocument("TranscriptRevision", await result.json());
  expect(revision.normalizationVersion).toBe(2);
  expect(revision.turns[0]).toMatchObject({ endMs: 1000 });
  expect(revision.turns[0]?.words[1]).toMatchObject({
    startMs: 150,
    endMs: 1200,
    timingUncertain: true,
  });
  const published = await Effect.runPromise(
    readTranscription(runtime.CATALOG, command.operationId),
  );
  expect((await requestProduct(runtime, path, command)).status).toBe(200);
  expect(await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId))).toEqual(
    published,
  );
  expect(provider.run).toHaveBeenCalledTimes(1);
  expect(runtime.TRANSCRIPTION_WORKFLOW!.create).toHaveBeenCalledTimes(1);
  expect(
    (await runtime.CATALOG.prepare("SELECT attempt_id FROM trigo_transcription_attempts").all())
      .results,
  ).toHaveLength(1);
});

it("keeps repair failures terminal and reuses durable artifacts after interrupted publication", async () => {
  const { runtime, provider, command, path } = await retainedFailure();
  const prepare = runtime.CATALOG.prepare.bind(runtime.CATALOG);
  let interrupt = true;
  vi.spyOn(runtime.CATALOG, "prepare").mockImplementation((sql) => {
    if (interrupt && sql.includes("SET state='result_available'")) {
      interrupt = false;
      throw new Error("interrupted normalization repair publication");
    }
    return prepare(sql);
  });
  expect((await requestProduct(runtime, path, command)).status).toBe(503);
  expect(
    await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId)),
  ).toMatchObject({ state: "failed", result_key: null });
  expect(
    await Effect.runPromise(admitTranscriptionAttempt(runtime, command.operationId, 1)),
  ).toBeNull();
  const before = (
    await runtime.CATALOG.prepare(
      "SELECT writer_id,sha256 FROM trigo_transcription_writers ORDER BY writer_id",
    ).all()
  ).results;
  expect((await requestProduct(runtime, path, command)).status).toBe(200);
  expect(
    (
      await runtime.CATALOG.prepare(
        "SELECT writer_id,sha256 FROM trigo_transcription_writers ORDER BY writer_id",
      ).all()
    ).results,
  ).toEqual(before);
  expect(provider.run).toHaveBeenCalledTimes(1);
});

it.each(["owner", "deletion", "newer-operation", "newer-attempt"])(
  "retained normalization obeys the %s fence",
  async (kind) => {
    const { runtime, provider, command, path } = await retainedFailure();
    if (kind === "owner") {
      await runtime.CATALOG.prepare(
        "UPDATE trigo_owner_credential_state SET generation=generation+1",
      ).run();
    } else if (kind === "deletion") {
      await runtime.CATALOG.prepare(
        "UPDATE trigo_master_uploads SET deletion_state='fenced'",
      ).run();
    } else if (kind === "newer-operation") {
      await requestProduct(runtime, path, transcriptionCommand());
    } else {
      await runtime.CATALOG.prepare(`INSERT INTO trigo_transcription_attempts
        (attempt_id,operation_id,attempt_index,state,created_at)
        SELECT ?,operation_id,1,'admitted',created_at FROM trigo_transcription_operations`)
        .bind("00000000-0000-4000-8000-000000009901")
        .run();
    }
    const result = await Effect.runPromise(
      recoverFailedNormalization(runtime, command.operationId).pipe(Effect.result),
    );
    expect(result._tag).toBe("Failure");
    expect(
      await Effect.runPromise(readTranscription(runtime.CATALOG, command.operationId)),
    ).toMatchObject({ state: "failed", result_key: null });
    expect(provider.run).toHaveBeenCalledTimes(1);
    expect(
      (
        await runtime.CATALOG.prepare(
          "SELECT * FROM trigo_transcription_writers WHERE kind!='raw'",
        ).all()
      ).results,
    ).toEqual([]);
  },
);
