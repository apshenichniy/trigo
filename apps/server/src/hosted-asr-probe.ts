import { Clock, DateTime, Effect, Schema } from "effect";

import { AsrProbeLanguage, inspectWaveObject, storedByteHash } from "@trigo/contracts";

import { AsrProbeError, type AsrProbeEnvironment } from "./asr-probe.ts";
import { readBoundedBody, submitNova3Stream } from "./nova-3-transport.ts";

const Fixture = Schema.String.check(Schema.isPattern(/^[a-z0-9][a-z0-9-]{0,79}$/));
const InputMetadata = Schema.Struct({
  language: AsrProbeLanguage,
  sha256: Schema.String,
  durationMs: Schema.FiniteFromString.check(Schema.isInt(), Schema.isGreaterThan(0)),
});
const json = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));

function failure(status: number, code: string, message: string) {
  return new AsrProbeError({ status, code, message, retry: "after_correction" });
}

const storage = <A>(operation: string, work: () => Promise<A>) =>
  Effect.tryPromise({
    try: work,
    catch: () =>
      failure(
        503,
        "asr_probe_storage_failed",
        `Private ${operation} failed; recover this same attempt before any new submission.`,
      ),
  });

function paths(fixture: string) {
  const root = `acceptance/issue-13/hosted-v2/${fixture}`;
  return {
    input: `${root}/input.wav`,
    admission: `${root}/admission.json`,
    raw: `${root}/raw.json`,
    failure: `${root}/failure.json`,
  };
}

const recover = Effect.fn("HostedAsrProbe.recover")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
  rawArtifact: boolean,
) {
  const keys = paths(fixture);
  const raw = yield* storage("result read", () => env.ARCHIVE.get(keys.raw));
  if (raw !== null) {
    if (rawArtifact) {
      return new Response(raw.body, {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }
    return Response.json({ fixture, state: "retained", rawKey: keys.raw, ...raw.customMetadata });
  }
  const admission = yield* storage("admission read", () => env.ARCHIVE.get(keys.admission));
  if (admission !== null) {
    return Response.json(
      {
        fixture,
        state: "uncertain",
        admissionKey: keys.admission,
        failureKey: keys.failure,
        resubmitted: false,
      },
      { status: 202 },
    );
  }
  return Response.json({ fixture, state: "not_submitted" }, { status: 404 });
});

const upload = Effect.fn("HostedAsrProbe.upload")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
  language: AsrProbeLanguage,
) {
  if (request.headers.get("content-type") !== "audio/wav") {
    return yield* failure(
      415,
      "asr_probe_input_invalid",
      "This diagnostic requires a bounded stereo WAVE control.",
    );
  }
  const bytes = yield* readBoundedBody(request.body, 4_000_000).pipe(
    Effect.mapError(() =>
      failure(
        413,
        "asr_probe_input_invalid",
        "Control input exceeds 4000000 bytes or is unreadable.",
      ),
    ),
  );
  const inspection = yield* Effect.try({
    try: () => inspectWaveObject(bytes),
    catch: () =>
      failure(
        422,
        "asr_probe_input_invalid",
        "Control input must match the retained stereo WAVE profile.",
      ),
  });
  const sha256 = yield* Effect.promise(() => storedByteHash(bytes));
  const keys = paths(fixture);
  const result = yield* storage("fixture write", () =>
    env.ARCHIVE.put(keys.input, bytes, {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "audio/wav" },
      customMetadata: { language, sha256, durationMs: String(inspection.durationMs) },
    }),
  );
  if (result === null) {
    return yield* failure(
      409,
      "asr_probe_fixture_exists",
      "This immutable fixture already exists; recover its evidence.",
    );
  }
  return Response.json(
    {
      fixture,
      inputKey: keys.input,
      sha256,
      byteLength: bytes.byteLength,
      durationMs: inspection.durationMs,
    },
    { status: 201 },
  );
});

