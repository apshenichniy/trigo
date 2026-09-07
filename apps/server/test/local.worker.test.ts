import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { expect, it } from "vitest";

import { validateDocument } from "@trigo/contracts";

import { fakeAsr } from "../src/asr.ts";
import { noSpeechInput } from "../src/local-fixture.ts";
import localWorker from "../src/local-worker.ts";

it("persists exact canonical fake adapter bytes in the real local R2 binding", async () => {
  const revision = await Effect.runPromise(fakeAsr.normalize(noSpeechInput));
  const bytes = new TextEncoder().encode(JSON.stringify(revision));
  await env.LOCAL_ARCHIVE.put("offline-adapter.json", bytes);
  const object = await env.LOCAL_ARCHIVE.get("offline-adapter.json");
  expect(new Uint8Array(await object!.arrayBuffer())).toEqual(bytes);
  expect(
    validateDocument("TranscriptRevision", JSON.parse(new TextDecoder().decode(bytes))),
  ).toEqual(revision);
});
it("denies external service access in the Workers runtime", async () => {
  expect((await fetch("https://api.cloudflare.com")).status).toBe(403);
});
it("does not ship the old fixture API or cloud-only acceptance route locally", async () => {
  for (const path of ["/__local/transcriptions/no-speech", "/__trigo/asr-probe/live-model"]) {
    expect(
      (await localWorker.fetch(new Request(`http://localhost${path}`, { method: "POST" }), env))
        .status,
    ).toBe(405);
  }
});
it("rejects infrastructure probes without the local-run capability", async () => {
  expect(
    (
      await localWorker.fetch(
        new Request("http://localhost/__local/probe", { method: "POST" }),
        env,
      )
    ).status,
  ).toBe(401);
});
it("validates shared schemas inside workerd", () => {
  expect(() => validateDocument("CallDocument", { schemaVersion: 2 })).toThrow("structure");
  expect(
    validateDocument("CommandIdentity", {
      schemaVersion: 1,
      operationId: "00000000-0000-4000-8000-000000000021",
    }),
  ).toBeDefined();
});
