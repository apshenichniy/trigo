import { DateTime, Effect, Schema } from "effect";

import {
  AsrProbeLanguage,
  CanonicalUUIDv4,
  storedByteHash,
  validateDocument,
} from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { AsrExtractionEvidence, AsrMaster } from "./asr-master.ts";
import { Nova3NormalizationError, Nova3NormalizationInput, normalizeNova3 } from "./nova-3.ts";

const ProviderMetadata = Schema.Struct({
  metadata: Schema.optionalKey(
    Schema.Struct({
      request_id: Schema.optionalKey(Schema.NonEmptyString),
      duration: Schema.optionalKey(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
      channels: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThan(0))),
      model_info: Schema.optionalKey(
        Schema.Record(
          Schema.String,
          Schema.Struct({ version: Schema.optionalKey(Schema.NonEmptyString) }),
        ),
      ),
    }),
  ),
  results: Schema.optionalKey(
    Schema.Struct({
      channels: Schema.optionalKey(
        Schema.Array(
          Schema.Struct({ detected_language: Schema.optionalKey(Schema.NonEmptyString) }),
        ),
      ),
    }),
  ),
});

export const Nova3SubmissionTransport = Schema.Struct({
  deliveryWitness: Schema.Literals(["consumer-eof-v1", "legacy-producer-hash-v1", "unobserved"]),
  deliveredByteLength: Schema.NullOr(Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))),
  responseBodyComplete: Schema.NullOr(Schema.Boolean),
  providerHttpStatus: Schema.NullOr(
    Schema.Int.check(Schema.isBetween({ minimum: 100, maximum: 599 })),
  ),
});

export const Nova3MasterSubmission = Schema.Struct({
  extraction: AsrExtractionEvidence,
  rawArtifactKey: Schema.NonEmptyString,
  rawBytes: Schema.Uint8Array,
  providerRequestId: Schema.NullOr(Schema.NonEmptyString),
  transport: Schema.optionalKey(Nova3SubmissionTransport),
});
export interface Nova3MasterSubmission extends Schema.Schema.Type<typeof Nova3MasterSubmission> {}

const NormalizationInput = Schema.Struct({
  master: AsrMaster,
  revisionId: CanonicalUUIDv4,
  createdAt: Schema.DateTimeUtcFromString,
  requestedLanguage: AsrProbeLanguage,
  submissions: Schema.Array(Nova3MasterSubmission).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(180),
  ),
  makeId: Nova3NormalizationInput.fields.makeId,
});

const sameMaster = Schema.toEquivalence(AsrMaster);
const parseJson = Schema.decodeUnknownEffect(Schema.fromJsonString(Schema.Unknown));

function failure(message: string) {
  return new Nova3NormalizationError({ operation: "Nova3.normalizeMaster", message });
}

