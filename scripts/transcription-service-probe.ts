import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Config, Console, Effect, Redacted, Schedule, Schema } from "effect";
import {
  FetchHttpClient,
  HttpClient,
  HttpClientRequest,
  type HttpClientResponse,
} from "effect/unstable/http";

import {
  ExchangeUUID,
  FinalizeMasterUpload,
  MasterUploadSession,
  RegisterMasterUpload,
  RequestTranscription,
  StatusResponse,
  TranscriptionOperation,
  UploadPartReceipt,
  VerifiedMasterReceipt,
  parseCallDocument,
  parseStored,
  storedByteHash,
} from "../packages/contracts/src/index.ts";
import { commandOptions } from "./arguments.ts";
import { generateMasterTemplate } from "./asr-master-fixtures.ts";
import { cloudTargetFor, readCloudConfiguration } from "./cloud.ts";

class ServiceProbeError extends Schema.TaggedError<ServiceProbeError>()("ServiceProbeError", {
  message: Schema.String,
}) {}
const failure = (message: string) => new ServiceProbeError({ message });
const disk = <A>(action: () => A) =>
  Effect.try({
    try: action,
    catch: () => failure("Probe artifact access failed; existing evidence was preserved."),
  });
const json = (value: unknown) =>
  Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown))(value).pipe(
    Effect.mapError(() => failure("Probe document cannot be encoded.")),
  );

const ServiceProbePlan = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  apiUrl: Schema.NonEmptyString,
  archiveId: ExchangeUUID,
  language: Schema.Literals(["en", "ru"]),
  registration: RegisterMasterUpload,
  finalization: FinalizeMasterUpload,
  transcription: RequestTranscription,
});
export interface ServiceProbePlan extends Schema.Schema.Type<typeof ServiceProbePlan> {}

export function parseServiceProbeOptions(args: readonly string[]): {
  action: "prepare" | "run";
  directory: string;
  configuration: string;
  language: "en" | "ru";
} {
  const [action, ...flags] = args;
  if (action !== "prepare" && action !== "run") {
    throw new Error("Expected prepare or run.");
  }
  const options = commandOptions("transcription-service-probe", flags, {
    "--stage": "value",
    "--config": "value",
    "--directory": "value",
    "--language": "value",
    "--allow-paid": "flag",
  });
  if (options.get("--stage") !== "dev") {
    throw new Error("The service probe requires --stage dev.");
  }
  const directory = options.get("--directory");
  const configuration = options.get("--config");
  const language = options.get("--language");
  if (
    typeof directory !== "string" ||
    typeof configuration !== "string" ||
    (language !== "en" && language !== "ru")
  ) {
    throw new Error("Pass --directory, --config and --language en or ru.");
  }
  if (action === "run" && options.get("--allow-paid") !== true) {
    throw new Error("Run requires explicit --allow-paid for this one-minute request set.");
  }
  return { action, directory: resolve(directory), configuration: resolve(configuration), language };
}

/** The prepared command fixes one 60-second call and its original-plus-one attempt ceiling. */
export const validateServiceProbePlan = Effect.fn("ServiceProbe.validatePlan")(function* (
  value: unknown,
  bytes: Uint8Array,
) {
  const plan = yield* Schema.decodeUnknownEffect(ServiceProbePlan, { onExcessProperty: "error" })(
    value,
  ).pipe(Effect.mapError(() => failure("Invalid prepared service probe.")));
  const call = yield* Effect.try({
    try: () => parseCallDocument(new TextEncoder().encode(plan.registration.callDocument)),
    catch: () => failure("Invalid prepared call document."),
  });
  const hash = yield* Effect.promise(() => storedByteHash(bytes));
  if (
    bytes.byteLength !== 3_840_068 ||
    plan.finalization.durationMs !== 60_000 ||
    hash !== plan.finalization.masterSHA256 ||
    call.archiveId !== plan.archiveId ||
    plan.finalization.uploadId !== plan.registration.uploadId ||
    plan.transcription.requestedLanguage !== plan.language
  ) {
    return yield* failure(
      "Prepared probe identity, exact audio bytes or one-minute bound changed.",
    );
  }
  return { plan, call };
});

