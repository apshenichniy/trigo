import {
  AsrProbeLanguage,
  AsrProbeTranscriptionResponse,
  AsrProbeUploadResponse,
  inspectWaveObject,
  selectedMediaProfile,
  storedByteHash,
  type AsrProbeLanguageCode,
  type AudioManifest,
} from "@trigo/contracts";
import { Clock, DateTime, Effect, Schema } from "effect";
import { normalizeNova3 } from "./nova-3.ts";

type ProbeLanguage = AsrProbeLanguageCode;

export interface Nova3Runner {
  readonly run: (
    model: string,
    input: Record<string, unknown>,
    options?: Record<string, unknown>,
  ) => Promise<unknown>;
}

export interface AsrProbeEnvironment {
  readonly ARCHIVE: Pick<R2Bucket, "get" | "put" | "delete">;
  readonly AI: Nova3Runner;
}

export class AsrProbeError extends Schema.TaggedError<AsrProbeError>()("AsrProbe.Error", {
  status: Schema.Int,
  code: Schema.String,
  retry: Schema.Literals(["never", "after_correction", "retryable"]),
  message: Schema.String,
}) {}
const isAsrProbeError = Schema.is(AsrProbeError);

class ProviderInvocationError extends Schema.TaggedError<ProviderInvocationError>()(
  "AsrProbe.ProviderInvocationError",
  {
    name: Schema.String,
    message: Schema.String,
  },
) {}

const encodePrettyJson = Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown, { space: 2 }));

function probeError(
  status: number,
  code: string,
  retry: "never" | "after_correction" | "retryable",
  message: string,
): AsrProbeError {
  return new AsrProbeError({ status, code, retry, message });
}

function providerInvocationError(cause: unknown): ProviderInvocationError {
  const name =
    typeof cause === "object" && cause !== null && typeof Reflect.get(cause, "name") === "string"
      ? String(Reflect.get(cause, "name"))
      : "UnknownProviderError";
  const message =
    typeof cause === "object" && cause !== null && typeof Reflect.get(cause, "message") === "string"
      ? String(Reflect.get(cause, "message"))
      : String(cause);
  return new ProviderInvocationError({
    name: name.slice(0, 128),
    message: message.slice(0, 1_024),
  });
}

function parseLanguage(url: URL): ProbeLanguage {
  try {
    return Schema.decodeUnknownSync(AsrProbeLanguage)(url.searchParams.get("language"));
  } catch {
    throw probeError(
      400,
      "asr_probe_language_invalid",
      "after_correction",
      "Use an explicit language=en, language=ru, or language=uk selector.",
    );
  }
}

function keysFor(fixture: string, language: ProbeLanguage) {
  const root = `acceptance/issue-13/${fixture}`;
  return {
    input: `${root}/input.wav`,
    manifest: `${root}/${language}/audio-manifest.json`,
    raw: `${root}/${language}/provider-result.json`,
    providerError: `${root}/${language}/provider-error.json`,
    normalized: `${root}/${language}/normalized-revision.json`,
  };
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 16_384)
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 16_384));
  return btoa(binary);
}

const upload = Effect.fn("AsrProbe.upload")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
  language: ProbeLanguage,
) {
  const keys = keysFor(fixture, language);
  const existing = yield* Effect.tryPromise({
    try: () =>
      Promise.all([
        env.ARCHIVE.get(keys.input),
        env.ARCHIVE.get(keys.raw),
        env.ARCHIVE.get(keys.providerError),
      ]),
    catch: () =>
      probeError(503, "asr_probe_storage_failed", "retryable", "Private fixture lookup failed."),
  });
  if (existing.some((object) => object !== null))
    return yield* probeError(
      409,
      "asr_probe_attempt_exists",
      "after_correction",
      "Delete this exact task-owned fixture before deliberately creating another attempt.",
    );
  if (request.headers.get("content-type") !== selectedMediaProfile.contentType)
    return yield* probeError(
      415,
      "asr_probe_media_type_invalid",
      "after_correction",
      `Use ${selectedMediaProfile.contentType} for the selected media profile.`,
    );
  if (request.headers.get("x-trigo-media-profile") !== selectedMediaProfile.id)
    return yield* probeError(
      409,
      "asr_probe_profile_mismatch",
      "after_correction",
      `Use the selected media profile ${selectedMediaProfile.id}.`,
    );

  const bytes = yield* Effect.tryPromise({
    try: () => request.arrayBuffer().then((buffer) => new Uint8Array(buffer)),
    catch: () =>
      probeError(400, "asr_probe_body_invalid", "after_correction", "Read the WAVE body again."),
  });
  const inspection = yield* Effect.try({
    try: () => inspectWaveObject(bytes),
    catch: () =>
      probeError(
        422,
        "asr_probe_profile_mismatch",
        "after_correction",
        "The WAVE bytes do not match the selected media profile.",
      ),
  });
  yield* Effect.tryPromise({
    try: () =>
      env.ARCHIVE.put(keys.input, bytes, {
        httpMetadata: { contentType: selectedMediaProfile.contentType },
        customMetadata: { mediaProfileId: selectedMediaProfile.id },
      }),
    catch: () =>
      probeError(503, "asr_probe_storage_failed", "retryable", "Private fixture storage failed."),
  });
  return Response.json(
    AsrProbeUploadResponse.make({
      fixture,
      language,
      profileId: selectedMediaProfile.id,
      byteLength: inspection.byteLength,
      durationMs: inspection.durationMs,
      inputKey: keys.input,
    }),
    { status: 201 },
  );
});

