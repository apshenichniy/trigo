import { expect, it } from "@effect/vitest";
import { Effect } from "effect";

import { AsrExtractionEvidence, AsrMaster } from "../src/asr-master.ts";
import { normalizeAssemblyAIMaster } from "../src/assemblyai-normalization.ts";

const id = (value: number) => `00000000-0000-4000-8000-${String(value).padStart(12, "0")}`;
const master = AsrMaster.make({
  callId: id(1),
  masterId: id(2),
  manifestId: id(3),
  manifestSha256: "a".repeat(64),
  sha256: "b".repeat(64),
  frameCount: 120_000 * 16,
  byteLength: 68 + 120_000 * 64,
  mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
  microphoneTrackId: id(4),
  applicationTrackId: id(5),
});
const word = (
  text: string,
  start: number,
  end: number,
  channel: string,
  speaker: string | null = "A",
) => ({ text, start, end, confidence: 0.9, channel, speaker });
function submission(
  index: number,
  words = [word("Hello.", 100, 500, "1"), word("Reply.", 600, 900, "2")],
  responseChanges: Record<string, unknown> = {},
) {
  const extraction = AsrExtractionEvidence.make({
    schemaVersion: 1,
    master,
    interval: {
      submissionId: id(10 + index),
      index,
      startFrame: index * 60_000 * 16,
      endFrame: (index + 1) * 60_000 * 16,
    },
    transform: "caf-lpcm-to-wave-pcm-frame-slice-v1",
    contentType: "audio/wav",
    codec: "pcm_s16le",
    sampleRateHz: 16_000,
    channels: 2,
    microphoneChannel: 0,
    applicationChannel: 1,
    byteLength: 44 + 60_000 * 64,
    sha256: "c".repeat(64),
    startMs: index * 60_000,
    endMs: (index + 1) * 60_000,
  });
  const uploadURL = `https://cdn.eu.assemblyai.com/upload/${index}`;
  const response = {
    id: `provider-${index}`,
    status: "completed",
    audio_url: uploadURL,
    audio_duration: 60,
    audio_channels: 2,
    multichannel: true,
    speaker_labels: true,
    language_code: "ru",
    language_detection: false,
    speech_model_used: "universal-2",
    punctuate: true,
    format_text: true,
    text: words.map((w) => w.text).join(" "),
    words,
  };
  return {
    extraction,
    rawArtifactKey: `raw/${index}`,
    rawBytes: new TextEncoder().encode(JSON.stringify({ ...response, ...responseChanges })),
    providerRequestId: response.id,
    transport: {
      deliveryWitness: "http-upload-ack-v1",
      uploadURL,
      uploadedByteLength: extraction.byteLength,
      inputSHA256: extraction.sha256,
      uploadHttpStatus: 200,
    },
  };
}
function input(submissions = [submission(0), submission(1)]) {
  let n = 100;
  return {
    master,
    revisionId: id(6),
    createdAt: "2026-09-10T10:00:00Z",
    requestedLanguage: "ru",
    submissions,
    makeId: () => id(n++),
  };
}

it.effect(
  "keeps independent channel/submission labels and interleaves speech after microphone pauses",
  () =>
    Effect.gen(function* () {
      const first = submission(0, [
        word("Greeting.", 100, 500, "1"),
        word("Meanwhile.", 3_000, 3_500, "2"),
        word("Returning.", 40_000, 40_500, "1"),
      ]);
      const result = yield* normalizeAssemblyAIMaster(input([first, submission(1)]));
      expect(result.revision.turns.map((t) => [t.text, t.startMs])).toEqual([
        ["Greeting.", 100],
        ["Meanwhile.", 3_000],
        ["Returning.", 40_000],
        ["Hello.", 60_100],
        ["Reply.", 60_600],
      ]);
      expect(result.revision.turns[0]?.speakerId).toBe(result.revision.turns[2]?.speakerId);
      expect(result.revision.speakers).toHaveLength(4);
      expect(new Set(result.revision.speakers.map((s) => s.diarizationScopeId)).size).toBe(4);
      expect(result.revision.asr).toMatchObject({
        adapter: "assemblyai",
        model: "universal-2",
        requestedLanguage: "ru",
        providerRequestIds: ["provider-0", "provider-1"],
      });
      expect(result.provenance.allUploadsAcknowledged).toBe(true);
      expect(result.provenance).not.toHaveProperty("allConsumerEOFVerified");
    }),
);

it.effect("preserves uncertain word times and unknown speakers with bounded passage playback", () =>
  Effect.gen(function* () {
    const result = yield* normalizeAssemblyAIMaster(
      input([
        submission(0, [
          word("first", 100, 900, "1", null),
          word("overlap", 700, 800, "1", null),
          word("tail", 60_001, 60_400, "1", null),
        ]),
        submission(1, []),
      ]),
    );
    expect(
      result.revision.turns
        .flatMap((t) => t.words)
        .map((w) => [w.startMs, w.endMs, w.timingUncertain]),
    ).toEqual([
      [100, 900, true],
      [700, 800, true],
      [60_001, 60_400, true],
    ]);
    expect(result.revision.turns[0]?.endMs).toBe(60_000);
    expect(result.revision.speakers).toEqual([]);
  }),
);

it.effect("publishes a valid empty revision for confirmed no-speech responses", () =>
  Effect.gen(function* () {
    const result = yield* normalizeAssemblyAIMaster(input([submission(0, []), submission(1, [])]));
    expect(result.revision.turns).toEqual([]);
    expect(result.revision.speakers).toEqual([]);
  }),
);

it.effect("rejects source/model/duration mismatches and text without timed words", () =>
  Effect.gen(function* () {
    for (const change of [
      { audio_channels: 1 },
      { multichannel: false },
      { language_code: "en" },
      { speech_model_used: "another-model" },
      { audio_duration: 55 },
      { is_deleted: true },
      { id: "wrong-id" },
      { audio_url: "https://example.com/other.wav" },
      { words: [] },
      { words: [word("bad channel", 0, 100, "3")] },
    ]) {
      const first = submission(0, undefined, change);
      const result = yield* normalizeAssemblyAIMaster(input([first, submission(1)])).pipe(
        Effect.result,
      );
      expect(result._tag).toBe("Failure");
    }
    const first = submission(0);
    first.transport.uploadedByteLength -= 4;
    expect(
      (yield* normalizeAssemblyAIMaster(input([first, submission(1)])).pipe(Effect.result))._tag,
    ).toBe("Failure");
  }),
);
