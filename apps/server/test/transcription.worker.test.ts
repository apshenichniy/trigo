import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { parseStored, storedByteHash, validateDocument } from "@trigo/contracts";

import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
  failTranscriptionAttempt,
  recoverTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { readTranscription } from "../src/transcription-catalog.ts";
import { recoverAndPublishTranscription } from "../src/transcription-results.ts";
import { inspectTranscriptionWriters } from "../src/transcription-writers.ts";
import { fenceMasterUploads } from "../src/upload-catalog.ts";
import {
  createUploadedCall,
  fixtureRuntime,
  owner,
  requestProduct,
  resetTranscriptionFixture,
  speechRunner,
  transcriptionCommand,
} from "./transcription-fixture.ts";

beforeEach(resetTranscriptionFixture);

describe("durable transcription requests and immutable results", () => {
  it("admits concurrent duplicate commands once and never starts processing from polling", async () => {
    const provider = speechRunner();
    const runtime = fixtureRuntime(provider);
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    const path = `/v1/calls/${call.callId}/transcriptions`;
    const responses = await Promise.all([
      requestProduct(runtime, path, command),
      requestProduct(runtime, path, command),
    ]);
    const operations = await Promise.all(
      responses.map(async (response) => {
        expect(response.status).toBe(200);
        return validateDocument("TranscriptionOperation", await response.json());
      }),
    );
    expect(operations[0]).toEqual(operations[1]);
    expect(operations[0]).toMatchObject({
      operationId: command.operationId,
      state: "queued",
      attemptCount: 0,
      result: null,
    });
    const dispatched = vi.mocked(runtime.TRANSCRIPTION_WORKFLOW!.create).mock.calls.length;
    for (let i = 0; i < 3; i++) {
      expect((await requestProduct(runtime, `/v1/operations/${command.operationId}`)).status).toBe(
        200,
      );
    }
    expect(runtime.TRANSCRIPTION_WORKFLOW!.create).toHaveBeenCalledTimes(dispatched);
    expect(provider.run).not.toHaveBeenCalled();
    const conflict = await requestProduct(runtime, path, transcriptionCommand());
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toMatchObject({ error: { code: "asr_already_processing" } });
    const changed = await requestProduct(runtime, path, { ...command, requestedLanguage: "ru" });
    expect(changed.status).toBe(409);
    expect(await changed.json()).toMatchObject({ error: { code: "asr_conflict" } });
  });

  it("publishes exact immutable bytes only after raw evidence and provenance are retained", async () => {
    const provider = speechRunner();
    const runtime = fixtureRuntime(provider);
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    expect(
      (await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command)).status,
    ).toBe(200);
    const attempt = await Effect.runPromise(
      admitTranscriptionAttempt(runtime, command.operationId, 0),
    );
    expect(attempt).not.toBeNull();
    await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt!.attempt_id));
    await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt!.attempt_id));
    expect(provider.run).toHaveBeenCalledTimes(1);
    const available = await Effect.runPromise(
      recoverAndPublishTranscription(runtime, command.operationId, attempt!),
    );
    const again = await Effect.runPromise(
      recoverAndPublishTranscription(runtime, command.operationId, attempt!),
    );
    expect(again).toEqual(available);
    expect(available.state).toBe("result_available");
    const response = await requestProduct(
      runtime,
      `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
    );
    expect(response.status).toBe(200);
    const bytes = new Uint8Array(await response.arrayBuffer());
    expect(await storedByteHash(bytes)).toBe(available.result_sha256);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    const revision = parseStored("TranscriptRevision", bytes);
    expect(revision.turns.map((turn) => turn.text).sort()).toEqual([
      "Hello application.",
      "Hello microphone.",
    ]);
    for (const track of call.tracks) {
      expect(revision.turns.find((turn) => turn.trackId === track.trackId)?.text).toBe(
        `Hello ${track.role}.`,
      );
    }
    expect(new Set(revision.speakers.map((speaker) => speaker.diarizationScopeId)).size).toBe(2);
    expect(new Set(revision.speakers.map((speaker) => speaker.trackId)).size).toBe(2);
    const writers = await Effect.runPromise(
      inspectTranscriptionWriters(runtime, command.operationId),
    );
    expect(writers.map((writer) => writer.kind).sort()).toEqual(["provenance", "raw", "revision"]);
    expect(writers.every((writer) => writer.state === "stored")).toBe(true);
    for (const table of [
      "trigo_transcription_operations",
      "trigo_transcription_attempts",
      "trigo_asr_submissions",
      "trigo_transcription_writers",
    ]) {
      expect(
        JSON.stringify((await env.CATALOG.prepare(`SELECT * FROM ${table}`).all()).results),
      ).not.toContain("Hello");
    }
  });

  it("recovers a raw R2 write after its acknowledgement is lost without another provider call", async () => {
    const provider = speechRunner();
    const runtime = fixtureRuntime(provider);
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
    const attempt = (await Effect.runPromise(
      admitTranscriptionAttempt(runtime, command.operationId, 0),
    ))!;
    const actualPut = runtime.ARCHIVE.put.bind(runtime.ARCHIVE);
    let lost = false;
    const put = vi.spyOn(runtime.ARCHIVE, "put").mockImplementation(async (key, body, options) => {
      const stored = await actualPut(key, body, options);
      if (key.includes("/raw/") && !lost) {
        lost = true;
        throw new Error("lost raw acknowledgement");
      }
      return stored;
    });
    await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
    await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
    expect(
      await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id)),
    ).toEqual({ state: "result_available" });
    expect(provider.run).toHaveBeenCalledTimes(1);
    expect(put.mock.calls.filter(([key]) => key.includes("/raw/"))).toHaveLength(1);
  });

  it("persists the two-attempt ceiling through uncertain submissions and process replay", async () => {
    const provider = {
      run: vi.fn(async () => {
        throw new Error("provider acknowledgement lost");
      }),
    };
    const runtime = fixtureRuntime(provider);
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
    for (const index of [0, 1] as const) {
      const attempt = (await Effect.runPromise(
        admitTranscriptionAttempt(runtime, command.operationId, index),
      ))!;
      await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
      await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
      const recovered = await Effect.runPromise(
        recoverTranscriptionAttempt(runtime, attempt.attempt_id),
      );
      expect(recovered).toMatchObject({
        state: "failed",
        code: "asr_submission_uncertain",
        retry: "retryable",
      });
      if (recovered.state === "failed") {
        await Effect.runPromise(
          failTranscriptionAttempt(runtime, attempt.attempt_id, recovered, index === 1),
        );
      }
    }
    expect(provider.run).toHaveBeenCalledTimes(2);
    expect(
      await Effect.runPromise(admitTranscriptionAttempt(runtime, command.operationId, 1)),
    ).toBeNull();
    const operation = validateDocument(
      "TranscriptionOperation",
      await (await requestProduct(runtime, `/v1/operations/${command.operationId}`)).json(),
    );
    expect(operation).toMatchObject({
      state: "failed",
      attemptCount: 2,
      result: null,
      failure: { code: "asr_attempt_limit" },
    });
    const writers = await Effect.runPromise(
      inspectTranscriptionWriters(runtime, command.operationId),
    );
    expect(writers).toHaveLength(2);
    expect(writers.every((writer) => writer.state === "admitted" && writer.sha256 === null)).toBe(
      true,
    );
  });

  it("rejects publication after the call is fenced and retains admitted artifacts for draining", async () => {
    const runtime = fixtureRuntime(speechRunner());
    const { call } = await createUploadedCall(runtime);
    const command = transcriptionCommand();
    await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
    const attempt = (await Effect.runPromise(
      admitTranscriptionAttempt(runtime, command.operationId, 0),
    ))!;
    await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
    await Effect.runPromise(fenceMasterUploads(env.CATALOG, owner.archiveId, call.callId));
    const failure = await Effect.runPromise(
      recoverAndPublishTranscription(runtime, command.operationId, attempt).pipe(Effect.result),
    );
    expect(failure).toMatchObject({ _tag: "Failure", failure: { code: "call_deleted" } });
    expect(
      (await Effect.runPromise(readTranscription(env.CATALOG, command.operationId))).result_key,
    ).toBeNull();
    const writers = await Effect.runPromise(
      inspectTranscriptionWriters(runtime, command.operationId),
    );
    expect(writers).toHaveLength(1);
    expect(writers[0]).toMatchObject({ kind: "raw", state: "stored" });
  });

  it.each([0, 1000])(
    "publishes a valid empty revision for %i ms of no-speech input",
    async (duration) => {
      const runtime = fixtureRuntime();
      const provider = vi.spyOn(runtime.AI, "run");
      const { call } = await createUploadedCall(runtime, duration);
      const command = transcriptionCommand();
      await requestProduct(runtime, `/v1/calls/${call.callId}/transcriptions`, command);
      const attempt = (await Effect.runPromise(
        admitTranscriptionAttempt(runtime, command.operationId, 0),
      ))!;
      await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
      expect(
        await Effect.runPromise(recoverTranscriptionAttempt(runtime, attempt.attempt_id)),
      ).toEqual({ state: "result_available" });
      const response = await requestProduct(
        runtime,
        `/v1/calls/${call.callId}/revisions/${command.revisionId}`,
      );
      const revision = validateDocument("TranscriptRevision", await response.json());
      expect(revision.speakers).toEqual([]);
      expect(revision.turns).toEqual([]);
      expect(provider).toHaveBeenCalledTimes(duration === 0 ? 0 : 1);
    },
  );
});
