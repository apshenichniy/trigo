import { DateTime, Effect, Schema } from "effect";

import {
  AsrProbeLanguage,
  CanonicalUUIDv4,
  SHA256,
  storedByteHash,
  validateDocument,
  type TranscriptRevision,
} from "@trigo/contracts";

import { assemblyAIStereoProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { AsrExtractionEvidence, AsrMaster } from "./asr-master.ts";
import { AssemblyAIJobId, inspectAssemblyAIResult } from "./assemblyai-response.ts";
import {
  alignTranscriptWords,
  followsTranscriptPause,
  interleaveTrackTurns,
} from "./transcript-timing.ts";
import { transcriptionError } from "./transcription-errors.ts";

export const AssemblyAIUploadWitness = Schema.Struct({
  deliveryWitness: Schema.Literal("http-upload-ack-v1"),
  uploadURL: Schema.NonEmptyString,
  uploadedByteLength: Schema.Int.check(Schema.isGreaterThan(44)),
  inputSHA256: SHA256,
  uploadHttpStatus: Schema.Literal(200),
});
export interface AssemblyAIUploadWitness extends Schema.Schema.Type<
  typeof AssemblyAIUploadWitness
> {}

export const AssemblyAIMasterSubmission = Schema.Struct({
  extraction: AsrExtractionEvidence,
  rawArtifactKey: Schema.NonEmptyString,
  rawBytes: Schema.Uint8Array,
  providerRequestId: AssemblyAIJobId,
  transport: AssemblyAIUploadWitness,
});
export interface AssemblyAIMasterSubmission extends Schema.Schema.Type<
  typeof AssemblyAIMasterSubmission
> {}

const Input = Schema.Struct({
  master: AsrMaster,
  revisionId: CanonicalUUIDv4,
  createdAt: Schema.DateTimeUtcFromString,
  requestedLanguage: AsrProbeLanguage,
  submissions: Schema.Array(AssemblyAIMasterSubmission).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(2),
  ),
  makeId: Schema.declare((value): value is () => string => typeof value === "function", {
    expected: "UUID factory",
  }),
});
const sameMaster = Schema.toEquivalence(AsrMaster);

