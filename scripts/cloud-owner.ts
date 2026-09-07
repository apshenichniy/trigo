import { randomUUID } from "node:crypto";
import { closeSync, constants, fstatSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

import { Config, Console, DateTime, Effect, Redacted, Schema } from "effect";
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/unstable/http";

import type {
  OwnerOperation,
  OwnerOperationResult,
  OwnerToken as OwnerTokenType,
} from "../apps/server/src/owner-state.ts";
import {
  ArchiveId,
  hashOwnerToken,
  OwnerOperationId,
  ownerOperationQueries,
  OwnerToken,
} from "../apps/server/src/owner-state.ts";
import type { CloudConfiguration, CloudStage, CloudTarget } from "./cloud.ts";
import { cloudDeploymentIdentity, cloudTargetFor, preflightCloudConfiguration } from "./cloud.ts";

export type OwnerAction = "initialize" | "rotate" | "revoke";

interface OwnerCommandBase {
  readonly action: OwnerAction;
  readonly stage: CloudStage;
  readonly handoffPath: string;
  readonly configPath?: string;
}

export type OwnerCommand =
  | (OwnerCommandBase & { readonly action: "initialize" })
  | (OwnerCommandBase & {
      readonly action: "rotate" | "revoke";
      readonly expectedGeneration: number;
    });

const CloudflareDatabaseId = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
).pipe(Schema.brand("CloudflareDatabaseId"));
const CloudflareAccountId = Schema.String.check(Schema.isPattern(/^[0-9a-f]{32}$/)).pipe(
  Schema.brand("CloudflareAccountId"),
);
const CloudResourceName = Schema.String.check(Schema.isMinLength(1)).pipe(
  Schema.brand("CloudResourceName"),
);
const CloudDeploymentIdentity = Schema.String.check(Schema.isMinLength(1)).pipe(
  Schema.brand("CloudDeploymentIdentity"),
);
const PositiveGeneration = Schema.Finite.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1));

const OwnerHandoffTargetSchema = Schema.Struct({
  accountId: CloudflareAccountId,
  databaseName: CloudResourceName,
  deploymentIdentity: CloudDeploymentIdentity,
});

export type OwnerHandoffTarget = Schema.Schema.Type<typeof OwnerHandoffTargetSchema>;

const OwnerHandoffCommon = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  stage: Schema.Literals(["dev", "personal"]),
  target: OwnerHandoffTargetSchema,
  operationId: OwnerOperationId,
  createdAt: Schema.DateTimeUtcFromString,
});

const OwnerHandoffSchema = Schema.Union([
  Schema.Struct({
    ...OwnerHandoffCommon.fields,
    action: Schema.tag("initialize"),
    archiveId: ArchiveId,
    token: OwnerToken,
  }),
  Schema.Struct({
    ...OwnerHandoffCommon.fields,
    action: Schema.tag("rotate"),
    expectedGeneration: PositiveGeneration,
    token: OwnerToken,
  }),
  Schema.Struct({
    ...OwnerHandoffCommon.fields,
    action: Schema.tag("revoke"),
    expectedGeneration: PositiveGeneration,
  }),
]).pipe(Schema.toTaggedUnion("action"));

export type OwnerHandoff = Schema.Schema.Type<typeof OwnerHandoffSchema>;

export class OwnerCommandError extends Schema.TaggedError<OwnerCommandError>()(
  "CloudOwner.OwnerCommandError",
  {
    message: Schema.String,
    cause: Schema.optional(Schema.Defect()),
  },
) {}

function commandError(message: string, cause?: unknown): OwnerCommandError {
  return new OwnerCommandError(cause === undefined ? { message } : { message, cause });
}

export interface CloudflareOwnerTransport {
  readonly request: (
    request: Request,
  ) => Effect.Effect<{ readonly status: number; readonly body: unknown }, OwnerCommandError>;
}

