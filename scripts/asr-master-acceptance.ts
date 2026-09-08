import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { Schema } from "effect";

import { AsrExtractionEvidence, AsrMaster } from "../apps/server/src/asr-master.ts";
import { HostedMasterFixture } from "../apps/server/src/hosted-master-fixture.ts";
import { Nova3SubmissionTransport } from "../apps/server/src/nova-3-master.ts";
import { validateDocument } from "../packages/contracts/src/index.ts";

const Event = Schema.Struct({
  block: Schema.Int,
  marker: Schema.NonEmptyString,
  voice: Schema.NonEmptyString,
  channel: Schema.Literals([0, 1]),
  startMs: Schema.Finite,
  endMs: Schema.Finite,
});
const Template = Schema.Struct({
  language: Schema.Literals(["en", "ru", "uk"]),
  kind: Schema.Literals(["controlled-synthetic-speech", "digital-silence"]),
  sha256: Schema.NonEmptyString,
  events: Schema.Array(Event),
});
const Word = Schema.Struct({
  word: Schema.String,
  punctuated_word: Schema.optionalKey(Schema.String),
  start: Schema.Finite,
  end: Schema.Finite,
  confidence: Schema.optionalKey(Schema.Finite),
  speaker: Schema.optionalKey(Schema.Union([Schema.String, Schema.Finite])),
});
const Raw = Schema.Struct({
  results: Schema.Struct({
    channels: Schema.Array(
      Schema.Struct({
        alternatives: Schema.Array(Schema.Struct({ words: Schema.Array(Word) })),
      }),
    ).check(Schema.isLengthBetween(2, 2)),
  }),
  usage: Schema.optionalKey(Schema.Struct({ neurons: Schema.Finite })),
});
const Provenance = Schema.Struct({
  callId: Schema.NonEmptyString,
  revisionId: Schema.NonEmptyString,
  profileId: Schema.NonEmptyString,
  master: AsrMaster,
  allConsumerEOFVerified: Schema.optionalKey(Schema.Boolean),
  submissions: Schema.Array(
    Schema.Struct({
      extraction: AsrExtractionEvidence,
      transport: Schema.optionalKey(Nova3SubmissionTransport),
      rawArtifact: Schema.Struct({ sha256: Schema.NonEmptyString, byteLength: Schema.Int }),
    }),
  ),
});
const markerWords: Record<string, Record<string, string>> = {
  en: { alpha: "alpha", bravo: "bravo", charlie: "charlie" },
  ru: { alpha: "альфа", bravo: "браво", charlie: "чарли" },
  uk: { alpha: "альфа", bravo: "браво", charlie: "чарлі" },
};
const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const readJson = (path: string) =>
  Schema.decodeSync(Schema.fromJsonString(Schema.Unknown))(readFileSync(path, "utf8"));

