import { expect, it } from "@effect/vitest";
import { Effect } from "effect";

import { normalizeNova3, Nova3NormalizationError } from "../src/nova-3.ts";

const microphoneTrack = "00000000-0000-4000-8000-000000001302";
const applicationTrack = "00000000-0000-4000-8000-000000001303";

function ids() {
  let value = 1_400;
  return () => `00000000-0000-4000-8000-${String(value++).padStart(12, "0")}`;
}

function object(
  index: number,
  response: unknown,
  providerRequestId: string | null = `provider-${index}`,
) {
  const startMs = index * 60_000;
  return {
    objectId: `00000000-0000-4000-8000-${String(1_310 + index).padStart(12, "0")}`,
    index,
    startMs,
    endMs: startMs + 60_000,
    channelMap: [
      { channelIndex: 0, trackId: microphoneTrack },
      { channelIndex: 1, trackId: applicationTrack },
    ],
    providerRequestId,
    response,
  };
}

const inputBase = {
  callId: "00000000-0000-4000-8000-000000001300",
  revisionId: "00000000-0000-4000-8000-000000001309",
  createdAt: "2026-09-06T00:00:00Z",
  audioManifest: {
    manifestId: "00000000-0000-4000-8000-000000001301",
    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  },
  requestedLanguage: "en",
  detectedLanguages: ["en"],
  tracks: [
    { trackId: microphoneTrack, role: "microphone" },
    { trackId: applicationTrack, role: "application" },
  ],
};

it.effect("places returning microphone speech after a long silence on the call timeline", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        {
          ...object(0, {
            results: {
              channels: [
                {
                  alternatives: [
                    {
                      words: [
                        { word: "Hello.", start: 145.26, end: 145.82, speaker: 0 },
                        { word: "Returning", start: 1088.13, end: 1088.77, speaker: 0 },
                        { word: "now.", start: 1088.8, end: 1089.2, speaker: 0 },
                      ],
                    },
                  ],
                },
                {
                  alternatives: [
                    { words: [{ word: "Meanwhile.", start: 600, end: 601, speaker: 0 }] },
                  ],
                },
              ],
            },
          }),
          endMs: 1_703_750,
        },
      ],
    });
    expect(result.turns.map(({ startMs, text }) => ({ startMs, text }))).toEqual([
      { startMs: 145_260, text: "Hello." },
      { startMs: 600_000, text: "Meanwhile." },
      { startMs: 1_088_130, text: "Returning now." },
    ]);
    expect(result.turns[0]?.speakerId).toBe(result.turns[2]?.speakerId);
    expect(result.turns.flatMap((turn) => turn.words).map((word) => word.startMs)).toEqual([
      145_260, 600_000, 1_088_130, 1_088_800,
    ]);
  }),
);

it.effect("retains overlapping and beyond-end words with approximate timing", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        {
          ...object(0, {
            results: {
              channels: [
                {
                  alternatives: [
                    {
                      words: [
                        { word: "First", start: 10.4, end: 11.2, confidence: 0.98 },
                        { word: "overlap", start: 10.919, end: 11.239 },
                        { word: "clear", start: 12, end: 13 },
                        { word: "tail", start: 18.359, end: 18.599 },
                        {
                          word: "outside",
                          punctuated_word: "outside.",
                          start: 18.599,
                          end: 18.999,
                        },
                      ],
                    },
                  ],
                },
                { alternatives: [{ words: [{ word: "Boundary", start: 18.599, end: 18.999 }] }] },
              ],
            },
          }),
          endMs: 18_514,
        },
      ],
    });
    expect(result.normalizationVersion).toBe(2);
    expect(result.turns.map(({ startMs, endMs, text }) => ({ startMs, endMs, text }))).toEqual([
      { startMs: 10_400, endMs: 18_514, text: "First overlap clear tail outside." },
      { startMs: 18_514, endMs: 18_514, text: "Boundary" },
    ]);
    expect(result.turns[0]?.words).toEqual([
      { text: "First", startMs: 10_400, endMs: 11_200, confidence: 0.98, timingUncertain: true },
      { text: "overlap", startMs: 10_919, endMs: 11_239, confidence: null, timingUncertain: true },
      { text: "clear", startMs: 12_000, endMs: 13_000, confidence: null },
      { text: "tail", startMs: 18_359, endMs: 18_599, confidence: null, timingUncertain: true },
      { text: "outside.", startMs: 18_599, endMs: 18_999, confidence: null, timingUncertain: true },
    ]);
  }),
);