const CloudflareError = Schema.Struct({
  code: Schema.Finite,
  message: Schema.String,
});
const CloudflareDatabaseList = Schema.Struct({
  success: Schema.Boolean,
  errors: Schema.Array(CloudflareError),
  result: Schema.Array(
    Schema.Struct({
      name: Schema.optionalKey(Schema.String),
      uuid: Schema.optionalKey(CloudflareDatabaseId),
    }),
  ),
});
const CloudflareQueryResult = Schema.Struct({
  success: Schema.optionalKey(Schema.Boolean),
  results: Schema.optionalKey(Schema.Array(Schema.Unknown)),
});
const CloudflareQueryResponse = Schema.Struct({
  success: Schema.Boolean,
  errors: Schema.Array(CloudflareError),
  result: Schema.Array(CloudflareQueryResult),
});
const OwnerStateRow = Schema.Struct({
  archive_id: ArchiveId,
  generation: PositiveGeneration,
  operation_id: OwnerOperationId,
  revoked: Schema.Finite.check(Schema.isInt(), Schema.isBetween({ minimum: 0, maximum: 1 })),
});

const decodeCloudflareDatabaseList = Schema.decodeUnknownEffect(CloudflareDatabaseList);
const decodeCloudflareQueryResponse = Schema.decodeUnknownEffect(CloudflareQueryResponse);
const decodeOwnerStateRow = Schema.decodeUnknownEffect(OwnerStateRow);
const decodeOwnerHandoffTarget = Schema.decodeUnknownSync(OwnerHandoffTargetSchema);
const decodeOwnerHandoffValue = Schema.decodeUnknownSync(OwnerHandoffSchema);
const encodeOwnerHandoff = Schema.encodeSync(
  Schema.fromJsonString(OwnerHandoffSchema, { space: 2 }),
);
const encodeUnknownJson = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));
const encodePrettyJson = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown, { space: 2 }));
const isOwnerCommandError = Schema.is(OwnerCommandError);

export function ownerHandoffFromUnknown(input: unknown): OwnerHandoff {
  return decodeOwnerHandoffValue(input);
}

function cloudflareFailure(
  operation: string,
  status: number,
  errors: ReadonlyArray<{ readonly code: number; readonly message: string }>,
): OwnerCommandError {
  const detail = errors.map((error) => `${error.code}: ${error.message}`).join("; ");
  return commandError(
    `${operation} failed with HTTP ${status}${detail === "" ? "" : ` (${detail})`}`,
  );
}

function cloudflareRequest(
  url: string,
  apiToken: Redacted.Redacted<string>,
  init?: RequestInit,
): Request {
  const headers = new Headers(init?.headers);
  headers.set("authorization", `Bearer ${Redacted.value(apiToken)}`);
  headers.set("accept", "application/json");
  return new Request(url, { ...init, headers });
}

