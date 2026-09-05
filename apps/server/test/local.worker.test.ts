import { exports } from "cloudflare:workers";
import { expect, it, beforeAll } from "vitest";
beforeAll(async () => {
  expect((await exports.default.fetch("http://localhost/__local/health")).status).toBe(200);
});
it("persists fake transcription through the local Worker and R2 binding", async () => {
  const response = await exports.default.fetch(
    "http://localhost/__local/transcriptions/no-speech",
    { method: "POST" },
  );
  expect(response.status).toBe(201);
  const stored = await exports.default.fetch("http://localhost/__local/transcriptions/no-speech");
  expect(await stored.json()).toEqual({ fixture: "no-speech", turns: [], provider: "fake" });
});
it("denies external service access in the Workers runtime", async () => {
  expect((await fetch("https://api.cloudflare.com")).status).toBe(403);
});
it("rejects arbitrary model requests", async () => {
  expect(
    (
      await exports.default.fetch("http://localhost/__local/transcriptions/live-model", {
        method: "POST",
      })
    ).status,
  ).toBe(400);
});
it("validates shared generated schemas inside workerd", async () => {
  const { validateDocument } = await import("@trigo/contracts");
  expect(() => validateDocument("CallDocument", { schemaVersion: 2 })).toThrow("structure");
  expect(
    validateDocument("CommandIdentity", {
      schemaVersion: 1,
      operationId: "00000000-0000-4000-8000-000000000021",
    }),
  ).toBeDefined();
});