const saveExact = (path: string, bytes: Uint8Array | string) =>
  disk(() => {
    const encoded = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
    if (existsSync(path)) {
      const existing = readFileSync(path);
      if (
        existing.byteLength !== encoded.byteLength ||
        existing.some((byte, index) => byte !== encoded[index])
      ) {
        throw new Error("Refusing to overwrite different evidence");
      }
      return;
    }
    writeFileSync(path, encoded, { mode: 0o600, flag: "wx" });
  });

const request = Effect.fn("ServiceProbe.request")(function* (
  apiUrl: string,
  token: Redacted.Redacted<string>,
  path: string,
  method: "GET" | "POST" | "PUT" = "GET",
  body?: unknown,
  headers?: Readonly<Record<string, string>>,
) {
  let outgoing = HttpClientRequest.make(method)(apiUrl + path).pipe(
    HttpClientRequest.bearerToken(token),
  );
  if (body instanceof Uint8Array) {
    outgoing = HttpClientRequest.bodyUint8Array(outgoing, body, "application/octet-stream");
  } else if (body !== undefined) {
    outgoing = yield* HttpClientRequest.bodyJson(outgoing, body);
  }
  if (headers) {
    outgoing = HttpClientRequest.setHeaders(outgoing, headers);
  }
  const response = yield* HttpClient.execute(outgoing).pipe(
    Effect.timeout("2 minutes"),
    Effect.mapError(() =>
      failure(`Request interrupted: ${method} ${path}. Reuse the same prepared directory.`),
    ),
  );
  if (response.status < 200 || response.status >= 300) {
    return yield* failure(
      `HTTP ${response.status}: ${method} ${path}. Reuse the prepared identities after correction.`,
    );
  }
  return response;
});

const decodeResponse = <Success>(
  schema: Schema.Decoder<Success, never>,
  response: HttpClientResponse.HttpClientResponse,
) =>
  response.json.pipe(
    Effect.flatMap(Schema.decodeUnknownEffect(schema, { onExcessProperty: "error" })),
    Effect.mapError(() => failure("Server response does not match the shared contract.")),
  );

