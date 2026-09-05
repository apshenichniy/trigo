import { randomUUID } from "node:crypto";
import { closeSync, openSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { Config, Console, Effect, Redacted, Schema } from "effect";
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/unstable/http";
import type { OwnerOperation, OwnerOperationResult } from "../apps/server/src/owner-state.ts";
import { hashOwnerToken, ownerOperationQueries } from "../apps/server/src/owner-state.ts";
import type { CloudConfiguration, CloudStage } from "./cloud.ts";
import { cloudTargetFor, preflightCloudConfiguration } from "./cloud.ts";

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

const Uuid = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
);
const OwnerToken = Schema.String.check(Schema.isPattern(/^trigo_v1_[0-9a-f]{64}$/));
const PositiveGeneration = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1));

const OwnerHandoffSchema = Schema.Union([
  Schema.Struct({
    schemaVersion: Schema.Literal(1),
    action: Schema.Literal("initialize"),
    stage: Schema.Literals(["dev", "personal"]),
    operationId: Uuid,
    archiveId: Uuid,
    token: OwnerToken,
    createdAt: Schema.String,
  }),
  Schema.Struct({
    schemaVersion: Schema.Literal(1),
    action: Schema.Literal("rotate"),
    stage: Schema.Literals(["dev", "personal"]),
    operationId: Uuid,
    expectedGeneration: PositiveGeneration,
    token: OwnerToken,
    createdAt: Schema.String,
  }),
  Schema.Struct({
    schemaVersion: Schema.Literal(1),
    action: Schema.Literal("revoke"),
    stage: Schema.Literals(["dev", "personal"]),
    operationId: Uuid,
    expectedGeneration: PositiveGeneration,
    createdAt: Schema.String,
  }),
]);

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
  code: Schema.Number,
  message: Schema.String,
});
const CloudflareDatabaseList = Schema.Struct({
  success: Schema.Boolean,
  errors: Schema.Array(CloudflareError),
  result: Schema.Array(
    Schema.Struct({
      name: Schema.optional(Schema.String),
      uuid: Schema.optional(Schema.String),
    }),
  ),
});
const CloudflareQueryResult = Schema.Struct({
  success: Schema.optional(Schema.Boolean),
  results: Schema.optional(Schema.Array(Schema.Unknown)),
});
const CloudflareQueryResponse = Schema.Struct({
  success: Schema.Boolean,
  errors: Schema.Array(CloudflareError),
  result: Schema.Array(CloudflareQueryResult),
});
const OwnerStateRow = Schema.Struct({
  archive_id: Uuid,
  generation: PositiveGeneration,
  operation_id: Uuid,
  revoked: Schema.Number.check(Schema.isInt(), Schema.isBetween({ minimum: 0, maximum: 1 })),
});

const decodeCloudflareDatabaseList = Schema.decodeUnknownEffect(CloudflareDatabaseList);
const decodeCloudflareQueryResponse = Schema.decodeUnknownEffect(CloudflareQueryResponse);
const decodeOwnerStateRow = Schema.decodeUnknownEffect(OwnerStateRow);

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
  if (!/^[0-9a-f]{32}$/i.test(accountId))
    return yield* commandError("Cloudflare account ID must be exactly 32 hexadecimal characters");
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
  if (databaseResponse.status < 200 || databaseResponse.status >= 300 || !databases.success)
    return yield* cloudflareFailure(
      "D1 database lookup",
      databaseResponse.status,
      databases.errors,
    );
  const matches = databases.result.filter(
    (database) => database.name === databaseName && database.uuid !== undefined,
  );
  if (matches.length !== 1 || matches[0]?.uuid === undefined)
    return yield* commandError(`Expected exactly one D1 database named ${databaseName}`);

  const queryUrl = `https://api.cloudflare.com/client/v4/accounts/${accountId.toLowerCase()}/d1/database/${matches[0].uuid}/query`;
  const queryResponse = yield* transport.request(
    cloudflareRequest(queryUrl, apiToken, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ batch: ownerOperationQueries(operation) }),
    }),
  );
  const query = yield* decodeCloudflareQueryResponse(queryResponse.body).pipe(
    Effect.mapError((cause) =>
      commandError("Cloudflare returned a malformed D1 query result", cause),
    ),
  );
  if (queryResponse.status < 200 || queryResponse.status >= 300 || !query.success)
    return yield* cloudflareFailure("D1 owner operation", queryResponse.status, query.errors);
  if (query.result.some((result) => result.success === false))
    return yield* commandError("D1 owner operation batch reported a failed statement");
  const finalResult = query.result[query.result.length - 1];
  const row = finalResult?.results?.[0];
  if (row === undefined)
    return yield* commandError(
      "Owner operation conflicts with the current credential generation or content",
    );
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
  )
    throw new Error(
      "Personal owner operations are blocked until #32 is accepted and personalDeploymentGate is approved-after-32",
    );
}

export const liveCloudflareOwnerTransport: CloudflareOwnerTransport = {
  request: (request) =>
    Effect.gen(function* () {
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
      if (body !== undefined)
        outgoing = HttpClientRequest.bodyText(
          outgoing,
          body,
          request.headers.get("content-type") ?? "application/json",
        );
      const response = yield* HttpClient.execute(outgoing);
      const responseBody = yield* response.json;
      return { status: response.status, body: responseBody };
    }).pipe(
      Effect.mapError((cause) =>
        cause instanceof OwnerCommandError
          ? cause
          : commandError("Cloudflare owner request failed", cause),
      ),
      Effect.provide(FetchHttpClient.layer),
      Effect.provideService(FetchHttpClient.RequestInit, { redirect: "error" }),
    ),
};