/** Independent source-window and raw-to-canonical comparison; this does not invoke ASR. */
export function checkHostedMasterAcceptance(
  templatePath: string,
  directory: string,
  allowLegacy = false,
) {
  const template = Schema.decodeUnknownSync(Template)(readJson(templatePath));
  const templateBytes = readFileSync(templatePath.replace(/\.json$/, ""));
  assert.equal(hash(templateBytes), template.sha256);
  const plan = Schema.decodeUnknownSync(HostedMasterFixture)(
    readJson(join(directory, "plan-0.json")),
  );
  assert.equal(plan.templateSha256, template.sha256);
  const provenance = Schema.decodeUnknownSync(Provenance)(
    readJson(join(directory, "provenance-0.json")),
  );
  assert.equal(provenance.submissions.length, plan.intervals.length);
  if (!allowLegacy) {
    assert.equal(provenance.allConsumerEOFVerified, true);
  }
  const revision = validateDocument(
    "TranscriptRevision",
    readJson(join(directory, "normalize.json")),
  );
  assert.deepEqual(provenance.master, plan.master);
  assert.equal(provenance.callId, plan.master.callId);
  assert.equal(revision.callId, plan.master.callId);
  assert.equal(provenance.revisionId, plan.revisionId);
  assert.equal(revision.revisionId, plan.revisionId);
  assert.equal(provenance.profileId, "nova3-wav-s16le-16000-stereo-stream-v1");
  assert.equal(revision.asr.profileId, provenance.profileId);
  assert.equal(plan.language, template.language);
  assert.equal(revision.asr.requestedLanguage, template.language);
  assert.equal(revision.asr.adapter, "cloudflare-workers-ai");
  assert.equal(revision.asr.model, "@cf/deepgram/nova-3");
  assert.equal(revision.audioManifest.manifestId, plan.master.manifestId);
  assert.equal(revision.audioManifest.sha256, plan.master.manifestSha256);
  const durationMs = plan.master.frameCount / 16;
  const blocks = durationMs / 20_000;
  assert.equal(blocks, Math.floor(blocks));
  const sourceBlock = (block: number) =>
    block === blocks - 1 ? 2 : block === Math.floor(blocks / 2) ? 1 : 0;
  const hashPcm = (digest: ReturnType<typeof createHash>, startFrame: number, endFrame: number) => {
    let offset = startFrame * 4;
    while (offset < endFrame * 4) {
      const block = Math.floor(offset / 1_280_000);
      const within = offset % 1_280_000;
      const length = Math.min(1_280_000 - within, endFrame * 4 - offset);
      const start = 68 + sourceBlock(block) * 1_280_000 + within;
      digest.update(templateBytes.subarray(start, start + length));
      offset += length;
    }
  };
  const masterDigest = createHash("sha256").update(templateBytes.subarray(0, 68));
  hashPcm(masterDigest, 0, plan.master.frameCount);
  assert.equal(masterDigest.digest("hex"), plan.master.sha256);
  const expectedEvents = Array.from({ length: blocks }, (_, block) => {
    const templateBlock = sourceBlock(block);
    return template.events
      .filter((event) => event.block === templateBlock)
      .map((event) => ({
        ...event,
        startMs: event.startMs + (block - templateBlock) * 20_000,
        endMs: event.endMs + (block - templateBlock) * 20_000,
      }));
  }).flat();
  const projectedWords: string[] = [];
  let intervalCursor = 0;
  let wordsOutside500MsSpeechWindows = 0;
  const sourceEvents: Array<{
    channel: number;
    voice: string;
    startMs: number;
    wordCount: number;
    startErrorMs: number;
    endErrorMs: number;
    labels: string[];
  }> = [];
  const observations = plan.intervals.map((interval, index) => {
    const bytes = readFileSync(join(directory, `raw-${index}.json`));
    const witness = provenance.submissions[index];
    assert.ok(witness);
    assert.equal(interval.index, index);
    assert.equal(interval.startFrame, intervalCursor);
    intervalCursor = interval.endFrame;
    assert.deepEqual(witness.extraction.master, plan.master);
    assert.deepEqual(witness.extraction.interval, interval);
    const expectedBytes = 44 + (interval.endFrame - interval.startFrame) * 4;
    const waveHeader = Buffer.from(
      "524946460000000057415645666d74201000000001000200803e000000fa0000040010006461746100000000",
      "hex",
    );
    waveHeader.writeUInt32LE(expectedBytes - 8, 4);
    waveHeader.writeUInt32LE(expectedBytes - 44, 40);
    const inputDigest = createHash("sha256").update(waveHeader);
    hashPcm(inputDigest, interval.startFrame, interval.endFrame);
    assert.equal(inputDigest.digest("hex"), witness.extraction.sha256);
    assert.equal(hash(bytes), witness.rawArtifact.sha256);
    assert.equal(bytes.byteLength, witness.rawArtifact.byteLength);
    if (!allowLegacy) {
      assert.equal(witness.transport?.deliveryWitness, "consumer-eof-v1");
    }
    if (witness.transport?.deliveryWitness === "consumer-eof-v1") {
      assert.equal(witness.transport.deliveredByteLength, expectedBytes);
      assert.equal(witness.transport.responseBodyComplete, true);
      assert.equal(witness.transport.providerHttpStatus, 200);
    }
    const raw = Schema.decodeUnknownSync(Raw)(readJson(join(directory, `raw-${index}.json`)));
    const offsetMs = interval.startFrame / 16;
    const endMs = interval.endFrame / 16;
    const channels = raw.results.channels.map((channel, channelIndex) => {
      const words = channel.alternatives[0]?.words;
      assert.ok(words);
      const trackId =
        channelIndex === 0 ? plan.master.microphoneTrackId : plan.master.applicationTrackId;
      const absolute = words.map((word) => ({
        ...word,
        startMs: offsetMs + Math.round(word.start * 1_000),
        endMs: offsetMs + Math.round(word.end * 1_000),
      }));
      for (const word of absolute) {
        assert.ok(word.startMs >= offsetMs && word.endMs <= endMs && word.endMs >= word.startMs);
        projectedWords.push(
          JSON.stringify([
            `${interval.submissionId}:${channelIndex}`,
            trackId,
            word.speaker === undefined ? null : String(word.speaker),
            word.punctuated_word ?? word.word,
            word.startMs,
            word.endMs,
            word.confidence ?? null,
          ]),
        );
      }
      const events = expectedEvents.filter(
        (event) =>
          event.channel === channelIndex && event.startMs >= offsetMs && event.endMs <= endMs,
      );
      let assignedWords = 0;
      for (const [eventIndex, event] of events.entries()) {
        const previous = events[eventIndex - 1];
        const next = events[eventIndex + 1];
        const slotStartMs =
          previous === undefined ? offsetMs : (previous.endMs + event.startMs) / 2;
        const slotEndMs = next === undefined ? endMs : (event.endMs + next.startMs) / 2;
        const matched = absolute.filter(
          (word) =>
            (word.startMs + word.endMs) / 2 >= slotStartMs &&
            (word.startMs + word.endMs) / 2 < slotEndMs,
        );
        assert.ok(matched.length > 0, `Missing source event ${channelIndex}/${event.startMs}`);
        assert.ok(
          matched.some(
            (word) => word.word.toLowerCase() === markerWords[template.language]?.[event.marker],
          ),
          `Missing ${event.marker} marker at ${channelIndex}/${event.startMs}`,
        );
        assignedWords += matched.length;
        wordsOutside500MsSpeechWindows += matched.filter(
          (word) => word.startMs < event.startMs - 500 || word.endMs > event.endMs + 500,
        ).length;
        sourceEvents.push({
          channel: channelIndex,
          voice: event.voice,
          startMs: event.startMs,
          wordCount: matched.length,
          startErrorMs: Math.abs((matched[0]?.startMs ?? 0) - event.startMs),
          endErrorMs: Math.abs((matched.at(-1)?.endMs ?? 0) - event.endMs),
          labels: [...new Set(matched.map((word) => String(word.speaker ?? "unknown")))],
        });
      }
      assert.equal(
        assignedWords,
        absolute.length,
        "Words outside midpoint-separated source event slots or overlapping assignments",
      );
      return {
        channel: channelIndex,
        words: words.length,
        labels: [...new Set(words.map((word) => String(word.speaker ?? "unknown")))],
        lastWordEndMs: absolute.at(-1)?.endMs ?? null,
      };
    });
    return {
      submissionId: interval.submissionId,
      startMs: offsetMs,
      endMs,
      rawSha256: hash(bytes),
      rawBytes: bytes.byteLength,
      neurons: raw.usage?.neurons ?? null,
      deliveryWitness: witness.transport?.deliveryWitness ?? "legacy-producer-hash-v1",
      channels,
    };
  });
  assert.equal(intervalCursor, plan.master.frameCount);
  const strictEOF = observations.every((item) => item.deliveryWitness === "consumer-eof-v1");
  assert.equal(provenance.allConsumerEOFVerified ?? false, strictEOF);
  const scopeIds = new Map<string, string>();
  const scopeKeys = new Map<string, string>();
  const speakerIds = new Map<string, string>();
  const usedSpeakers = new Set<string>();
  const canonicalWords = revision.turns.flatMap((turn) => {
    assert.ok(turn.words.length > 0);
    assert.equal(turn.text, turn.words.map((word) => word.text).join(" "));
    assert.equal(turn.startMs, turn.words[0]?.startMs);
    assert.equal(turn.endMs, turn.words.at(-1)?.endMs);
    const interval = plan.intervals.find(
      (item) => turn.startMs >= item.startFrame / 16 && turn.endMs <= item.endFrame / 16,
    );
    assert.ok(interval, "A normalized turn crosses submission scopes");
    const channel = turn.trackId === plan.master.microphoneTrackId ? 0 : 1;
    assert.equal(
      turn.trackId,
      channel === 0 ? plan.master.microphoneTrackId : plan.master.applicationTrackId,
    );
    const scopeKey = `${interval.submissionId}:${channel}`;
    const speaker = revision.speakers.find((item) => item.speakerId === turn.speakerId);
    if (turn.speakerId !== null) {
      assert.ok(speaker);
      assert.equal(speaker.trackId, turn.trackId);
      assert.equal(
        scopeIds.get(scopeKey) ?? speaker.diarizationScopeId,
        speaker.diarizationScopeId,
      );
      assert.equal(scopeKeys.get(speaker.diarizationScopeId) ?? scopeKey, scopeKey);
      scopeIds.set(scopeKey, speaker.diarizationScopeId);
      scopeKeys.set(speaker.diarizationScopeId, scopeKey);
      const speakerKey = `${scopeKey}:${speaker.providerLabel}`;
      assert.equal(speakerIds.get(speakerKey) ?? speaker.speakerId, speaker.speakerId);
      speakerIds.set(speakerKey, speaker.speakerId);
      usedSpeakers.add(speaker.speakerId);
    }
    return turn.words.map((word) =>
      JSON.stringify([
        scopeKey,
        turn.trackId,
        speaker?.providerLabel ?? null,
        word.text,
        word.startMs,
        word.endMs,
        word.confidence,
      ]),
    );
  });
  assert.equal(usedSpeakers.size, revision.speakers.length);
  assert.deepEqual(
    canonicalWords.sort(),
    projectedWords.sort(),
    "Canonical words differ from exact provider evidence",
  );
  assert.equal(sourceEvents.length, expectedEvents.length);
  const result = {
    schemaVersion: 1,
    fixture: plan.fixture,
    language: template.language,
    masterSha256: plan.master.sha256,
    masterBytes: plan.master.byteLength,
    durationMs,
    allConsumerEOFVerified: strictEOF,
    sourceEvents: sourceEvents.length,
    words: projectedWords.length,
    wordsOutside500MsSpeechWindows,
    maximumEventStartErrorMs: Math.max(0, ...sourceEvents.map((event) => event.startErrorMs)),
    maximumEventEndErrorMs: Math.max(0, ...sourceEvents.map((event) => event.endErrorMs)),
    normalizedSpeakers: revision.speakers.length,
    normalizedScopes: new Set(revision.speakers.map((speaker) => speaker.diarizationScopeId)).size,
    submissions: observations,
  };
  writeFileSync(join(directory, "acceptance.json"), JSON.stringify(result, null, 2) + "\n", {
    mode: 0o600,
  });
  return result;
}

if (import.meta.main) {
  const [template, directory, legacy] = process.argv.slice(2);
  assert.ok(
    template && directory,
    "Usage: bun scripts/asr-master-acceptance.ts TEMPLATE.caf.json FIXTURE_DIRECTORY [--allow-legacy]",
  );
  assert.ok(legacy === undefined || legacy === "--allow-legacy");
  process.stdout.write(
    JSON.stringify(
      checkHostedMasterAcceptance(template, directory, legacy === "--allow-legacy"),
      null,
      2,
    ) + "\n",
  );
}