const transcribe = Effect.fn("AsrProbe.transcribe")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
  language: ProbeLanguage,
) {
  const keys = keysFor(fixture, language);
  const completedAttempt = yield* Effect.tryPromise({
    try: () => Promise.all([env.ARCHIVE.get(keys.raw), env.ARCHIVE.get(keys.providerError)]),
    catch: () =>
      probeError(503, "asr_probe_storage_failed", "retryable", "Private attempt lookup failed."),
  });
  if (completedAttempt.some((object) => object !== null))
    return yield* probeError(
      409,
      "asr_probe_attempt_exists",
      "after_correction",
      "The bounded provider attempt already has retained evidence and will not be repeated.",
    );
  const object = yield* Effect.tryPromise({
    try: () => env.ARCHIVE.get(keys.input),
    catch: () =>
      probeError(503, "asr_probe_storage_failed", "retryable", "Private fixture read failed."),
  });
  if (object === null)
    return yield* probeError(
      404,
      "asr_probe_fixture_missing",
      "after_correction",
      "Upload the controlled fixture before running inference.",
    );
  if (object.customMetadata?.mediaProfileId !== selectedMediaProfile.id)
    return yield* probeError(
      409,
      "asr_probe_profile_mismatch",
      "after_correction",
      "The stored fixture does not declare the selected media profile.",
    );
  const bytes = yield* Effect.tryPromise({
    try: () => object.arrayBuffer().then((buffer) => new Uint8Array(buffer)),
    catch: () =>
      probeError(503, "asr_probe_storage_failed", "retryable", "Private fixture read failed."),
  });
  const inspection = yield* Effect.try({
    try: () => inspectWaveObject(bytes),
    catch: () =>
      probeError(
        422,
        "asr_probe_profile_mismatch",
        "after_correction",
        "The stored fixture no longer matches the selected media profile.",
      ),
  });

  const providerStartedAt = yield* Clock.currentTimeMillis;
  const providerResult = yield* Effect.tryPromise({
    try: () =>
      env.AI.run(selectedMediaProfile.asr.model, {
        audio: {
          body: bytesToBase64(bytes),
          contentType: selectedMediaProfile.asr.requestContentType,
        },
        language,
        channels: selectedMediaProfile.asr.channels,
        multichannel: selectedMediaProfile.asr.multichannel,
        diarize: selectedMediaProfile.asr.diarize,
        punctuate: true,
        smart_format: true,
      }),
    catch: providerInvocationError,
  }).pipe(
    Effect.catchTag("AsrProbe.ProviderInvocationError", (failure) =>
      Effect.gen(function* () {
        const failureBytes = new TextEncoder().encode(
          yield* encodePrettyJson({
            model: selectedMediaProfile.asr.model,
            profileId: selectedMediaProfile.id,
            language,
            failure: { name: failure.name, message: failure.message },
          }).pipe(Effect.orDie),
        );
        yield* Effect.tryPromise({
          try: () =>
            env.ARCHIVE.put(keys.providerError, failureBytes, {
              httpMetadata: { contentType: "application/json" },
              customMetadata: { mediaProfileId: selectedMediaProfile.id, language },
            }),
          catch: () =>
            probeError(
              503,
              "asr_probe_storage_failed",
              "retryable",
              "Private provider-failure storage failed.",
            ),
        });
        return yield* probeError(
          502,
          "asr_probe_provider_failed",
          "retryable",
          `Cloudflare-hosted Nova-3 failed with ${failure.name}: ${failure.message}`,
        );
      }),
    ),
  );
  const providerLatencyMs = (yield* Clock.currentTimeMillis) - providerStartedAt;

  const rawBytes = new TextEncoder().encode(
    yield* encodePrettyJson(providerResult).pipe(Effect.orDie),
  );
  yield* Effect.tryPromise({
    try: () =>
      env.ARCHIVE.put(keys.raw, rawBytes, {
        httpMetadata: { contentType: "application/json" },
        customMetadata: { mediaProfileId: selectedMediaProfile.id, language },
      }),
    catch: () =>
      probeError(
        503,
        "asr_probe_storage_failed",
        "retryable",
        "Raw provider-result storage failed.",
      ),
  });

  // oxlint-disable-next-line effecttsgo/crypto-random-uuid -- Probe identities are persisted evidence, never provider IDs.
  const makeId = () => crypto.randomUUID();
  const callId = makeId();
  const manifestId = makeId();
  const objectId = makeId();
  const microphoneTrackId = makeId();
  const applicationTrackId = makeId();
  const channelMap = [
    { channelIndex: 0, trackId: microphoneTrackId },
    { channelIndex: 1, trackId: applicationTrackId },
  ] as const;
  const audioManifest = {
    schemaVersion: 1,
    callId,
    manifestId,
    durationMs: inspection.durationMs,
    mediaProfileId: selectedMediaProfile.id,
    objects: [
      {
        objectId,
        index: 0,
        contentType: selectedMediaProfile.contentType,
        byteLength: bytes.byteLength,
        sha256: yield* Effect.promise(() => storedByteHash(bytes)),
        startMs: 0,
        endMs: inspection.durationMs,
        channelMap: [...channelMap],
      },
    ],
  } satisfies AudioManifest;
  const manifestText = yield* encodePrettyJson(audioManifest).pipe(Effect.orDie);
  const manifestBytes = new TextEncoder().encode(manifestText);
  const manifestSha256 = yield* Effect.promise(() => storedByteHash(manifestBytes));
  const createdAt = DateTime.formatIso(yield* DateTime.now);
  const normalized = yield* normalizeNova3({
    callId,
    revisionId: makeId(),
    createdAt,
    audioManifest: { manifestId, sha256: manifestSha256 },
    requestedLanguage: language,
    detectedLanguages: [],
    tracks: [
      { trackId: microphoneTrackId, role: "microphone" },
      { trackId: applicationTrackId, role: "application" },
    ],
    objects: [
      {
        objectId,
        index: 0,
        startMs: 0,
        endMs: inspection.durationMs,
        channelMap,
        providerRequestId: null,
        response: providerResult,
      },
    ],
    makeId,
  }).pipe(
    Effect.mapError(() =>
      probeError(
        502,
        "asr_probe_normalization_failed",
        "after_correction",
        "The raw result was retained, but it cannot prove the required normalized contract.",
      ),
    ),
  );
  const normalizedBytes = new TextEncoder().encode(
    yield* encodePrettyJson(normalized).pipe(Effect.orDie),
  );

  yield* Effect.tryPromise({
    try: () =>
      Promise.all([
        env.ARCHIVE.put(keys.manifest, manifestBytes, {
          httpMetadata: { contentType: "application/json" },
          customMetadata: { mediaProfileId: selectedMediaProfile.id, language },
        }),
        env.ARCHIVE.put(keys.normalized, normalizedBytes, {
          httpMetadata: { contentType: "application/json" },
          customMetadata: { mediaProfileId: selectedMediaProfile.id, language },
        }),
      ]).then(() => undefined),
    catch: () =>
      probeError(
        503,
        "asr_probe_storage_failed",
        "retryable",
        "Normalized provider-result storage failed.",
      ),
  });

  return Response.json(
    AsrProbeTranscriptionResponse.make({
      fixture,
      language,
      profileId: selectedMediaProfile.id,
      byteLength: bytes.byteLength,
      durationMs: inspection.durationMs,
      providerLatencyMs,
      channelCount: selectedMediaProfile.channels.length,
      speakerCount: normalized.speakers.length,
      turnCount: normalized.turns.length,
      retained: {
        inputKey: keys.input,
        manifestKey: keys.manifest,
        rawProviderKey: keys.raw,
        normalizedRevisionKey: keys.normalized,
      },
    }),
  );
});