export const applyRemoteOwnerOperation = Effect.fn("CloudOwner.applyRemoteOperation")(function* (
  accountId: string,
  databaseName: string,
  apiToken: Redacted.Redacted<string>,
  operation: OwnerOperation,
  transport: CloudflareOwnerTransport,
): Effect.fn.Return<OwnerOperationResult, OwnerCommandError> {
  if (!/^[0-9a-f]{32}$/i.test(accountId)) {
    return yield* commandError("Cloudflare account ID must be exactly 32 hexadecimal characters");
  }
  const databasesUrl = new URL(
    `https://api.cloudflare.com/client/v4/accounts/${accountId.toLowerCase()}/d1/database`,
  );
  databasesUrl.searchParams.set("name", databaseName);
  databasesUrl.searchParams.set("per_page", "10");
  const databaseResponse = yield* transport.request(
    cloudflareRequest(databasesUrl.toString(), apiToken),
  );
  const databases = yield* decodeCloudflareDatabaseList(databaseResponse.body).pipe(
    Effect.mapError((cause) =>
      commandError("Cloudflare returned a malformed D1 database list", cause),
    ),
  );
  if (databaseResponse.status < 200 || databaseResponse.status >= 300 || !databases.success) {
    return yield* cloudflareFailure(
      "D1 database lookup",
      databaseResponse.status,
      databases.errors,
    );
  }
  const matches = databases.result.filter(
    (database) => database.name === databaseName && database.uuid !== undefined,
  );
  if (matches.length !== 1 || matches[0]?.uuid === undefined) {
    return yield* commandError(`Expected exactly one D1 database named ${databaseName}`);
  }

  const queryUrl = `https://api.cloudflare.com/client/v4/accounts/${accountId.toLowerCase()}/d1/database/${matches[0].uuid}/query`;
  const queryResponse = yield* transport.request(
    cloudflareRequest(queryUrl, apiToken, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: encodeUnknownJson({ batch: ownerOperationQueries(operation) }),
    }),
  );
  const query = yield* decodeCloudflareQueryResponse(queryResponse.body).pipe(
    Effect.mapError((cause) =>
      commandError("Cloudflare returned a malformed D1 query result", cause),
    ),
  );
  if (queryResponse.status < 200 || queryResponse.status >= 300 || !query.success) {
    return yield* cloudflareFailure("D1 owner operation", queryResponse.status, query.errors);
  }
  if (query.result.some((result) => result.success === false)) {
    return yield* commandError("D1 owner operation batch reported a failed statement");
  }
  const finalResult = query.result[query.result.length - 1];
  const row = finalResult?.results?.[0];
  if (row === undefined) {
    return yield* commandError(
      "Owner operation conflicts with the current credential generation or content",
    );
  }
  const state = yield* decodeOwnerStateRow(row).pipe(
    Effect.mapError((cause) => commandError("D1 returned a malformed owner state", cause)),
  );
  return {
    archiveId: state.archive_id,
    generation: state.generation,
    operationId: state.operation_id,
    state: state.revoked === 0 ? "active" : "revoked",
  };
});

export function assertOwnerMutationAllowed(configuration: CloudConfiguration): void {
  if (
    configuration.stage === "personal" &&
    configuration.personalDeploymentGate !== "approved-after-32"
  ) {
    throw new Error(
      "Personal owner operations are blocked until #32 is accepted and personalDeploymentGate is approved-after-32",
    );
  }
}

const liveCloudflareOwnerRequest = Effect.fn("CloudOwner.liveRequest")(function* (
  request: Request,
) {
  const method = request.method === "POST" ? "POST" : "GET";
  const body =
    method === "POST"
      ? yield* Effect.tryPromise({
          try: () => request.text(),
          catch: (cause) => commandError("Cannot encode Cloudflare request body", cause),
        })
      : undefined;
  let outgoing = HttpClientRequest.make(method)(request.url, {
    headers: Array.from(request.headers.entries()),
  });
  if (body !== undefined) {
    outgoing = HttpClientRequest.bodyText(
      outgoing,
      body,
      request.headers.get("content-type") ?? "application/json",
    );
  }
  const response = yield* HttpClient.execute(outgoing).pipe(
    Effect.provide(FetchHttpClient.layer),
    Effect.provideService(FetchHttpClient.RequestInit, { redirect: "error" }),
  );
  const responseBody = yield* response.json;
  return { status: response.status, body: responseBody };
});

export const liveCloudflareOwnerTransport: CloudflareOwnerTransport = {
  request: (request) =>
    liveCloudflareOwnerRequest(request).pipe(
      Effect.mapError((cause) =>
        isOwnerCommandError(cause) ? cause : commandError("Cloudflare owner request failed", cause),
      ),
    ),
};

function flagValues(args: readonly string[]): ReadonlyMap<string, string> {
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (flag === undefined || !flag.startsWith("--") || value === undefined) {
      throw new Error("Owner command arguments must be --flag value pairs");
    }
    if (values.has(flag)) {
      throw new Error(`Pass ${flag} at most once`);
    }
    values.set(flag, value);
  }
  return values;
}

