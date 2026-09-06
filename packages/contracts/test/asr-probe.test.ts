import { expect, it } from "vitest";
import { Schema } from "effect";
import {
  AsrProbeErrorEnvelope,
  AsrProbeTranscriptionResponse,
  AsrProbeUploadResponse,
  selectedMediaProfile,
} from "../src/index.ts";

const common = {
  fixture: "two-source-en",
  language: "en",
  profileId: selectedMediaProfile.id,
  byteLength: 1_152_044,
  durationMs: 18_000,
} as const;

it("shares the ASR upload envelope across producer and consumer", () => {
  expect(
    Schema.decodeUnknownSync(AsrProbeUploadResponse)({
      ...common,
      inputKey: "acceptance/issue-13/two-source-en/input.wav",
    }),
  ).toMatchObject(common);
});

it("shares the ASR transcription envelope across producer and consumer", () => {
  expect(
    Schema.decodeUnknownSync(AsrProbeTranscriptionResponse)({
      ...common,
      providerLatencyMs: 500,
      channelCount: 2,
      speakerCount: 2,
      turnCount: 3,
      retainedKeys: ["acceptance/issue-13/two-source-en/en/provider-result.json"],
    }),
  ).toMatchObject(common);
});

it("rejects profile drift in ASR probe evidence", () => {
  expect(() =>
    Schema.decodeUnknownSync(AsrProbeUploadResponse)({
      ...common,
      profileId: "another-profile",
      inputKey: "acceptance/issue-13/two-source-en/input.wav",
    }),
  ).toThrow();
});

it("shares the ASR error envelope across producer and consumer", () => {
  expect(
    Schema.decodeUnknownSync(AsrProbeErrorEnvelope)({
      schemaVersion: 1,
      error: {
        code: "asr_probe_attempt_exists",
        retry: "after_correction",
        message: "The bounded provider attempt already exists.",
        requestId: "00000000-0000-4000-8000-000000000013",
      },
    }).error.code,
  ).toBe("asr_probe_attempt_exists");
});
