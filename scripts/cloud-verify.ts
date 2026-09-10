import { spawnSync } from "node:child_process";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Config, Console, Effect, Redacted, Schema } from "effect";
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/unstable/http";

import type { OwnerToken } from "../apps/server/src/owner-state.ts";
import { validateDocument } from "../packages/contracts/src/index.ts";
import type { OwnerHandoff, OwnerHandoffTarget } from "./cloud-owner.ts";
import { ownerHandoffTarget, readOwnerHandoff } from "./cloud-owner.ts";
import type { CloudTarget } from "./cloud.ts";
import { cloudDeploymentIdentity, cloudTargetFor } from "./cloud.ts";

export type CloudVerification =
  | { readonly stage: "dev"; readonly mode: "inspect" }
  | { readonly stage: "dev"; readonly mode: "seed" | "verify"; readonly fixtureId: string }
  | { readonly stage: "dev"; readonly mode: "owner"; readonly handoffPath: string };

export class CloudVerificationError extends Schema.TaggedError<CloudVerificationError>()(
  "CloudVerificationError",
  {
    message: Schema.String,
    cause: Schema.optional(Schema.Defect()),
  },
) {}

function cloudVerificationError(message: string, cause?: unknown): CloudVerificationError {
  return new CloudVerificationError(cause === undefined ? { message } : { message, cause });
}

function cloudVerificationCause(fallback: string, cause: unknown): CloudVerificationError {
  return cloudVerificationError(cause instanceof Error ? cause.message : fallback, cause);
}

const unknownFromJsonString = Schema.fromJsonString(Schema.Unknown);
const decodeUnknownJson = Schema.decodeUnknownEffect(unknownFromJsonString);
const encodeUnknownJson = Schema.encodeSync(unknownFromJsonString);
const encodePrettyJson = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown, { space: 2 }));
const D1FixtureResult = Schema.Array(
  Schema.Struct({
    results: Schema.Array(Schema.Struct({ fixture_id: Schema.String })),
  }),
);
const decodeD1FixtureResult = Schema.decodeUnknownEffect(Schema.fromJsonString(D1FixtureResult));

export function parseCloudVerification(args: readonly string[]): CloudVerification {
  if (args[0] !== "--stage" || args[1] !== "dev") {
    throw new Error("Cloud verification requires --stage dev");
  }
  if (args.length === 2) {
    return { stage: "dev", mode: "inspect" };
  }
  const flag = args[2];
  const value = args[3];
  if (args.length === 4 && flag === "--owner-handoff" && value !== undefined) {
    if (!isAbsolute(value)) {
      throw new Error("Pass an absolute path after --owner-handoff");
    }
    return { stage: "dev", mode: "owner", handoffPath: value };
  }
  const fixtureId = value;
  if (args.length !== 4 || (flag !== "--seed" && flag !== "--verify") || fixtureId === undefined) {
    throw new Error(
      "Use test:cloud --stage dev, --seed <fixture-id>, --verify <fixture-id>, or --owner-handoff <absolute-path>",
    );
  }
  return { stage: "dev", mode: flag === "--seed" ? "seed" : "verify", fixtureId };
}

export interface CloudOwnerStatusBoundary {
  readonly status: (
    ownerToken: OwnerToken,
  ) => Effect.Effect<{ readonly status: number; readonly body: unknown }, CloudVerificationError>;
}