/** Returns immutable transcript evidence and its independently retained transformation provenance. */
export const normalizeNova3Master = Effect.fn("Nova3.normalizeMaster")(function* (
  unknownInput: unknown,
) {
  const input = yield* Schema.decodeUnknownEffect(NormalizationInput)(unknownInput).pipe(
    Effect.mapError(() => failure("Invalid master normalization input")),
  );
  let cursor = 0;
  const submissionIds = new Set<string>();
  const rawKeys = new Set<string>();
  const detectedLanguages = new Set<string>();
  const modelVersions = new Set<string>();

  const submissions = yield* Effect.forEach(input.submissions, (submission, index) =>
    Effect.gen(function* () {
      const { extraction } = submission;
      const { interval } = extraction;
      const transport =
        submission.transport ??
        Nova3SubmissionTransport.make({
          deliveryWitness: "unobserved",
          deliveredByteLength: null,
          responseBodyComplete: null,
          providerHttpStatus: null,
        });
      if (
        transport.deliveryWitness === "consumer-eof-v1" &&
        (transport.deliveredByteLength !== extraction.byteLength ||
          transport.responseBodyComplete !== true ||
          transport.providerHttpStatus !== 200)
      ) {
        return yield* failure(
          "Consumer EOF evidence must cover the exact input and a complete successful response",
        );
      }
      if (
        !sameMaster(extraction.master, input.master) ||
        interval.index !== index ||
        interval.startFrame !== cursor ||
        interval.endFrame > input.master.frameCount ||
        submissionIds.has(interval.submissionId) ||
        rawKeys.has(submission.rawArtifactKey)
      ) {
        return yield* failure(
          "Submissions must cover the exact master once, in order, with independent identities and raw artifacts",
        );
      }
      cursor = interval.endFrame;
      submissionIds.add(interval.submissionId);
      rawKeys.add(submission.rawArtifactKey);
      const text = yield* Effect.try({
        try: () => new TextDecoder("utf-8", { fatal: true }).decode(submission.rawBytes),
        catch: () => failure("Provider evidence is not valid UTF-8"),
      });
      const response = yield* parseJson(text).pipe(
        Effect.mapError(() => failure("Provider evidence is not valid JSON")),
      );
      const metadata = yield* Schema.decodeUnknownEffect(ProviderMetadata)(response).pipe(
        Effect.mapError(() => failure("Provider metadata is invalid")),
      );
      const reportedDurationSeconds = metadata.metadata?.duration ?? null;
      if (
        reportedDurationSeconds !== null &&
        Math.abs(reportedDurationSeconds * 16_000 - (interval.endFrame - interval.startFrame)) > 1
      ) {
        return yield* failure("Provider duration does not match the complete submitted interval");
      }
      if (metadata.metadata?.channels !== undefined && metadata.metadata.channels !== 2) {
        return yield* failure("Provider metadata does not preserve both channels");
      }
      for (const channel of metadata.results?.channels ?? []) {
        if (channel.detected_language !== undefined) {
          detectedLanguages.add(channel.detected_language);
        }
      }
      const versions = Object.values(metadata.metadata?.model_info ?? {}).flatMap((model) =>
        model.version === undefined ? [] : [model.version],
      );
      for (const version of versions) {
        modelVersions.add(version);
      }
      const providerRequestId =
        submission.providerRequestId ?? metadata.metadata?.request_id ?? null;
      return {
        response,
        object: {
          objectId: interval.submissionId,
          index,
          startMs: extraction.startMs,
          endMs: extraction.endMs,
          channelMap: [
            { channelIndex: 0, trackId: input.master.microphoneTrackId },
            { channelIndex: 1, trackId: input.master.applicationTrackId },
          ],
          providerRequestId,
          response,
        },
        evidence: {
          extraction,
          transport,
          rawArtifact: {
            key: submission.rawArtifactKey,
            sha256: yield* Effect.promise(() => storedByteHash(submission.rawBytes)),
            byteLength: submission.rawBytes.byteLength,
          },
          providerRequestId,
          returnedRequestId: metadata.metadata?.request_id ?? null,
          reportedDurationSeconds,
          returnedModelVersions: versions,
        },
      };
    }),
  );
  if (cursor !== input.master.frameCount) {
    return yield* failure("The final submission does not cover the complete retained master");
  }

  const normalized = yield* normalizeNova3({
    callId: input.master.callId,
    revisionId: input.revisionId,
    createdAt: DateTime.formatIso(input.createdAt),
    audioManifest: { manifestId: input.master.manifestId, sha256: input.master.manifestSha256 },
    requestedLanguage: input.requestedLanguage,
    detectedLanguages: [...detectedLanguages],
    tracks: [
      { trackId: input.master.microphoneTrackId, role: "microphone" },
      { trackId: input.master.applicationTrackId, role: "application" },
    ],
    objects: submissions.map((submission) => submission.object),
    makeId: input.makeId,
  });
  const revision = yield* Effect.try({
    try: () =>
      validateDocument("TranscriptRevision", {
        schemaVersion: normalized.schemaVersion,
        callId: normalized.callId,
        revisionId: normalized.revisionId,
        createdAt: normalized.createdAt,
        audioManifest: normalized.audioManifest,
        normalizationVersion: normalized.normalizationVersion,
        speakers: normalized.speakers,
        turns: normalized.turns,
        asr: {
          ...normalized.asr,
          profileId: nova3StreamProfile.id,
          returnedModelVersion: modelVersions.size === 1 ? ([...modelVersions][0] ?? null) : null,
        },
      }),
    catch: () => failure("Normalized master evidence does not satisfy the transcript contract"),
  });
  return {
    revision,
    provenance: {
      schemaVersion: 1,
      callId: input.master.callId,
      revisionId: input.revisionId,
      profileId: nova3StreamProfile.id,
      master: input.master,
      allConsumerEOFVerified: submissions.every(
        (submission) => submission.evidence.transport.deliveryWitness === "consumer-eof-v1",
      ),
      submissions: submissions.map((submission) => submission.evidence),
    },
  };
});
