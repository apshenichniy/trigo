// oxlint-disable-next-line effecttsgo/node-builtin-import -- Deterministic diagnostic identities make raw-result recovery byte-stable.
import { createHash } from "node:crypto";

import { Clock, DateTime, Effect, Schema, Stream } from "effect";

import { AsrProbeLanguage, storedByteHash } from "@trigo/contracts";

import { AsrExtractionEvidence, extractMasterWave, r2MasterSource } from "./asr-master.ts";
import { AsrProbeError, type AsrProbeEnvironment } from "./asr-probe.ts";
import {
  HostedMasterFixture,
  fixtureTemplateByteLength,
  prepareHostedMasterFixture,
  storeControlledMaster,
} from "./hosted-master-fixture.ts";
import { normalizeNova3Master, type Nova3MasterSubmission } from "./nova-3-master.ts";
import { readBoundedBody, submitNova3Stream } from "./nova-3-transport.ts";

const json = Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown));
const Index = Schema.FiniteFromString.check(
  Schema.isInt(),
  Schema.isBetween({ minimum: 0, maximum: 179 }),
);
const Duration = Schema.FiniteFromString.check(
  Schema.isInt(),
  Schema.isBetween({ minimum: 60_000, maximum: 10_800_000 }),
);

function failure(status: number, message: string) {
  return new AsrProbeError({
    status,
    code: "hosted_master_probe_failed",
    retry: "after_correction",
    message,
  });
}

const storage = <A>(work: () => Promise<A>) =>
  Effect.tryPromise({
    try: work,
    catch: () => failure(503, "Private evidence storage is unavailable; recover the same attempt"),
  });

function paths(fixture: string, index = 0) {
  const root = `acceptance/issue-13/hosted-masters/${fixture}`;
  const submission = `${root}/submissions/${index}`;
  return {
    plan: `${root}/fixture.json`,
    master: `${root}/master.caf`,
    ready: `${root}/ready.json`,
    input: `${submission}/extraction.json`,
    admission: `${submission}/admission.json`,
    raw: `${submission}/raw.json`,
    failure: `${submission}/failure.json`,
    normalized: `${root}/normalized.json`,
    provenance: `${root}/provenance.json`,
    normalization: `${root}/normalization.json`,
  };
}

const writeJson = Effect.fn("HostedMasterProbe.writeJson")(function* (
  env: AsrProbeEnvironment,
  key: string,
  value: unknown,
) {
  const text = yield* json(value).pipe(
    Effect.mapError(() => failure(422, "Evidence cannot be encoded")),
  );
  return yield* storage(() =>
    env.ARCHIVE.put(key, text, {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/json" },
    }),
  );
});

const readJson = Effect.fn("HostedMasterProbe.readJson")(function* (
  env: AsrProbeEnvironment,
  key: string,
) {
  const object = yield* storage(() => env.ARCHIVE.get(key));
  if (object === null) {
    return yield* failure(404, "The required private evidence has not been retained");
  }
  const bytes = yield* readBoundedBody(object.body, 4_000_000);
  return yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(
    new TextDecoder().decode(bytes),
  ).pipe(Effect.mapError(() => failure(409, "Stored evidence is invalid JSON")));
});

const prepare = Effect.fn("HostedMasterProbe.prepare")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
) {
  const url = new URL(request.url);
  const input = yield* Schema.decodeUnknownEffect(
    Schema.Struct({ language: AsrProbeLanguage, durationMs: Duration, intervalMs: Duration }),
  )({
    language: url.searchParams.get("language"),
    durationMs: url.searchParams.get("durationMs"),
    intervalMs: url.searchParams.get("intervalMs"),
  }).pipe(
    Effect.mapError(() => failure(400, "Explicit fixture language and durations are required")),
  );
  if (request.headers.get("content-type") !== "audio/x-caf") {
    return yield* failure(415, "The controlled input must be a 60-second CAF template");
  }
  const template = yield* readBoundedBody(request.body, fixtureTemplateByteLength);
  const started = yield* Clock.currentTimeMillis;
  const plan = yield* prepareHostedMasterFixture(
    fixture,
    input.language,
    template,
    input.durationMs,
    input.intervalMs,
    DateTime.formatIso(DateTime.makeUnsafe(started)),
    // oxlint-disable-next-line effecttsgo/crypto-random-uuid -- Durable UUIDv4 identities use the platform CSPRNG; pinned Effect Random has no UUID API.
    () => crypto.randomUUID(),
  );
  const keys = paths(fixture);
  const admitted = yield* writeJson(env, keys.plan, plan);
  if (admitted === null) {
    return yield* failure(
      409,
      "This immutable fixture already exists; recover its plan and results",
    );
  }
  yield* storeControlledMaster(env.ARCHIVE, keys.master, template, plan);
  const ready = {
    masterSha256: plan.master.sha256,
    byteLength: plan.master.byteLength,
    setupMs: (yield* Clock.currentTimeMillis) - started,
  };
  yield* writeJson(env, keys.ready, ready);
  return Response.json(
    { fixture, state: "ready", submissions: plan.intervals.length, ...ready },
    { status: 201 },
  );
});