const submit = Effect.fn("HostedAsrProbe.submit")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
  language: AsrProbeLanguage,
) {
  const keys = paths(fixture);
  const input = yield* storage("fixture read", () => env.ARCHIVE.get(keys.input));
  if (input === null) {
    return yield* failure(404, "asr_probe_fixture_missing", "Upload the controlled fixture first.");
  }
  const metadata = yield* Schema.decodeUnknownEffect(InputMetadata)(input.customMetadata).pipe(
    Effect.mapError(() =>
      failure(409, "asr_probe_fixture_invalid", "Stored fixture metadata is invalid."),
    ),
  );
  if (metadata.language !== language) {
    return yield* failure(
      409,
      "asr_probe_language_mismatch",
      "The language is pinned by the immutable fixture.",
    );
  }
  const startedAt = yield* Clock.currentTimeMillis;
  const admission = yield* storage("attempt admission", () =>
    env.ARCHIVE.put(
      keys.admission,
      json({
        fixture,
        language,
        inputKey: keys.input,
        inputSha256: metadata.sha256,
        durationMs: metadata.durationMs,
        transport: "workers-ai-binding-stream",
        admittedAt: DateTime.formatIso(DateTime.makeUnsafe(startedAt)),
      }),
      { onlyIf: { etagDoesNotMatch: "*" }, httpMetadata: { contentType: "application/json" } },
    ),
  );
  if (admission === null) {
    yield* Effect.promise(() => input.body.cancel());
    return yield* recover(env, fixture, false);
  }
  const response = yield* submitNova3Stream(
    env.AI,
    input.body,
    "audio/wav",
    language,
    input.size,
  ).pipe(Effect.result);
  const latencyMs = (yield* Clock.currentTimeMillis) - startedAt;
  if (response._tag === "Failure") {
    yield* storage("uncertainty evidence write", () =>
      env.ARCHIVE.put(
        keys.failure,
        json({
          operation: response.failure.operation,
          message: response.failure.message,
          latencyMs,
        }),
        { onlyIf: { etagDoesNotMatch: "*" }, httpMetadata: { contentType: "application/json" } },
      ),
    );
    return yield* recover(env, fixture, false);
  }
  const result = response.success;
  const sha256 = yield* Effect.promise(() => storedByteHash(result.bytes));
  yield* storage("raw result write", () =>
    env.ARCHIVE.put(keys.raw, result.bytes, {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/json" },
      customMetadata: {
        httpStatus: String(result.status),
        providerRequestId: result.requestId,
        sha256,
        providerLatencyMs: String(latencyMs),
        language,
        responseBodyComplete: String(result.responseBodyComplete),
        responseBodyProblem: result.responseBodyProblem ?? "",
        requestBodyComplete: String(result.requestBody.complete),
        deliveredByteLength: String(result.requestBody.byteLength),
      },
    }),
  );
  return yield* recover(env, fixture, false);
});

/** Dev diagnostic only: immutable fixtures, one atomic admission, no replacement/deletion path. */
export const hostedAsrProbeResponse = Effect.fn("HostedAsrProbe.response")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
) {
  const url = new URL(request.url);
  const input = yield* Schema.decodeUnknownEffect(
    Schema.Struct({ fixture: Fixture, language: AsrProbeLanguage }),
  )({ fixture, language: url.searchParams.get("language") }).pipe(
    Effect.mapError(() =>
      failure(
        400,
        "asr_probe_input_invalid",
        "Use a bounded fixture name and explicit en, ru, or uk language.",
      ),
    ),
  );
  if (request.method === "PUT") {
    return yield* upload(request, env, input.fixture, input.language);
  }
  if (request.method === "POST") {
    return yield* submit(env, input.fixture, input.language);
  }
  if (request.method === "GET") {
    return yield* recover(env, input.fixture, url.searchParams.get("artifact") === "raw");
  }
  return new Response(null, { status: 405 });
});