const prepare = Effect.fn("ServiceProbe.prepare")(function* (
  directory: string,
  apiUrl: string,
  archiveId: string,
  language: "en" | "ru",
) {
  const planPath = resolve(directory, "plan.json");
  if (yield* disk(() => existsSync(planPath))) {
    return;
  }
  yield* disk(() => {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    if (existsSync(resolve(directory, "master.caf"))) {
      throw new Error("A partial preparation already exists");
    }
    generateMasterTemplate(language, resolve(directory, "master.caf"));
  });
  const bytes = yield* disk(() => new Uint8Array(readFileSync(resolve(directory, "master.caf"))));
  const sha256 = yield* Effect.promise(() => storedByteHash(bytes));
  // oxlint-disable-next-line effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Independent operator fixture identities are persisted before any provider work.
  const ids = yield* Effect.sync(() => Array.from({ length: 9 }, () => crypto.randomUUID()));
  const [
    callId,
    uploadId,
    masterId,
    microphoneTrackId,
    applicationTrackId,
    manifestId,
    operationId,
    revisionId,
    finalizeOperationId,
  ] = ids;
  const tracks = [
    { trackId: microphoneTrackId, role: "microphone" },
    { trackId: applicationTrackId, role: "application" },
  ];
  const audioManifest = yield* json({
    schemaVersion: 1,
    callId,
    manifestId,
    durationMs: 60_000,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
    objects: [
      {
        objectId: masterId,
        index: 0,
        contentType: "audio/x-caf",
        byteLength: bytes.byteLength,
        sha256,
        startMs: 0,
        endMs: 60_000,
        channelMap: tracks.map((track, channelIndex) => ({ channelIndex, trackId: track.trackId })),
      },
    ],
  });
  const callDocument = yield* json({
    schemaVersion: 1,
    archiveId,
    callId,
    documentVersion: 1,
    startedAt: "2026-09-08T00:00:00.000Z",
    endedAt: null,
    durationMs: null,
    captureState: "recording",
    interruptionReason: null,
    source: {
      applicationName: "Trigo synthetic service acceptance",
      bundleId: "test.trigo.service-probe",
      processId: 18,
      windowId: null,
      windowTitle: null,
    },
    tracks: tracks.map((track) => ({
      ...track,
      inputDevice: null,
      mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
      intervals: [],
    })),
    audioManifest: null,
    revisions: [],
    activeRevisionId: null,
    speakerNames: {},
  });
  const value = {
    schemaVersion: 1,
    apiUrl,
    archiveId,
    language,
    registration: { schemaVersion: 1, uploadId, masterId, callDocument },
    finalization: {
      schemaVersion: 1,
      operationId: finalizeOperationId,
      uploadId,
      captureState: "stopped",
      durationMs: 60_000,
      sourceStates: {
        encoding: "source-states-2bit-ms-v1",
        data: Buffer.alloc(30_000).toString("base64"),
      },
      audioManifest,
      masterSHA256: sha256,
    },
    transcription: {
      schemaVersion: 1,
      operationId,
      revisionId,
      requestedLanguage: language,
      profileId: "nova3-wav-s16le-16000-stereo-stream-v1",
    },
  };
  const { plan } = yield* validateServiceProbePlan(value, bytes);
  yield* saveExact(planPath, yield* json(plan));
});