const readPlan = Effect.fn("HostedMasterProbe.readPlan")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
) {
  const value = yield* readJson(env, paths(fixture).plan);
  return yield* Schema.decodeUnknownEffect(HostedMasterFixture)(value).pipe(
    Effect.mapError(() => failure(409, "The immutable master fixture plan is invalid")),
  );
});

const recoverSubmission = Effect.fn("HostedMasterProbe.recoverSubmission")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
  index: number,
) {
  const keys = paths(fixture, index);
  const raw = yield* storage(() => env.ARCHIVE.get(keys.raw));
  if (raw !== null) {
    yield* Effect.promise(() => raw.body.cancel());
    return { index, state: "retained", rawKey: keys.raw, ...raw.customMetadata };
  }
  const admission = yield* storage(() => env.ARCHIVE.get(keys.admission));
  if (admission !== null) {
    yield* Effect.promise(() => admission.body.cancel());
    return { index, state: "uncertain", resubmitted: false };
  }
  return { index, state: "not_submitted" };
});

const submit = Effect.fn("HostedMasterProbe.submit")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
  index: number,
) {
  const recovered = yield* recoverSubmission(env, fixture, index);
  if (recovered.state !== "not_submitted") {
    return Response.json(recovered, { status: recovered.state === "uncertain" ? 202 : 200 });
  }
  const keys = paths(fixture, index);
  const plan = yield* readPlan(env, fixture);
  yield* readJson(env, keys.ready);
  const interval = plan.intervals[index];
  if (interval === undefined) {
    return yield* failure(400, "Submission index is outside the immutable coverage plan");
  }
  const source = r2MasterSource(env.ARCHIVE, keys.master, plan.master);
  const started = yield* Clock.currentTimeMillis;
  const inspection = yield* extractMasterWave(source, plan.master, interval);
  yield* Stream.runDrain(inspection.stream);
  const extraction = yield* inspection.evidence();
  yield* writeJson(env, keys.input, extraction);
  const storedEvidence = yield* Schema.decodeUnknownEffect(AsrExtractionEvidence)(
    yield* readJson(env, keys.input),
  ).pipe(Effect.mapError(() => failure(409, "Stored extraction evidence is invalid")));
  if (!Schema.toEquivalence(AsrExtractionEvidence)(extraction, storedEvidence)) {
    return yield* failure(409, "The same submission no longer resolves to identical input bytes");
  }
  const extractionMs = (yield* Clock.currentTimeMillis) - started;
  const actual = yield* extractMasterWave(source, plan.master, interval);
  const admitted = yield* writeJson(env, keys.admission, {
    submissionId: interval.submissionId,
    inputSha256: extraction.sha256,
    inputByteLength: extraction.byteLength,
    language: plan.language,
    admittedAt: DateTime.formatIso(DateTime.makeUnsafe(yield* Clock.currentTimeMillis)),
  });
  if (admitted === null) {
    const current = yield* recoverSubmission(env, fixture, index);
    return Response.json(current, { status: current.state === "uncertain" ? 202 : 200 });
  }
  const providerStarted = yield* Clock.currentTimeMillis;
  const result = yield* Effect.gen(function* () {
    const body = yield* Stream.toReadableStreamEffect(actual.stream);
    const response = yield* submitNova3Stream(env.AI, body, "audio/wav", plan.language);
    const bytes = yield* readBoundedBody(response.body, 4_000_000);
    const consumed = yield* Effect.result(actual.evidence());
    return {
      bytes,
      status: response.status,
      requestId: response.headers.get("cf-ai-req-id") ?? "",
      fullyConsumed:
        consumed._tag === "Success" &&
        Schema.toEquivalence(AsrExtractionEvidence)(consumed.success, extraction),
    };
  }).pipe(Effect.result);
  const providerMs = (yield* Clock.currentTimeMillis) - providerStarted;
  if (result._tag === "Failure") {
    yield* writeJson(env, keys.failure, {
      operation: result.failure.operation,
      message: result.failure.message,
      extractionMs,
      providerMs,
    });
    return Response.json(yield* recoverSubmission(env, fixture, index), { status: 202 });
  }
  const raw = result.success;
  const sha256 = yield* Effect.promise(() => storedByteHash(raw.bytes));
  yield* storage(() =>
    env.ARCHIVE.put(keys.raw, raw.bytes, {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/json" },
      customMetadata: {
        httpStatus: String(raw.status),
        providerRequestId: raw.requestId,
        sha256,
        byteLength: String(raw.bytes.byteLength),
        extractionMs: String(extractionMs),
        providerMs: String(providerMs),
        fullyConsumed: String(raw.fullyConsumed),
      },
    }),
  );
  return Response.json(yield* recoverSubmission(env, fixture, index));
});

