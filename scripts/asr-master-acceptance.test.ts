// oxlint-disable effecttsgo/prefer-schema-over-json -- Adversarial fixture bytes intentionally include corrupted shapes before the decoder under test sees them.
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, it } from "@effect/vitest";
import { Effect } from "effect";

import {
  AsrExtractionEvidence,
  makeAsrMasterHeader,
  makeAsrWaveHeader,
} from "../apps/server/src/asr-master.ts";
import { prepareHostedMasterFixture } from "../apps/server/src/hosted-master-fixture.ts";
import { normalizeNova3Master } from "../apps/server/src/nova-3-master.ts";
import { checkHostedMasterAcceptance } from "./asr-master-acceptance.ts";

const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const id = (value: number) => `00000000-0000-4000-8000-${String(value).padStart(12, "0")}`;

const fixture = Effect.fn("AcceptanceTest.fixture")(function* () {
  const template = new Uint8Array(3_840_068);
  template.set(makeAsrMasterHeader());
  let identity = 1;
  const plan = yield* prepareHostedMasterFixture(
    "scope-proof",
    "en",
    template,
    120_000,
    60_000,
    "2026-09-08T00:00:00Z",
    () => id(identity++),
  );
  const markers = ["alpha", "bravo", "charlie"];
  const voices = [
    { voice: "local", channel: 0, at: 1000, label: 0 },
    { voice: "first remote", channel: 1, at: 5500, label: 0 },
    { voice: "second remote", channel: 1, at: 12000, label: 1 },
  ];
  const events = markers.flatMap((marker, block) =>
    voices.map((voice) => ({
      block,
      marker,
      voice: voice.voice,
      channel: voice.channel,
      startMs: block * 20_000 + voice.at,
      endMs: block * 20_000 + voice.at + 200,
    })),
  );
  const submissions = plan.intervals.map((interval) => {
    const wave = new Uint8Array(3_840_044);
    wave.set(makeAsrWaveHeader(960_000));
    const raw = {
      results: {
        channels: [0, 1].map((channel) => ({
          alternatives: [
            {
              words: [0, 1, 2].flatMap((localBlock) => {
                const block = interval.index * 3 + localBlock;
                const marker = markers[block === 5 ? 2 : block === 3 ? 1 : 0] ?? "alpha";
                return voices
                  .filter((voice) => voice.channel === channel)
                  .map((voice) => ({
                    word: marker,
                    punctuated_word: marker + ".",
                    speaker: voice.label,
                    start: localBlock * 20 + voice.at / 1_000,
                    end: localBlock * 20 + voice.at / 1_000 + 0.1,
                    confidence: 0.9,
                  }));
              }),
            },
          ],
        })),
      },
    };
    const extraction = AsrExtractionEvidence.make({
      schemaVersion: 1,
      master: plan.master,
      interval,
      transform: "caf-lpcm-to-wave-pcm-frame-slice-v1",
      contentType: "audio/wav",
      codec: "pcm_s16le",
      sampleRateHz: 16_000,
      channels: 2,
      microphoneChannel: 0,
      applicationChannel: 1,
      byteLength: wave.length,
      sha256: hash(wave),
      startMs: interval.startFrame / 16,
      endMs: interval.endFrame / 16,
    });
    return {
      extraction,
      rawArtifactKey: `raw-${interval.index}.json`,
      rawBytes: new TextEncoder().encode(JSON.stringify(raw)),
      providerRequestId: `request-${interval.index}`,
      transport: {
        deliveryWitness: "consumer-eof-v1",
        deliveredByteLength: wave.length,
        responseBodyComplete: true,
        providerHttpStatus: 200,
      },
    };
  });
  const normalized = yield* normalizeNova3Master({
    master: plan.master,
    revisionId: plan.revisionId,
    createdAt: plan.createdAt,
    requestedLanguage: "en",
    submissions,
    makeId: () => id(identity++),
  });
  const files: Record<string, string | Uint8Array> = {
    "template.caf": template,
    "template.caf.json": JSON.stringify({
      language: "en",
      kind: "controlled-synthetic-speech",
      sha256: hash(template),
      events,
    }),
    "plan-0.json": JSON.stringify(plan),
    "normalize.json": JSON.stringify(normalized.revision),
    "provenance-0.json": JSON.stringify(normalized.provenance),
  };
  submissions.forEach((submission, index) => {
    files[`raw-${index}.json`] = submission.rawBytes;
  });
  return { files, plan, ...normalized };
});

it.effect("rejects proof tampering that leaves the word-only projection unchanged", () =>
  Effect.gen(function* () {
    const baseline = yield* fixture();
    const { revision, provenance, plan } = baseline;
    const changes = [
      { "plan-0.json": JSON.stringify({ ...plan, language: "ru" }) },
      {
        "normalize.json": JSON.stringify({
          ...revision,
          speakers: [],
          turns: revision.turns.map((turn) => ({ ...turn, speakerId: null })),
        }),
      },
      {
        "normalize.json": JSON.stringify({
          ...revision,
          turns: revision.turns.map((turn) => ({ ...turn, text: "Unrelated text" })),
        }),
      },
      {
        "normalize.json": JSON.stringify({
          ...revision,
          speakers: revision.speakers.map((speaker) => ({
            ...speaker,
            diarizationScopeId: id(999),
          })),
        }),
      },
      { "normalize.json": JSON.stringify({ ...revision, revisionId: id(999) }) },
      {
        "plan-0.json": JSON.stringify({
          ...plan,
          master: { ...plan.master, sha256: "a".repeat(64) },
        }),
      },
      ...[
        { deliveredByteLength: 0 },
        { responseBodyComplete: false },
        { providerHttpStatus: 500 },
      ].map((bad) => ({
        "provenance-0.json": JSON.stringify({
          ...provenance,
          submissions: provenance.submissions.map((item) => ({
            ...item,
            transport: { ...item.transport, ...bad },
          })),
        }),
      })),
    ];
    const directory = mkdtempSync(join(tmpdir(), "trigo-acceptance-test-"));
    try {
      const write = (overrides: Record<string, string>) => {
        for (const [name, content] of Object.entries({ ...baseline.files, ...overrides })) {
          writeFileSync(join(directory, name), content);
        }
      };
      write({});
      const accepted = checkHostedMasterAcceptance(join(directory, "template.caf.json"), directory);
      expect(accepted).toMatchObject({
        sourceEvents: 18,
        words: 18,
        normalizedSpeakers: 6,
        normalizedScopes: 4,
        allConsumerEOFVerified: true,
      });
      for (const changed of changes) {
        write(changed);
        expect(() =>
          checkHostedMasterAcceptance(join(directory, "template.caf.json"), directory),
        ).toThrow();
      }
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }),
);