export const verifyCloudOwnerStatus = Effect.fn("CloudVerifier.ownerStatus")(function* (
  stage: "dev",
  handoff: OwnerHandoff,
  expectedTarget: OwnerHandoffTarget,
  boundary: CloudOwnerStatusBoundary,
) {
  if (handoff.stage !== stage) {
    return yield* cloudVerificationError(`Owner handoff stage mismatch: expected ${stage}`);
  }
  if (
    handoff.target.accountId !== expectedTarget.accountId ||
    handoff.target.databaseName !== expectedTarget.databaseName ||
    handoff.target.deploymentIdentity !== expectedTarget.deploymentIdentity
  ) {
    return yield* cloudVerificationError("Owner handoff does not match the verified cloud target");
  }
  if (handoff.action === "revoke") {
    return yield* cloudVerificationError("A revoked owner handoff cannot authenticate status");
  }
  const response = yield* boundary.status(handoff.token);
  if (response.status < 200 || response.status >= 300) {
    return yield* cloudVerificationError(
      `Authenticated owner status failed with HTTP ${response.status}`,
    );
  }
  const status = yield* Effect.try({
    try: () => validateDocument("StatusResponse", response.body),
    catch: (cause) => cloudVerificationError("Owner status does not match StatusResponse", cause),
  });
  if (status.stage !== stage) {
    return yield* cloudVerificationError(`Owner status stage mismatch: expected ${stage}`);
  }
  if (handoff.action === "initialize" && status.archiveId !== handoff.archiveId) {
    return yield* cloudVerificationError("Owner status returned an unexpected archive identity");
  }
  if (
    status.readiness.archive !== "ready" ||
    status.readiness.ownerAuthentication !== "ready" ||
    status.readiness.transcription !== "not_verified" ||
    status.readiness.callOperations !== "ready"
  ) {
    return yield* cloudVerificationError("Owner status returned unexpected issue #30 readiness");
  }
  return status;
});

export interface CloudInspectionBoundary {
  readonly workerDeployment: Effect.Effect<string, CloudVerificationError>;
  readonly r2Exposure: Effect.Effect<
    { readonly publicAccess: boolean; readonly customDomainCount: number },
    CloudVerificationError
  >;
  readonly infrastructure: Effect.Effect<
    { readonly status: number; readonly body: unknown },
    CloudVerificationError
  >;
}

export interface CloudFixtureBoundary {
  readonly putObject: (
    bucket: string,
    key: string,
    content: string,
  ) => Effect.Effect<void, CloudVerificationError>;
  readonly getObject: (
    bucket: string,
    key: string,
  ) => Effect.Effect<string, CloudVerificationError>;
  readonly writeCatalog: (
    database: string,
    fixtureId: string,
  ) => Effect.Effect<void, CloudVerificationError>;
  readonly readCatalog: (
    database: string,
    fixtureId: string,
  ) => Effect.Effect<string, CloudVerificationError>;
}

export type WranglerRunner = (
  args: readonly string[],
  input?: string,
) => Effect.Effect<string, CloudVerificationError>;

export function makeWranglerBoundary(
  target: CloudTarget,
  run: WranglerRunner,
  infrastructure: Effect.Effect<
    { readonly status: number; readonly body: unknown },
    CloudVerificationError
  >,
): CloudInspectionBoundary & CloudFixtureBoundary {
  const r2Exposure = Effect.all({
    devUrl: run(["r2", "bucket", "dev-url", "get", target.resources.archiveBucket]),
    domains: run(["r2", "bucket", "domain", "list", target.resources.archiveBucket]),
  }).pipe(
    Effect.flatMap(({ devUrl, domains }) => {
      const publicAccess = devUrl.includes("Public access is enabled at")
        ? true
        : devUrl.includes("Public access via the r2.dev URL is disabled")
          ? false
          : undefined;
      if (publicAccess === undefined) {
        return cloudVerificationError(
          `Wrangler returned an unknown R2 development URL status: ${target.resources.archiveBucket}`,
        );
      }
      return Effect.succeed({
        publicAccess,
        customDomainCount: domains.includes("There are no custom domains connected to this bucket")
          ? 0
          : 1,
      });
    }),
  );
  return {
    workerDeployment: run([
      "deployments",
      "status",
      "--name",
      target.resources.apiWorker,
      "--json",
    ]),
    r2Exposure,
    infrastructure,
    putObject: (bucket, key, content) =>
      run(
        [
          "r2",
          "object",
          "put",
          `${bucket}/${key}`,
          "--remote",
          "--pipe",
          "--content-type",
          "application/json",
          "--force",
        ],
        content,
      ).pipe(Effect.asVoid),
    getObject: (bucket, key) =>
      run(["r2", "object", "get", `${bucket}/${key}`, "--remote", "--pipe"]),
    writeCatalog: (database, fixtureId) =>
      run([
        "d1",
        "execute",
        database,
        "--remote",
        "--yes",
        "--json",
        "--command",
        `CREATE TABLE IF NOT EXISTS trigo_infrastructure_fixture (fixture_id TEXT PRIMARY KEY, seeded_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP); INSERT OR IGNORE INTO trigo_infrastructure_fixture (fixture_id) VALUES ('${fixtureId}')`,
      ]).pipe(Effect.asVoid),
    readCatalog: (database, fixtureId) =>
      run([
        "d1",
        "execute",
        database,
        "--remote",
        "--yes",
        "--json",
        "--command",
        `SELECT fixture_id FROM trigo_infrastructure_fixture WHERE fixture_id = '${fixtureId}'`,
      ]),
  };
}