export function parseOwnerCommand(action: string, args: readonly string[]): OwnerCommand {
  if (action !== "initialize" && action !== "rotate" && action !== "revoke") {
    throw new Error("Expected owner action: initialize, rotate, or revoke");
  }
  const values = flagValues(args);
  const allowed = new Set([
    "--stage",
    "--handoff",
    "--config",
    ...(action === "initialize" ? [] : ["--expected-generation"]),
  ]);
  const unexpected = Array.from(values.keys()).filter((flag) => !allowed.has(flag));
  if (unexpected.length > 0) {
    throw new Error(`Unexpected owner argument: ${unexpected.join(", ")}`);
  }

  const stage = values.get("--stage");
  if (stage !== "dev" && stage !== "personal") {
    throw new Error("Pass an explicit --stage dev or --stage personal");
  }
  const handoffPath = values.get("--handoff");
  if (handoffPath === undefined || !isAbsolute(handoffPath)) {
    throw new Error("Pass an absolute path after --handoff");
  }
  const configured = values.get("--config");
  const config = configured === undefined ? {} : { configPath: resolve(configured) };
  if (action === "initialize") {
    return { action: "initialize", stage, handoffPath, ...config };
  }

  const rawGeneration = values.get("--expected-generation");
  const expectedGeneration = rawGeneration === undefined ? NaN : Number(rawGeneration);
  if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 1) {
    throw new Error("Pass a positive integer after --expected-generation");
  }
  return { action, stage, handoffPath, ...config, expectedGeneration };
}

function ownerToken(): OwnerTokenType {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return OwnerToken.make(`trigo_v1_${hex}`);
}

export function ownerHandoffTarget(target: CloudTarget, accountId: string): OwnerHandoffTarget {
  return decodeOwnerHandoffTarget({
    accountId: accountId.toLowerCase(),
    databaseName: target.resources.catalogDatabase,
    deploymentIdentity: cloudDeploymentIdentity(target, accountId),
  });
}

function newHandoff(
  command: OwnerCommand,
  target: OwnerHandoffTarget,
  createdAt: string,
): OwnerHandoff {
  const common = {
    schemaVersion: 1 as const,
    stage: command.stage,
    target,
    operationId: randomUUID(),
    createdAt,
  };
  if (command.action === "initialize") {
    return decodeOwnerHandoffValue({
      ...common,
      action: "initialize",
      archiveId: randomUUID(),
      token: ownerToken(),
    });
  }
  if (command.action === "rotate") {
    return decodeOwnerHandoffValue({
      ...common,
      action: "rotate",
      expectedGeneration: command.expectedGeneration,
      token: ownerToken(),
    });
  }
  return decodeOwnerHandoffValue({
    ...common,
    action: "revoke",
    expectedGeneration: command.expectedGeneration,
  });
}

function assertHandoffMatches(
  command: OwnerCommand,
  target: OwnerHandoffTarget,
  handoff: OwnerHandoff,
): void {
  if (handoff.action !== command.action || handoff.stage !== command.stage) {
    throw new Error("Existing owner handoff does not match the requested action and stage");
  }
  if (
    handoff.target.accountId !== target.accountId ||
    handoff.target.databaseName !== target.databaseName ||
    handoff.target.deploymentIdentity !== target.deploymentIdentity
  ) {
    throw new Error("Existing owner handoff does not match the requested Cloudflare target");
  }
  if (
    command.action !== "initialize" &&
    handoff.action !== "initialize" &&
    handoff.expectedGeneration !== command.expectedGeneration
  ) {
    throw new Error("Existing owner handoff does not match --expected-generation");
  }
}

const decodeOwnerHandoff = Schema.decodeUnknownSync(Schema.fromJsonString(OwnerHandoffSchema));

function loadOwnerHandoff(handoffPath: string): OwnerHandoff {
  const fd = openSync(
    handoffPath,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const status = fstatSync(fd);
    if (
      !status.isFile() ||
      status.size > 65_536 ||
      (process.getuid && status.uid !== process.getuid())
    ) {
      throw new Error("Owner handoff must be a bounded, owned regular file");
    }
    const mode = status.mode & 0o777;
    if (mode !== 0o600) {
      throw new Error(
        `Owner handoff permissions must be 0600, found ${mode.toString(8).padStart(4, "0")}`,
      );
    }
    return decodeOwnerHandoff(readFileSync(fd, "utf8"));
  } finally {
    closeSync(fd);
  }
}