const normalize = Effect.fn("HostedMasterProbe.normalize")(function* (
  env: AsrProbeEnvironment,
  fixture: string,
) {
  const keys = paths(fixture);
  const retained = yield* storage(() => env.ARCHIVE.get(keys.normalized));
  if (retained !== null) {
    return new Response(retained.body, {
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  }
  const plan = yield* readPlan(env, fixture);
  let rawTotalBytes = 0;
  const submissions = yield* Effect.forEach(plan.intervals, (interval) =>
    Effect.gen(function* () {
      const part = paths(fixture, interval.index);
      const raw = yield* storage(() => env.ARCHIVE.get(part.raw));
      if (
        raw === null ||
        raw.customMetadata?.httpStatus !== "200" ||
        raw.customMetadata.fullyConsumed !== "true"
      ) {
        return yield* failure(
          409,
          "Every planned input must be fully consumed and have a retained provider success",
        );
      }
      rawTotalBytes += raw.size;
      if (rawTotalBytes > 16_000_000) {
        return yield* failure(
          413,
          "The controlled result set exceeds the normalization memory bound",
        );
      }
      const extraction = yield* Schema.decodeUnknownEffect(AsrExtractionEvidence)(
        yield* readJson(env, part.input),
      ).pipe(Effect.mapError(() => failure(409, "Stored extraction evidence is invalid")));
      const rawBytes = yield* readBoundedBody(raw.body, 4_000_000);
      const rawHash = yield* Effect.promise(() => storedByteHash(rawBytes));
      if (rawHash !== raw.customMetadata.sha256) {
        return yield* failure(409, "Raw evidence hash does not match the retained receipt");
      }
      return {
        extraction,
        rawArtifactKey: part.raw,
        rawBytes,
        providerRequestId: raw.customMetadata.providerRequestId || null,
      } satisfies Nova3MasterSubmission;
    }),
  );
  let identity = 0;
  const started = yield* Clock.currentTimeMillis;
  const output = yield* normalizeNova3Master({
    master: plan.master,
    revisionId: plan.revisionId,
    createdAt: plan.createdAt,
    requestedLanguage: plan.language,
    submissions,
    makeId: () => {
      const hex = createHash("sha256").update(`${plan.revisionId}:${identity++}`).digest("hex");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
    },
  });
  yield* writeJson(env, keys.provenance, output.provenance);
  yield* writeJson(env, keys.normalization, {
    normalizationMs: (yield* Clock.currentTimeMillis) - started,
    rawTotalBytes,
  });
  yield* writeJson(env, keys.normalized, output.revision);
  return Response.json(output.revision);
});

/** This authenticated dev-only fixture endpoint does not admit production call masters. */
const handle = Effect.fn("HostedMasterProbe.handle")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
) {
  if (!/^[a-z0-9][a-z0-9-]{0,79}$/.test(fixture)) {
    return yield* failure(400, "Invalid controlled fixture identity");
  }
  const url = new URL(request.url);
  if (request.method === "PUT") {
    return yield* prepare(request, env, fixture);
  }
  const index = url.searchParams.get("index");
  if (request.method === "POST") {
    if (url.searchParams.get("action") === "normalize") {
      return yield* normalize(env, fixture);
    }
    const decoded = yield* Schema.decodeUnknownEffect(Index)(index).pipe(
      Effect.mapError(() => failure(400, "An explicit submission index is required")),
    );
    return yield* submit(env, fixture, decoded);
  }
  if (request.method === "GET") {
    const artifact = url.searchParams.get("artifact");
    if (artifact !== null) {
      const decoded =
        index === null
          ? 0
          : yield* Schema.decodeEffect(Index)(index).pipe(
              Effect.mapError(() => failure(400, "Invalid submission index")),
            );
      const keys = paths(fixture, decoded);
      const key = yield* Schema.decodeUnknownEffect(
        Schema.Literals([
          "plan",
          "ready",
          "input",
          "admission",
          "raw",
          "failure",
          "normalized",
          "provenance",
          "normalization",
        ]),
      )(artifact).pipe(Effect.mapError(() => failure(400, "Unknown retained artifact")));
      const object = yield* storage(() => env.ARCHIVE.get(keys[key]));
      if (object === null) {
        return yield* failure(404, "This artifact has not been retained");
      }
      return new Response(object.body, {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }
    const plan = yield* readPlan(env, fixture);
    const ready = yield* readJson(env, paths(fixture).ready);
    const submissions = yield* Effect.forEach(plan.intervals, (interval) =>
      recoverSubmission(env, fixture, interval.index),
    );
    return Response.json({ fixture, master: plan.master, ready, submissions });
  }
  return new Response(null, { status: 405 });
});

export const hostedMasterProbeResponse = Effect.fn("HostedMasterProbe.response")(function* (
  request: Request,
  env: AsrProbeEnvironment,
  fixture: string,
) {
  return yield* handle(request, env, fixture).pipe(
    Effect.catchTags({
      "Asr.ExtractionError": (error) => Effect.fail(failure(422, error.message)),
      "Nova3.TransportError": (error) => Effect.fail(failure(422, error.message)),
      "Nova3.NormalizationError": (error) => Effect.fail(failure(422, error.message)),
    }),
  );
});