export const normalizeAssemblyAIMaster = Effect.fn("AssemblyAI.normalizeMaster")(function* (
  unknownInput: unknown,
) {
  const input = yield* Schema.decodeUnknownEffect(Input)(unknownInput).pipe(
    Effect.mapError(() => transcriptionError("asr_result_invalid")),
  );
  const turns: TranscriptRevision["turns"][number][] = [];
  const speakers: TranscriptRevision["speakers"][number][] = [];
  const provenance = [];
  const submissions = new Set<string>();
  const providerIds = new Set<string>();
  const rawKeys = new Set<string>();
  let cursor = 0;
  for (const [index, submission] of input.submissions.entries()) {
    const { extraction, transport } = submission;
    const { interval } = extraction;
    if (
      !sameMaster(extraction.master, input.master) ||
      interval.index !== index ||
      interval.startFrame !== cursor ||
      interval.endFrame > input.master.frameCount ||
      extraction.endMs - extraction.startMs > assemblyAIStereoProfile.maxSubmissionDurationMs ||
      transport.uploadedByteLength !== extraction.byteLength ||
      transport.inputSHA256 !== extraction.sha256 ||
      submissions.has(interval.submissionId) ||
      providerIds.has(submission.providerRequestId) ||
      rawKeys.has(submission.rawArtifactKey)
    ) {
      return yield* transcriptionError("asr_result_invalid");
    }
    cursor = interval.endFrame;
    submissions.add(interval.submissionId);
    providerIds.add(submission.providerRequestId);
    rawKeys.add(submission.rawArtifactKey);
    const response = yield* inspectAssemblyAIResult(submission.rawBytes, extraction, {
      providerId: submission.providerRequestId,
      uploadURL: transport.uploadURL,
      language: input.requestedLanguage,
    });
    yield* Effect.try({
      try: () => {
        for (const [channel, trackId] of [
          [1, input.master.microphoneTrackId],
          [2, input.master.applicationTrackId],
        ] as const) {
          const words = alignTranscriptWords(
            (response.words ?? [])
              .filter((word) => Number(word.channel) === channel)
              .map((word) => ({
                label: word.speaker ?? null,
                text: word.text,
                confidence: word.confidence,
                startMs: extraction.startMs + word.start,
                endMs: extraction.startMs + word.end,
              })),
            extraction.startMs,
            extraction.endMs,
          );
          let scopeId: string | undefined;
          const speakerIds = new Map<string, string>();
          let current: TranscriptRevision["turns"][number]["words"][number][] = [];
          let label: string | null = null;
          const finish = () => {
            if (current.length === 0) {
              return;
            }
            let speakerId: string | null = null;
            if (label !== null) {
              scopeId ??= CanonicalUUIDv4.make(input.makeId());
              speakerId = speakerIds.get(label) ?? null;
              if (speakerId === null) {
                speakerId = CanonicalUUIDv4.make(input.makeId());
                speakerIds.set(label, speakerId);
                speakers.push({
                  speakerId,
                  trackId,
                  diarizationScopeId: scopeId,
                  providerLabel: label,
                });
              }
            }
            const bound = (time: number) =>
              Math.min(extraction.endMs, Math.max(extraction.startMs, time));
            let startMs = extraction.endMs;
            let endMs = extraction.startMs;
            for (const word of current) {
              startMs = Math.min(startMs, bound(Math.min(word.startMs, word.endMs)));
              endMs = Math.max(endMs, bound(Math.max(word.startMs, word.endMs)));
            }
            turns.push({
              turnId: CanonicalUUIDv4.make(input.makeId()),
              trackId,
              speakerId,
              startMs,
              endMs,
              text: current.map((word) => word.text).join(" "),
              words: current,
            });
            current = [];
          };
          for (const word of words) {
            if (word.label !== label || followsTranscriptPause(current.at(-1), word.normalized)) {
              finish();
            }
            label = word.label;
            current.push(word.normalized);
          }
          finish();
        }
      },
      catch: () => transcriptionError("asr_result_invalid"),
    });
    provenance.push({
      extraction,
      transport,
      providerRequestId: submission.providerRequestId,
      returnedModel: response.speech_model_used,
      reportedDurationSeconds: response.audio_duration,
      rawArtifact: {
        key: submission.rawArtifactKey,
        sha256: yield* Effect.promise(() => storedByteHash(submission.rawBytes)),
        byteLength: submission.rawBytes.byteLength,
      },
    });
  }
  if (cursor !== input.master.frameCount) {
    return yield* transcriptionError("asr_result_invalid");
  }
  const revision = yield* Effect.try({
    try: () =>
      validateDocument("TranscriptRevision", {
        schemaVersion: 1,
        callId: input.master.callId,
        revisionId: input.revisionId,
        createdAt: DateTime.formatIso(input.createdAt),
        audioManifest: { manifestId: input.master.manifestId, sha256: input.master.manifestSha256 },
        normalizationVersion: 2,
        asr: {
          adapter: "assemblyai",
          model: assemblyAIStereoProfile.model,
          profileId: assemblyAIStereoProfile.id,
          requestedLanguage: input.requestedLanguage,
          detectedLanguages: [input.requestedLanguage],
          effectiveOptions: {
            multichannel: true,
            speaker_labels: true,
            punctuate: true,
            format_text: true,
            language_detection: false,
            region: "eu",
            passageGapMs: 1_200,
          },
          returnedModelVersion: assemblyAIStereoProfile.model,
          providerRequestIds: [...providerIds],
        },
        speakers,
        turns: interleaveTrackTurns(turns),
      }),
    catch: () => transcriptionError("asr_result_invalid"),
  });
  return {
    revision,
    provenance: {
      schemaVersion: 1,
      callId: input.master.callId,
      revisionId: input.revisionId,
      profileId: assemblyAIStereoProfile.id,
      master: input.master,
      allUploadsAcknowledged: true,
      submissions: provenance,
    },
  };
});