export const readOwnerHandoff = Effect.fn("CloudOwner.readHandoff")(
  (handoffPath: string, stage: CloudStage) =>
    Effect.try({
      try: () => {
        const handoff = loadOwnerHandoff(handoffPath);
        if (handoff.stage !== stage) {
          throw new Error(`Owner handoff stage mismatch: expected ${stage}`);
        }
        return handoff;
      },
      catch: (cause) => commandError(`Cannot read owner handoff: ${handoffPath}`, cause),
    }),
);

export const prepareOwnerHandoff = Effect.fn("CloudOwner.prepareHandoff")(function* (
  command: OwnerCommand,
  target: OwnerHandoffTarget,
) {
  const createdAt = DateTime.formatIso(yield* DateTime.now);
  return yield* Effect.try({
    try: () => {
      try {
        const handoff = loadOwnerHandoff(command.handoffPath);
        assertHandoffMatches(command, target, handoff);
        return handoff;
      } catch (cause) {
        if (
          typeof cause !== "object" ||
          cause === null ||
          Reflect.get(cause, "code") !== "ENOENT"
        ) {
          throw cause;
        }
      }

      const handoff = newHandoff(command, target, createdAt);
      const descriptor = openSync(command.handoffPath, "wx", 0o600);
      try {
        writeFileSync(descriptor, `${encodeOwnerHandoff(handoff)}\n`, "utf8");
      } finally {
        closeSync(descriptor);
      }
      return handoff;
    },
    catch: (cause) =>
      commandError(
        `Cannot prepare owner handoff: ${command.handoffPath}${
          cause instanceof Error ? `: ${cause.message}` : ""
        }`,
        cause,
      ),
  });
});

export const ownerOperationFromHandoff = Effect.fn("CloudOwner.operationFromHandoff")(function* (
  handoff: OwnerHandoff,
): Effect.fn.Return<OwnerOperation> {
  if (handoff.action === "initialize") {
    return {
      kind: "initialize",
      operationId: handoff.operationId,
      archiveId: handoff.archiveId,
      verifierSha256: yield* hashOwnerToken(handoff.token),
      now: DateTime.formatIso(handoff.createdAt),
    };
  }
  if (handoff.action === "rotate") {
    return {
      kind: "rotate",
      operationId: handoff.operationId,
      expectedGeneration: handoff.expectedGeneration,
      verifierSha256: yield* hashOwnerToken(handoff.token),
      now: DateTime.formatIso(handoff.createdAt),
    };
  }
  return {
    kind: "revoke",
    operationId: handoff.operationId,
    expectedGeneration: handoff.expectedGeneration,
    now: DateTime.formatIso(handoff.createdAt),
  };
});

if (import.meta.main) {
  try {
    const [action, ...args] = process.argv.slice(2);
    const command = parseOwnerCommand(action ?? "", args);
    const program = Effect.gen(function* () {
      const apiToken = yield* Config.redacted("CLOUDFLARE_API_TOKEN").pipe(
        Effect.mapError((cause) =>
          commandError("Missing CLOUDFLARE_API_TOKEN for owner operation", cause),
        ),
      );
      const target = cloudTargetFor(command.stage);
      const configPath = command.configPath ?? resolve(target.configPath);
      const configuration = yield* Effect.try({
        try: () => preflightCloudConfiguration(configPath, target),
        catch: (cause) => commandError("Cloud owner preflight failed", cause),
      });
      yield* Effect.try({
        try: () => assertOwnerMutationAllowed(configuration),
        catch: (cause) => commandError("Cloud owner preflight failed", cause),
      });
      const handoff = yield* prepareOwnerHandoff(
        command,
        ownerHandoffTarget(target, configuration.accountId),
      );
      const operation = yield* ownerOperationFromHandoff(handoff);
      const result = yield* applyRemoteOwnerOperation(
        configuration.accountId,
        target.resources.catalogDatabase,
        apiToken,
        operation,
        liveCloudflareOwnerTransport,
      );
      yield* Console.log(
        encodePrettyJson({
          action: handoff.action,
          stage: handoff.stage,
          handoff: command.handoffPath,
          ...result,
        }),
      );
    });
    await Effect.runPromise(program);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