const expectedBindings = {
  archive: "configured",
  catalog: "configured",
  workflow: "configured",
  workersAi: "configured-not-verified",
  assemblyAi: "configured-not-verified",
} as const;

export const inspectCloudInfrastructure = Effect.fn("CloudVerifier.inspect")(function* (
  target: CloudTarget,
  accountId: string,
  apiUrl: string,
  boundary: CloudInspectionBoundary,
) {
  const deployment = yield* boundary.workerDeployment.pipe(
    Effect.flatMap((value) =>
      decodeUnknownJson(value).pipe(
        Effect.mapError((cause) =>
          cloudVerificationError(
            `Cloud Worker deployment status is malformed: ${target.resources.apiWorker}`,
            cause,
          ),
        ),
      ),
    ),
  );
  if (
    typeof deployment !== "object" ||
    deployment === null ||
    Array.isArray(deployment) ||
    Object.keys(deployment).length === 0
  ) {
    return yield* cloudVerificationError(
      `Cloud Worker deployment status is malformed: ${target.resources.apiWorker}`,
    );
  }

  const r2Exposure = yield* boundary.r2Exposure;
  if (r2Exposure.publicAccess) {
    return yield* cloudVerificationError(
      `R2 public access is enabled: ${target.resources.archiveBucket}`,
    );
  }
  if (r2Exposure.customDomainCount !== 0) {
    return yield* cloudVerificationError(
      `R2 custom domains are present: ${target.resources.archiveBucket}`,
    );
  }

  const response = yield* boundary.infrastructure;
  if (response.status < 200 || response.status >= 300) {
    return yield* cloudVerificationError(
      `Cloud infrastructure endpoint failed: ${apiUrl} (${response.status})`,
    );
  }
  const reported = response.body;
  const expectedIdentity = cloudDeploymentIdentity(target, accountId);
  const reportedIdentity =
    typeof reported === "object" && reported !== null
      ? Reflect.get(reported, "identity")
      : undefined;
  const bindings =
    typeof reported === "object" && reported !== null
      ? Reflect.get(reported, "bindings")
      : undefined;
  if (
    typeof reported !== "object" ||
    reported === null ||
    Reflect.get(reported, "stage") !== target.stage ||
    reportedIdentity !== expectedIdentity ||
    typeof bindings !== "object" ||
    bindings === null ||
    Object.entries(expectedBindings).some(
      ([key, expected]) => Reflect.get(bindings, key) !== expected,
    )
  ) {
    return yield* cloudVerificationError(
      reportedIdentity !== expectedIdentity
        ? "Cloud infrastructure endpoint reported an unexpected target identity"
        : "Cloud infrastructure endpoint reported unexpected bindings",
    );
  }

  return {
    stage: target.stage,
    identity: expectedIdentity,
    worker: target.resources.apiWorker,
    archiveBucket: target.resources.archiveBucket,
    r2PublicAccess: "disabled" as const,
    r2CustomDomains: 0,
    bindings: expectedBindings,
  };
});