it.effect("preserves channel provenance, gaps, and independent speaker scopes", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              {
                alternatives: [
                  {
                    transcript: "Local marker.",
                    words: [
                      {
                        word: "Local",
                        punctuated_word: "Local",
                        start: 1,
                        end: 1.4,
                        confidence: 0.98,
                        speaker: 0,
                      },
                      {
                        word: "marker",
                        punctuated_word: "marker.",
                        start: 1.4,
                        end: 2,
                        confidence: 0.97,
                        speaker: 0,
                      },
                    ],
                  },
                ],
              },
              {
                alternatives: [
                  {
                    transcript: "First remote. Second remote.",
                    words: [
                      { word: "First", start: 8, end: 8.4, speaker: 0 },
                      { word: "remote", start: 8.4, end: 9, speaker: 0 },
                      { word: "Second", start: 20, end: 20.4, speaker: 1 },
                      { word: "remote", start: 20.4, end: 21, speaker: 1 },
                    ],
                  },
                ],
              },
            ],
          },
        }),
        object(1, {
          results: {
            channels: [
              { alternatives: [{ transcript: "", words: [] }] },
              {
                alternatives: [
                  {
                    transcript: "First again.",
                    words: [
                      { word: "First", start: 5, end: 5.4, speaker: 0 },
                      { word: "again", start: 5.4, end: 6, speaker: 0 },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      ],
    });

    expect(result.asr).toMatchObject({
      adapter: "cloudflare-workers-ai",
      model: "@cf/deepgram/nova-3",
      profileId: "trigo-call-wav-s16le-16khz-stereo-60s-v1",
      providerRequestIds: ["provider-0", "provider-1"],
    });
    expect(
      result.turns.map(({ trackId, startMs, endMs, text }) => ({
        trackId,
        startMs,
        endMs,
        text,
      })),
    ).toEqual([
      { trackId: microphoneTrack, startMs: 1_000, endMs: 2_000, text: "Local marker." },
      { trackId: applicationTrack, startMs: 8_000, endMs: 9_000, text: "First remote" },
      { trackId: applicationTrack, startMs: 20_000, endMs: 21_000, text: "Second remote" },
      { trackId: applicationTrack, startMs: 65_000, endMs: 66_000, text: "First again" },
    ]);
    expect(result.speakers).toHaveLength(4);
    const remoteZero = result.speakers.filter(
      (speaker) => speaker.trackId === applicationTrack && speaker.providerLabel === "0",
    );
    expect(remoteZero).toHaveLength(2);
    expect(new Set(remoteZero.map((speaker) => speaker.diarizationScopeId)).size).toBe(2);
  }),
);

it.effect("retains unknown speakers without inventing speaker identity", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              {
                alternatives: [
                  { transcript: "Hello", words: [{ word: "Hello", start: 0, end: 1 }] },
                ],
              },
              { alternatives: [{ transcript: "", words: [] }] },
            ],
          },
        }),
      ],
    });

    expect(result.speakers).toEqual([]);
    expect(result.turns[0]).toMatchObject({ trackId: microphoneTrack, speakerId: null });
  }),
);

it.effect("rejects a channel result that cannot prove both source roles", () =>
  Effect.gen(function* () {
    const error = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: { channels: [{ alternatives: [{ transcript: "", words: [] }] }] },
        }),
      ],
    }).pipe(Effect.flip);

    expect(error).toBeInstanceOf(Nova3NormalizationError);
    expect(error.message).toContain("must return 2 channels");
  }),
);

it.effect("rejects a channel map that swaps microphone and application tracks", () =>
  Effect.gen(function* () {
    const swapped = object(0, {
      results: {
        channels: [
          { alternatives: [{ transcript: "", words: [] }] },
          { alternatives: [{ transcript: "", words: [] }] },
        ],
      },
    });
    const error = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        {
          ...swapped,
          channelMap: [
            { channelIndex: 0, trackId: applicationTrack },
            { channelIndex: 1, trackId: microphoneTrack },
          ],
        },
      ],
    }).pipe(Effect.flip);

    expect(error.message).toContain("does not map to microphone");
  }),
);

it.effect("rejects provider text when word timing is absent", () =>
  Effect.gen(function* () {
    const error = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              { alternatives: [{ transcript: "Unbounded text" }] },
              { alternatives: [{ transcript: "", words: [] }] },
            ],
          },
        }),
      ],
    }).pipe(Effect.flip);

    expect(error.message).toContain("text without word timing");
  }),
);