const main = Effect.gen(function* () {
  const options = yield* Effect.try({
    try: () => parseServiceProbeOptions(process.argv.slice(2)),
    catch: (cause) => failure(String(cause)),
  });
  const configuration = yield* Effect.try({
    try: () => readCloudConfiguration(options.configuration, cloudTargetFor("dev")),
    catch: () => failure("Dev configuration could not be validated."),
  });
  const apiUrl = configuration.apiUrl;
  if (!apiUrl) {
    return yield* failure("Dev configuration requires apiUrl.");
  }
  const token = yield* Config.redacted("TRIGO_ASR_OPERATOR_TOKEN");
  const status = yield* decodeResponse(StatusResponse, yield* request(apiUrl, token, "/v1/status"));
  if (status.stage !== "dev") {
    return yield* failure("The server does not identify as Dev.");
  }
  if (options.action === "prepare") {
    yield* prepare(options.directory, apiUrl, status.archiveId, options.language);
  }
  const input = yield* disk(() => readFileSync(resolve(options.directory, "plan.json"), "utf8"));
  const value = yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Unknown))(input);
  const bytes = yield* disk(
    () => new Uint8Array(readFileSync(resolve(options.directory, "master.caf"))),
  );
  const { plan, call } = yield* validateServiceProbePlan(value, bytes);
  if (
    plan.apiUrl !== apiUrl ||
    plan.archiveId !== status.archiveId ||
    plan.language !== options.language
  ) {
    return yield* failure(
      "Prepared request belongs to a different Dev server, archive or language.",
    );
  }
  if (options.action === "prepare") {
    yield* Console.log(
      yield* json({
        prepared: true,
        callId: call.callId,
        operationId: plan.transcription.operationId,
        language: plan.language,
        durationMs: 60_000,
        maximumProviderAttempts: 2,
        directory: options.directory,
      }),
    );
    return;
  }
  if (status.readiness.transcription !== "ready") {
    return yield* failure("Hosted transcription is not ready.");
  }
  yield* decodeResponse(
    MasterUploadSession,
    yield* request(apiUrl, token, "/v1/calls", "POST", plan.registration),
  );
  yield* decodeResponse(
    UploadPartReceipt,
    yield* request(
      apiUrl,
      token,
      `/v1/calls/${call.callId}/uploads/${plan.registration.uploadId}/chunks/0`,
      "PUT",
      bytes,
      {
        "x-trigo-byte-offset": "0",
        "x-trigo-content-sha256": plan.finalization.masterSHA256,
        "content-length": String(bytes.byteLength),
      },
    ),
  );
  const receipt = yield* decodeResponse(
    VerifiedMasterReceipt,
    yield* request(apiUrl, token, `/v1/calls/${call.callId}/finalize`, "POST", plan.finalization),
  );
  yield* saveExact(resolve(options.directory, "master-receipt.json"), yield* json(receipt));
  const path = `/v1/calls/${call.callId}/transcriptions`;
  yield* decodeResponse(
    TranscriptionOperation,
    yield* request(apiUrl, token, path, "POST", plan.transcription),
  );
  const readOperation = request(
    apiUrl,
    token,
    `/v1/operations/${plan.transcription.operationId}`,
  ).pipe(Effect.flatMap((response) => decodeResponse(TranscriptionOperation, response)));
  const operation = yield* readOperation.pipe(
    Effect.repeat({
      schedule: Schedule.spaced("2 seconds"),
      while: (operation) =>
        (operation.state === "queued" || operation.state === "running") &&
        operation.failure === null,
    }),
    Effect.timeout("6 minutes"),
  );
  if (operation.state !== "result_available" || !operation.result) {
    return yield* failure(
      `Operation ${operation.operationId}: ${operation.failure?.code ?? operation.state}. Reuse its prepared directory.`,
    );
  }
  const replay = yield* decodeResponse(
    TranscriptionOperation,
    yield* request(apiUrl, token, path, "POST", plan.transcription),
  );
  if (
    replay.operationId !== operation.operationId ||
    replay.result?.sha256 !== operation.result.sha256 ||
    replay.attemptCount !== operation.attemptCount
  ) {
    return yield* failure("Repeated command did not recover the exact available result.");
  }
  for (const provenance of [false, true]) {
    const resultPath = `/v1/calls/${call.callId}/revisions/${operation.revisionId}${provenance ? "/provenance" : ""}`;
    const response = yield* request(apiUrl, token, resultPath);
    const resultBytes = new Uint8Array(yield* response.arrayBuffer);
    const expectedHash = provenance ? operation.result.provenanceSHA256 : operation.result.sha256;
    const expectedLength = provenance
      ? operation.result.provenanceByteLength
      : operation.result.byteLength;
    if (
      resultBytes.byteLength !== expectedLength ||
      (yield* Effect.promise(() => storedByteHash(resultBytes))) !== expectedHash
    ) {
      return yield* failure("Retained evidence failed exact-byte verification.");
    }
    if (!provenance) {
      const revision = yield* Effect.try({
        try: () => parseStored("TranscriptRevision", resultBytes),
        catch: () => failure("Invalid retained transcript revision."),
      });
      if (
        revision.callId !== call.callId ||
        revision.revisionId !== plan.transcription.revisionId ||
        revision.asr.adapter !== "cloudflare-workers-ai" ||
        new Set(revision.turns.map((turn) => turn.trackId)).size !== 2 ||
        revision.turns.length === 0
      ) {
        return yield* failure("Hosted speech evidence does not preserve both fixture tracks.");
      }
    }
    yield* saveExact(
      resolve(options.directory, provenance ? "provenance.json" : "revision.json"),
      resultBytes,
    );
  }
  yield* saveExact(resolve(options.directory, "operation.json"), yield* json(operation));
  yield* Console.log(
    yield* json({
      accepted: true,
      callId: call.callId,
      operationId: operation.operationId,
      revisionId: operation.revisionId,
      attemptCount: operation.attemptCount,
      result: operation.result,
      directory: options.directory,
    }),
  );
});

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  Effect.runPromise(main.pipe(Effect.provide(FetchHttpClient.layer))).catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : "Service probe failed.");
    process.exitCode = 1;
  });
}