const fixture = Effect.fn("CloudVerifier.fixture")(function* (
  target: CloudTarget,
  fixtureId: string,
) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(fixtureId)) {
    return yield* cloudVerificationError("Cloud fixture ID must be a canonical lowercase UUIDv4");
  }
  const objectKey = `acceptance/issue-29/${fixtureId}.json`;
  return {
    fixtureId,
    objectKey,
    content: `${encodeUnknownJson({ kind: "trigo-infrastructure-fixture", version: 1, fixtureId })}\n`,
    archiveBucket: target.resources.archiveBucket,
    catalogDatabase: target.resources.catalogDatabase,
  };
});

export const seedCloudFixture = Effect.fn("CloudVerifier.seedFixture")(function* (
  target: CloudTarget,
  fixtureId: string,
  boundary: CloudFixtureBoundary,
) {
  if (target.stage !== "dev") {
    return yield* cloudVerificationError("Cloud fixtures may target only dev");
  }
  const expected = yield* fixture(target, fixtureId);
  yield* boundary.putObject(expected.archiveBucket, expected.objectKey, expected.content);
  yield* boundary.writeCatalog(expected.catalogDatabase, fixtureId);
});

export const verifyCloudFixture = Effect.fn("CloudVerifier.verifyFixture")(function* (
  target: CloudTarget,
  fixtureId: string,
  boundary: CloudFixtureBoundary,
) {
  if (target.stage !== "dev") {
    return yield* cloudVerificationError("Cloud fixtures may target only dev");
  }
  const expected = yield* fixture(target, fixtureId);
  const object = yield* boundary.getObject(expected.archiveBucket, expected.objectKey);
  if (object !== expected.content) {
    return yield* cloudVerificationError(`R2 fixture changed or is missing: ${fixtureId}`);
  }
  const catalog = yield* boundary
    .readCatalog(expected.catalogDatabase, fixtureId)
    .pipe(
      Effect.flatMap((value) =>
        decodeD1FixtureResult(value).pipe(
          Effect.mapError((cause) =>
            cloudVerificationError(`D1 fixture response is malformed: ${fixtureId}`, cause),
          ),
        ),
      ),
    );
  if (!catalog.some((statement) => statement.results.some((row) => row.fixture_id === fixtureId))) {
    return yield* cloudVerificationError(`D1 fixture changed or is missing: ${fixtureId}`);
  }
  return {
    fixtureId,
    objectKey: expected.objectKey,
    archiveBucket: expected.archiveBucket,
    catalogDatabase: expected.catalogDatabase,
  };
});

function productionWranglerRunner(
  root: string,
  cloudEnvironment: NodeJS.ProcessEnv,
): WranglerRunner {
  return Effect.fn("Wrangler.run")((args: readonly string[], input?: string) =>
    Effect.try({
      try: () => {
        const result = spawnSync(
          "node",
          [resolve(root, "node_modules/wrangler/bin/wrangler.js"), ...args],
          {
            cwd: root,
            env: { ...process.env, ...cloudEnvironment },
            encoding: "utf8",
            input,
          },
        );
        if (result.error) {
          throw result.error;
        }
        if (result.status !== 0) {
          throw new Error(
            `Wrangler ${args.slice(0, 3).join(" ")} failed (${result.status ?? result.signal}): ${result.stderr.trim()}`,
          );
        }
        return result.stdout;
      },
      catch: (cause) => cloudVerificationCause("Wrangler execution failed", cause),
    }),
  );
}

function liveOwnerStatusBoundary(apiUrl: string): CloudOwnerStatusBoundary {
  const status = Effect.fn("CloudVerifier.liveOwnerStatus")(function* (ownerToken: OwnerToken) {
    const response = yield* HttpClient.execute(
      HttpClientRequest.get(`${apiUrl}/v1/status`).pipe(HttpClientRequest.bearerToken(ownerToken)),
    ).pipe(
      Effect.mapError((cause) =>
        cloudVerificationError(`Cloud owner status request failed: ${apiUrl}`, cause),
      ),
      Effect.provide(FetchHttpClient.layer),
      Effect.provideService(FetchHttpClient.RequestInit, { redirect: "error" }),
    );
    return yield* response.json.pipe(
      Effect.map((body) => ({ status: response.status, body })),
      Effect.mapError((cause) =>
        cloudVerificationError(`Cloud owner status request failed: ${apiUrl}`, cause),
      ),
    );
  });
  return { status };
}