it.effect("keeps corrupt alignment from marking later independent words as uncertain", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              {
                alternatives: [
                  {
                    words: [
                      { word: "outlier", start: 0.1, end: 100 },
                      { word: "clear", start: 1, end: 2 },
                      { word: "reversed", start: 4, end: 3 },
                      { word: "clear-again", start: 5, end: 6 },
                    ],
                  },
                ],
              },
              { alternatives: [{ words: [] }] },
            ],
          },
        }),
      ],
    });
    expect(result.turns[0]?.words.map((w) => w.timingUncertain ?? false)).toEqual([
      true,
      false,
      true,
      false,
    ]);
    expect(result.turns[0]?.words[2]).toMatchObject({ startMs: 4000, endMs: 3000 });
    expect(result.turns[0]).toMatchObject({
      startMs: 100,
      endMs: 60_000,
      text: "outlier clear reversed clear-again",
    });
  }),
);

it.effect("marks conflicting word order without sorting the provider's text", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              {
                alternatives: [
                  {
                    words: [
                      { word: "First", start: 5, end: 6 },
                      { word: "second", start: 1, end: 2 },
                      { word: "third", start: 7, end: 8 },
                    ],
                  },
                ],
              },
              { alternatives: [{ words: [] }] },
            ],
          },
        }),
      ],
    });
    expect(result.turns[0]).toMatchObject({
      startMs: 1000,
      endMs: 8000,
      text: "First second third",
    });
    expect(result.turns[0]?.words.map((w) => w.timingUncertain ?? false)).toEqual([
      true,
      true,
      false,
    ]);
  }),
);

it.effect("still rejects structurally invalid or unrepresentable word timing", () =>
  Effect.gen(function* () {
    for (const start of [-1, Number.NaN, Number.MAX_VALUE]) {
      const result = yield* normalizeNova3({
        ...inputBase,
        makeId: ids(),
        objects: [
          object(0, {
            results: {
              channels: [
                { alternatives: [{ words: [{ word: "invalid", start, end: 1 }] }] },
                { alternatives: [{ words: [] }] },
              ],
            },
          }),
        ],
      }).pipe(Effect.result);
      expect(result._tag).toBe("Failure");
    }
  }),
);

it.effect("preserves provider order across speaker changes with backward timestamps", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              {
                alternatives: [
                  {
                    words: [
                      { word: "First", start: 5, end: 6, speaker: 0 },
                      { word: "second", start: 1, end: 2, speaker: 1 },
                      { word: "third", start: 7, end: 8, speaker: 2 },
                    ],
                  },
                ],
              },
              {
                alternatives: [
                  {
                    words: [
                      { word: "Remote", start: 4, end: 4.5, speaker: 0 },
                      { word: "later", start: 9, end: 10, speaker: 1 },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      ],
    });
    expect(result.turns.map((turn) => turn.text)).toEqual([
      "Remote",
      "First",
      "second",
      "third",
      "later",
    ]);
    expect(
      result.turns
        .filter((turn) => turn.trackId === microphoneTrack)
        .map((turn) => ({
          startMs: turn.startMs,
          endMs: turn.endMs,
          uncertain: turn.words.some((word) => word.timingUncertain),
        })),
    ).toEqual([
      { startMs: 5000, endMs: 6000, uncertain: true },
      { startMs: 1000, endMs: 2000, uncertain: true },
      { startMs: 7000, endMs: 8000, uncertain: false },
    ]);
  }),
);

it.effect("keeps valid later speaker playback after a wholly outside speaker run", () =>
  Effect.gen(function* () {
    const result = yield* normalizeNova3({
      ...inputBase,
      makeId: ids(),
      objects: [
        object(0, {
          results: {
            channels: [
              {
                alternatives: [
                  {
                    words: [
                      { word: "Outside", start: 70, end: 71, speaker: 0 },
                      { word: "clear", start: 1, end: 2, speaker: 1 },
                    ],
                  },
                ],
              },
              { alternatives: [{ words: [{ word: "Remote", start: 4, end: 5 }] }] },
            ],
          },
        }),
      ],
    });
    expect(
      result.turns.map((turn) => ({
        text: turn.text,
        startMs: turn.startMs,
        endMs: turn.endMs,
        uncertain: turn.words.some((word) => word.timingUncertain),
      })),
    ).toEqual([
      { text: "Remote", startMs: 4000, endMs: 5000, uncertain: false },
      { text: "Outside", startMs: 60_000, endMs: 60_000, uncertain: true },
      { text: "clear", startMs: 1000, endMs: 2000, uncertain: false },
    ]);
  }),
);
