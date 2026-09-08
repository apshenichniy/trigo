import { expect, it } from "@effect/vitest";
import { Effect } from "effect";

import { storedByteHash } from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { AsrExtractionEvidence, AsrMaster } from "../src/asr-master.ts";
import { normalizeNova3Master } from "../src/nova-3-master.ts";

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const master = AsrMaster.make({
  callId: id(1),
  masterId: id(2),
  manifestId: id(3),
  manifestSha256: "a".repeat(64),
  sha256: "b".repeat(64),
  frameCount: 32_000,
  byteLength: 128_068,
  mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
  microphoneTrackId: id(4),
  applicationTrackId: id(5),
});

function words(text: string, speaker: number | undefined = 0) {
  return {
    alternatives: [
      {
        transcript: text,
        words:
          text === ""
            ? []
            : [{ word: text, start: 0.2, end: 0.6, ...(speaker === undefined ? {} : { speaker }) }],
      },
    ],
  };
}

function submission(
  index: number,
  response: unknown = {
    metadata: {
      duration: 1,
      channels: 2,
      model_info: { model: { version: "observed-test-version" } },
    },
    results: { channels: [words("Local"), words("Remote")] },
  },
) {
  const extraction = AsrExtractionEvidence.make({
    schemaVersion: 1,
    master,
    interval: {
      submissionId: id(10 + index),
      index,
      startFrame: index * 16_000,
      endFrame: (index + 1) * 16_000,
    },
    transform: "caf-lpcm-to-wave-pcm-frame-slice-v1",
    contentType: "audio/wav",
    codec: "pcm_s16le",
    sampleRateHz: 16_000,
    channels: 2,
    microphoneChannel: 0,
    applicationChannel: 1,
    byteLength: 64_044,
    sha256: "c".repeat(64),
    startMs: index * 1_000,
    endMs: (index + 1) * 1_000,
  });
  return {
    extraction,
    rawArtifactKey: `fixture/raw-${index}.json`,
    rawBytes: new TextEncoder().encode(JSON.stringify(response)),
    providerRequestId: `request-${index}`,
  };
}

function input() {
  let nextId = 100;
  return {
    master,
    revisionId: id(6),
    createdAt: "2026-09-08T00:00:00Z",
    requestedLanguage: "en",
    submissions: [submission(0), submission(1)],
    makeId: () => id(nextId++),
  };
}

it.effect(
  "keeps two channels and independent submission scopes while retaining exact raw/provenance identities",
  () =>
    Effect.gen(function* () {
      const value = input();
      const result = yield* normalizeNova3Master(value);
      expect(result.revision.asr.profileId).toBe(nova3StreamProfile.id);
      expect(result.revision.asr.providerRequestIds).toEqual(["request-0", "request-1"]);
      expect(result.revision.asr.returnedModelVersion).toBe("observed-test-version");
      expect(result.revision.speakers).toHaveLength(4);
      expect(
        new Set(result.revision.speakers.map((speaker) => speaker.diarizationScopeId)).size,
      ).toBe(4);
      expect(result.revision.turns.map((turn) => turn.startMs)).toEqual([200, 200, 1200, 1200]);
      expect(result.provenance.master).toEqual(master);
      const first = result.provenance.submissions[0];
      expect(first?.extraction).toEqual(value.submissions[0]?.extraction);
      expect(first?.rawArtifact.sha256).toBe(
        yield* Effect.promise(() => storedByteHash(submission(0).rawBytes)),
      );
      expect(first?.reportedDurationSeconds).toBe(1);
      expect(first?.transport.deliveryWitness).toBe("unobserved");
      expect(result.provenance.allConsumerEOFVerified).toBe(false);
    }),
);

it.effect("preserves legacy delivery qualification and rejects contradictory EOF witnesses", () =>
  Effect.gen(function* () {
    const value = input();
    const submissions = value.submissions.map((item) => ({
      ...item,
      transport: {
        deliveryWitness: "consumer-eof-v1",
        deliveredByteLength: item.extraction.byteLength,
        responseBodyComplete: true,
        providerHttpStatus: 200,
      },
    }));
    const completed = yield* normalizeNova3Master({ ...value, submissions });
    expect(completed.provenance.allConsumerEOFVerified).toBe(true);
    const legacy = submissions.map((item) => ({
      ...item,
      transport: { ...item.transport, deliveryWitness: "legacy-producer-hash-v1" },
    }));
    const qualified = yield* normalizeNova3Master({ ...input(), submissions: legacy });
    expect(qualified.provenance.allConsumerEOFVerified).toBe(false);
    expect(qualified.provenance.submissions[0]?.transport.deliveryWitness).toBe(
      "legacy-producer-hash-v1",
    );
    for (const contradiction of [
      { deliveredByteLength: 44 },
      { responseBodyComplete: false },
      { providerHttpStatus: 500 },
    ]) {
      const rejected = yield* Effect.result(
        normalizeNova3Master({
          ...input(),
          submissions: submissions.map((item) => ({
            ...item,
            transport: { ...item.transport, ...contradiction },
          })),
        }),
      );
      expect(rejected._tag).toBe("Failure");
    }
  }),
);

it.effect(
  "accepts explicit no-speech evidence without manufacturing words or detected languages",
  () =>
    Effect.gen(function* () {
      const value = input();
      const silent = { results: { channels: [words(""), words("")] } };
      const result = yield* normalizeNova3Master({
        ...value,
        submissions: [submission(0, silent), submission(1, silent)],
      });
      expect(result.revision.turns).toEqual([]);
      expect(result.revision.speakers).toEqual([]);
      expect(result.revision.asr.detectedLanguages).toEqual([]);
      expect(
        result.provenance.submissions.every((item) => item.reportedDurationSeconds === null),
      ).toBe(true);
    }),
);

it.effect(
  "rejects truncated coverage, a changed master, reused submission identity and contradictory provider duration",
  () =>
    Effect.gen(function* () {
      const value = input();
      const first = submission(0);
      const second = submission(1);
      const invalidInputs = [
        { ...value, submissions: [first] },
        {
          ...value,
          submissions: [
            first,
            {
              ...second,
              extraction: { ...second.extraction, master: { ...master, sha256: "d".repeat(64) } },
            },
          ],
        },
        {
          ...value,
          submissions: [
            first,
            {
              ...second,
              extraction: {
                ...second.extraction,
                interval: {
                  ...second.extraction.interval,
                  submissionId: first.extraction.interval.submissionId,
                },
              },
            },
          ],
        },
        {
          ...value,
          submissions: [
            submission(0, {
              metadata: { duration: 0.5 },
              results: { channels: [words(""), words("")] },
            }),
            second,
          ],
        },
        {
          ...value,
          submissions: [first, { ...second, extraction: { ...second.extraction, startMs: 2 } }],
        },
      ];
      for (const invalid of invalidInputs) {
        expect((yield* Effect.result(normalizeNova3Master(invalid)))._tag).toBe("Failure");
      }
    }),
);