const main = Effect.gen(function* () {
  const verification = yield* Effect.try({
    try: () => parseCloudVerification(process.argv.slice(2)),
    catch: (cause) => cloudVerificationCause("Cloud verification arguments are invalid", cause),
  });
  const accountId = yield* Config.nonEmptyString("CLOUDFLARE_ACCOUNT_ID").pipe(
    Effect.mapError((cause) =>
      cloudVerificationError("Missing CLOUDFLARE_ACCOUNT_ID for test:cloud", cause),
    ),
  );
  if (!/^[0-9a-f]{32}$/i.test(accountId)) {
    return yield* cloudVerificationError(
      "CLOUDFLARE_ACCOUNT_ID must be exactly 32 hexadecimal characters",
    );
  }
  const apiToken = yield* Config.redacted("CLOUDFLARE_API_TOKEN").pipe(
    Effect.mapError((cause) =>
      cloudVerificationError("Missing CLOUDFLARE_API_TOKEN for test:cloud", cause),
    ),
  );
  const apiUrl = yield* Config.nonEmptyString("TRIGO_CLOUD_API_URL").pipe(
    Effect.mapError((cause) =>
      cloudVerificationError("Missing TRIGO_CLOUD_API_URL for test:cloud", cause),
    ),
  );
  const target = cloudTargetFor(verification.stage);
  const root = fileURLToPath(new URL("..", import.meta.url));
  const infrastructureRequest = HttpClient.get(`${apiUrl}/__trigo/infrastructure`).pipe(
    Effect.flatMap((response) =>
      response.json.pipe(Effect.map((body) => ({ status: response.status, body }))),
    ),
    Effect.mapError((cause) =>
      cloudVerificationError(`Cloud infrastructure request failed: ${apiUrl}`, cause),
    ),
    Effect.provide(FetchHttpClient.layer),
    Effect.provideService(FetchHttpClient.RequestInit, { redirect: "error" }),
  );
  const ownerStatusBoundary = liveOwnerStatusBoundary(apiUrl);
  const boundary = makeWranglerBoundary(
    target,
    productionWranglerRunner(root, {
      CLOUDFLARE_ACCOUNT_ID: accountId,
      CLOUDFLARE_API_TOKEN: Redacted.value(apiToken),
    }),
    infrastructureRequest,
  );
  const infrastructure = yield* inspectCloudInfrastructure(target, accountId, apiUrl, boundary);
  const fixture =
    verification.mode === "inspect" || verification.mode === "owner"
      ? undefined
      : verification.mode === "seed"
        ? yield* seedCloudFixture(target, verification.fixtureId, boundary).pipe(
            Effect.andThen(verifyCloudFixture(target, verification.fixtureId, boundary)),
          )
        : yield* verifyCloudFixture(target, verification.fixtureId, boundary);
  const owner =
    verification.mode === "owner"
      ? yield* readOwnerHandoff(verification.handoffPath, verification.stage).pipe(
          Effect.mapError((cause) =>
            cloudVerificationError("Cannot load owner handoff for status verification", cause),
          ),
          Effect.andThen((handoff) =>
            verifyCloudOwnerStatus(
              verification.stage,
              handoff,
              ownerHandoffTarget(target, accountId),
              ownerStatusBoundary,
            ),
          ),
        )
      : undefined;
  yield* Console.log(
    encodePrettyJson({
      infrastructure,
      ...(fixture === undefined ? {} : { fixture }),
      ...(owner === undefined ? {} : { owner }),
    }),
  );
});

if (import.meta.main) {
  try {
    await Effect.runPromise(main);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