const cleanup = Effect.fn("AsrProbe.cleanup")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
  language: ProbeLanguage,
) {
  const keys = keysFor(fixture, language);
  yield* Effect.tryPromise({
    try: () =>
      env.ARCHIVE.delete([
        keys.input,
        keys.manifest,
        keys.raw,
        keys.providerError,
        keys.normalized,
      ]),
    catch: () => probeError(503, "asr_probe_storage_failed", "retryable", "Probe cleanup failed."),
  });
  return new Response(null, { status: 204 });
});

export const asrProbeResponse = Effect.fn("AsrProbe.response")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
) {
  const language = yield* Effect.try({
    try: () => parseLanguage(new URL(request.url)),
    catch: (cause) =>
      isAsrProbeError(cause)
        ? cause
        : probeError(400, "asr_probe_language_invalid", "after_correction", "Invalid language."),
  });
  if (fixture !== `two-source-${language}`)
    return yield* probeError(
      400,
      "asr_probe_fixture_invalid",
      "after_correction",
      "The controlled fixture name must match its explicit language.",
    );
  if (request.method === "PUT") return yield* upload(request, env, fixture, language);
  if (request.method === "POST") return yield* transcribe(env, fixture, language);
  if (request.method === "DELETE") return yield* cleanup(env, fixture, language);
  return new Response(null, { status: 405 });
});