function flagValues(args: readonly string[]): ReadonlyMap<string, string> {
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (flag === undefined || !flag.startsWith("--") || value === undefined)
      throw new Error("Owner command arguments must be --flag value pairs");
    if (values.has(flag)) throw new Error(`Pass ${flag} at most once`);
    values.set(flag, value);
  }
  return values;
}

export function parseOwnerCommand(action: string, args: readonly string[]): OwnerCommand {
  if (action !== "initialize" && action !== "rotate" && action !== "revoke")
    throw new Error("Expected owner action: initialize, rotate, or revoke");
  const values = flagValues(args);
  const allowed = new Set([
    "--stage",
    "--handoff",
    "--config",
    ...(action === "initialize" ? [] : ["--expected-generation"]),
  ]);
  const unexpected = Array.from(values.keys()).filter((flag) => !allowed.has(flag));
  if (unexpected.length > 0) throw new Error(`Unexpected owner argument: ${unexpected.join(", ")}`);

  const stage = values.get("--stage");
  if (stage !== "dev" && stage !== "personal")
    throw new Error("Pass an explicit --stage dev or --stage personal");
  const handoffPath = values.get("--handoff");
  if (handoffPath === undefined || !isAbsolute(handoffPath))
    throw new Error("Pass an absolute path after --handoff");
  const configured = values.get("--config");
  const config = configured === undefined ? {} : { configPath: resolve(configured) };
  if (action === "initialize") return { action: "initialize", stage, handoffPath, ...config };

  const rawGeneration = values.get("--expected-generation");
  const expectedGeneration = rawGeneration === undefined ? NaN : Number(rawGeneration);
  if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 1)
    throw new Error("Pass a positive integer after --expected-generation");
  return { action, stage, handoffPath, ...config, expectedGeneration };
}

function ownerToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `trigo_v1_${hex}`;
}

function newHandoff(command: OwnerCommand): OwnerHandoff {
  const common = {
    schemaVersion: 1 as const,
    stage: command.stage,
    operationId: randomUUID(),
    createdAt: new Date().toISOString(),
  };
  if (command.action === "initialize")
    return {
      ...common,
      action: "initialize",
      archiveId: randomUUID(),
      token: ownerToken(),
    };
  if (command.action === "rotate")
    return {
      ...common,
      action: "rotate",
      expectedGeneration: command.expectedGeneration,
      token: ownerToken(),
    };
  return {
    ...common,
    action: "revoke",
    expectedGeneration: command.expectedGeneration,
  };
}

function assertHandoffMatches(command: OwnerCommand, handoff: OwnerHandoff): void {
  if (handoff.action !== command.action || handoff.stage !== command.stage)
    throw new Error("Existing owner handoff does not match the requested action and stage");
  if (
    command.action !== "initialize" &&
    handoff.action !== "initialize" &&
    handoff.expectedGeneration !== command.expectedGeneration
  )
    throw new Error("Existing owner handoff does not match --expected-generation");
}

const decodeOwnerHandoff = Schema.decodeUnknownSync(OwnerHandoffSchema);

export const prepareOwnerHandoff = Effect.fn("CloudOwner.prepareHandoff")((command: OwnerCommand) =>
  Effect.try({
    try: () => {
      try {
        const mode = statSync(command.handoffPath).mode & 0o777;
        if (mode !== 0o600)
          throw new Error(
            `Owner handoff permissions must be 0600, found ${mode.toString(8).padStart(4, "0")}`,
          );
        const handoff = decodeOwnerHandoff(JSON.parse(readFileSync(command.handoffPath, "utf8")));
        assertHandoffMatches(command, handoff);
        return handoff;
      } catch (cause) {
        if (typeof cause !== "object" || cause === null || Reflect.get(cause, "code") !== "ENOENT")
          throw cause;
      }

      const handoff = newHandoff(command);
      const descriptor = openSync(command.handoffPath, "wx", 0o600);
      try {
        writeFileSync(descriptor, `${JSON.stringify(handoff, undefined, 2)}\n`, "utf8");
      } finally {
        closeSync(descriptor);
      }
      return handoff;
    },
    catch: (cause) => commandError(`Cannot prepare owner handoff: ${command.handoffPath}`, cause),
  }),
);

export const ownerOperationFromHandoff = Effect.fn("CloudOwner.operationFromHandoff")(function* (
  handoff: OwnerHandoff,
): Effect.fn.Return<OwnerOperation> {
  if (handoff.action === "initialize")
    return {
      kind: "initialize",
      operationId: handoff.operationId,
      archiveId: handoff.archiveId,
      verifierSha256: yield* hashOwnerToken(handoff.token),
      now: handoff.createdAt,
    };
  if (handoff.action === "rotate")
    return {
      kind: "rotate",
      operationId: handoff.operationId,
      expectedGeneration: handoff.expectedGeneration,
      verifierSha256: yield* hashOwnerToken(handoff.token),
      now: handoff.createdAt,
    };
  return {
    kind: "revoke",
    operationId: handoff.operationId,
    expectedGeneration: handoff.expectedGeneration,
    now: handoff.createdAt,
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
      const handoff = yield* prepareOwnerHandoff(command);
      const operation = yield* ownerOperationFromHandoff(handoff);
      const result = yield* applyRemoteOwnerOperation(
        configuration.accountId,
        target.resources.catalogDatabase,
        apiToken,
        operation,
        liveCloudflareOwnerTransport,
      );
      yield* Console.log(
        JSON.stringify(
          {
            action: handoff.action,
            stage: handoff.stage,
            handoff: command.handoffPath,
            ...result,
          },
          undefined,
          2,
        ),
      );
    });
    await Effect.runPromise(program);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
