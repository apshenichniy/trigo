import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

export const PROTECTED_DEV_ACCOUNT_ID = "27940cd0d92bb3f03943a5378ccf68d3";
export const APPROVED_DISPOSABLE_ACCOUNT_ID = "3fd3cd769d5d372e6757d0ec208a74f2";

export const EXPECTED_STATE_STORE_LOGICAL_IDS = [
  "StateStoreSecrets",
  "StateStoreAuthTokenValue",
  "AlchemyStateStoreToken",
  "StateStoreEncryptionKeyValue",
  "StateStoreEncryptionKey",
  "Api",
] as const;

const PURPOSE = "issue-29-interrupted-bootstrap" as const;
const STATE_STORE_SCRIPT = "alchemy-state-store" as const;
const PENDING_STATE_STORE_ORIGIN = "pending-first-worker" as const;
const MARKER = "ARMED" as const;
const PLACEHOLDER_PROFILE = "trigo-cloud-issue-29-interrupt-replace-me" as const;
const STATE_STORE_ORIGIN_ERROR =
  "stateStoreOrigin must be the pending sentinel or verified state-store HTTPS origin";
const STATE_STORE_HOSTNAME = /^alchemy-state-store\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.workers\.dev$/;

export interface BootstrapInterruptionConfiguration {
  readonly purpose: typeof PURPOSE;
  readonly accountId: string;
  readonly profile: string;
  readonly stateStoreOrigin: string;
  readonly protectedAccountIds: readonly string[];
}

export interface BootstrapInterruptionEnvironment {
  readonly alchemyRoot: string;
  readonly workspaceRoot: string;
  readonly env: NodeJS.ProcessEnv;
  readonly umask?: number;
}

export interface BootstrapInterruptionSummary {
  readonly accountId: string;
  readonly profile: string;
  readonly localStage: string;
}

type InterruptedBootstrapSummary = BootstrapInterruptionSummary & {
  readonly resourceCount: number;
  readonly statuses: readonly string[];
};

const defaultEnvironment = (): BootstrapInterruptionEnvironment => ({
  alchemyRoot: resolve(homedir(), ".alchemy"),
  workspaceRoot: process.cwd(),
  env: process.env,
  umask: process.umask(),
});

function readJsonObject(path: string, description: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`${description} is missing or invalid JSON: ${path}`, { cause: error });
  }
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error(`${description} must be a JSON object: ${path}`);
  return value as Record<string, unknown>;
}

function accountId(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{32}$/i.test(value))
    throw new Error(`${field} must be exactly 32 hexadecimal characters`);
  return value.toLowerCase();
}

export function readBootstrapInterruptionConfiguration(
  path: string,
): BootstrapInterruptionConfiguration {
  const value = readJsonObject(path, "Bootstrap interruption configuration");
  const allowed = new Set([
    "purpose",
    "accountId",
    "profile",
    "stateStoreOrigin",
    "protectedAccountIds",
  ]);
  const unexpected = Object.keys(value).filter((key) => !allowed.has(key));
  if (unexpected.length > 0)
    throw new Error(`Unknown bootstrap interruption field: ${unexpected.join(", ")}`);
  if (value.purpose !== PURPOSE) throw new Error(`purpose must be exactly ${PURPOSE}`);

  const disposableAccountId = accountId(value.accountId, "accountId");
  if (disposableAccountId !== APPROVED_DISPOSABLE_ACCOUNT_ID)
    throw new Error(
      `accountId must be the approved Trigo Recovery Disposable account ${APPROVED_DISPOSABLE_ACCOUNT_ID}`,
    );
  if (
    typeof value.profile !== "string" ||
    !/^trigo-cloud-issue-29-interrupt-[a-z0-9][a-z0-9-]{5,31}$/.test(value.profile)
  )
    throw new Error(
      "profile must be unique and match trigo-cloud-issue-29-interrupt-<6-32 lowercase characters>",
    );
  if (value.profile === PLACEHOLDER_PROFILE)
    throw new Error("Replace the example profile suffix with a unique one-use value");
  let stateStoreOrigin = PENDING_STATE_STORE_ORIGIN as string;
  if (value.stateStoreOrigin !== PENDING_STATE_STORE_ORIGIN) {
    let verifiedStateStoreOrigin: URL;
    try {
      verifiedStateStoreOrigin = new URL(
        typeof value.stateStoreOrigin === "string" ? value.stateStoreOrigin : "",
      );
    } catch (error) {
      throw new Error(STATE_STORE_ORIGIN_ERROR, { cause: error });
    }
    if (
      verifiedStateStoreOrigin.protocol !== "https:" ||
      verifiedStateStoreOrigin.username !== "" ||
      verifiedStateStoreOrigin.password !== "" ||
      verifiedStateStoreOrigin.port !== "" ||
      verifiedStateStoreOrigin.pathname !== "/" ||
      verifiedStateStoreOrigin.search !== "" ||
      verifiedStateStoreOrigin.hash !== "" ||
      !STATE_STORE_HOSTNAME.test(verifiedStateStoreOrigin.hostname)
    )
      throw new Error(STATE_STORE_ORIGIN_ERROR);
    stateStoreOrigin = verifiedStateStoreOrigin.origin;
  }
  if (!Array.isArray(value.protectedAccountIds))
    throw new Error("protectedAccountIds must be an array of Cloudflare account IDs");
  const protectedAccountIds = value.protectedAccountIds.map((id, index) =>
    accountId(id, `protectedAccountIds[${index}]`),
  );
  if (!protectedAccountIds.includes(PROTECTED_DEV_ACCOUNT_ID))
    throw new Error(
      `protectedAccountIds must include working dev account ${PROTECTED_DEV_ACCOUNT_ID}`,
    );
  if (new Set(protectedAccountIds).size !== protectedAccountIds.length)
    throw new Error("protectedAccountIds must not contain duplicates");
  if (protectedAccountIds.includes(disposableAccountId))
    throw new Error("Disposable account must differ from every protected account");

  return {
    purpose: PURPOSE,
    accountId: disposableAccountId,
    profile: value.profile,
    stateStoreOrigin,
    protectedAccountIds,
  };
}

function localStage(configuration: BootstrapInterruptionConfiguration): string {
  return `${configuration.profile}_${STATE_STORE_SCRIPT}`;
}

function localStagePath(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): string {
  return resolve(
    environment.workspaceRoot,
    ".alchemy",
    "state",
    "CloudflareStateStore",
    localStage(configuration),
  );
}

function credentialProfilePath(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): string {
  return resolve(environment.alchemyRoot, "credentials", configuration.profile);
}

function credentialPath(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): string {
  return resolve(credentialProfilePath(configuration, environment), "cloudflare-state-store.json");
}

function markerPath(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): string {
  return resolve(credentialPath(configuration, environment), MARKER);
}

function expectedMarker(configuration: BootstrapInterruptionConfiguration): string {
  return `${PURPOSE}\n${configuration.accountId}\n${configuration.profile}\n`;
}

function requireStateStoreOrigin(configuration: BootstrapInterruptionConfiguration): string {
  if (configuration.stateStoreOrigin === PENDING_STATE_STORE_ORIGIN)
    throw new Error(
      "Resolve stateStoreOrigin after the first Worker deployment before asserting its checkpoint",
    );
  return configuration.stateStoreOrigin;
}

function assertRuntimeIdentity(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): void {
  const activeUmask = environment.umask ?? process.umask();
  if ((activeUmask & 0o077) !== 0o077)
    throw new Error("Set umask 077 before creating or reading bootstrap secrets");
  if (environment.env.CLOUDFLARE_ACCOUNT_ID?.toLowerCase() !== configuration.accountId)
    throw new Error("CLOUDFLARE_ACCOUNT_ID does not match the disposable configuration");
  if (!environment.env.CLOUDFLARE_API_TOKEN?.trim())
    throw new Error("CLOUDFLARE_API_TOKEN is required for the disposable experiment");
  if (environment.env.ALCHEMY_PROFILE !== configuration.profile)
    throw new Error("ALCHEMY_PROFILE does not match the disposable configuration");
}

function assertPrivateMode(path: string, description: string): void {
  const mode = lstatSync(path).mode & 0o777;
  if ((mode & 0o077) !== 0)
    throw new Error(`${description} must not be readable or writable by group/other: ${path}`);
}

function assertEnvironmentProfile(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): void {
  const registry = readJsonObject(
    resolve(environment.alchemyRoot, "profiles.json"),
    "Alchemy profile registry",
  );
  const profiles = registry.profiles;
  const profile =
    typeof profiles === "object" && profiles !== null
      ? Reflect.get(profiles, configuration.profile)
      : undefined;
  if (typeof profile !== "object" || profile === null || Array.isArray(profile))
    throw new Error(`Disposable Alchemy profile is not configured: ${configuration.profile}`);
  const providers = Object.keys(profile);
  if (providers.length !== 1 || providers[0] !== "Cloudflare")
    throw new Error("Disposable Alchemy profile must contain only the Cloudflare provider");
  const provider = Reflect.get(profile, "Cloudflare");
  if (
    typeof provider !== "object" ||
    provider === null ||
    Reflect.get(provider, "method") !== "env"
  )
    throw new Error("Disposable Alchemy profile must use the env Cloudflare method");
}

function assertConfiguredIdentity(
  configPath: string,
  environment: BootstrapInterruptionEnvironment,
): BootstrapInterruptionConfiguration {
  const configuration = readBootstrapInterruptionConfiguration(configPath);
  assertRuntimeIdentity(configuration, environment);
  assertEnvironmentProfile(configuration, environment);
  return configuration;
}

export function preflightBootstrapInterruption(
  configPath: string,
  environment = defaultEnvironment(),
): BootstrapInterruptionSummary {
  const configuration = assertConfiguredIdentity(configPath, environment);
  return assertCleanInterruptionSeam(configuration, environment);
}

function assertCleanInterruptionSeam(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): BootstrapInterruptionSummary {
  if (existsSync(credentialProfilePath(configuration, environment)))
    throw new Error(
      `Disposable credential profile path already exists: ${credentialProfilePath(configuration, environment)}`,
    );
  if (existsSync(localStagePath(configuration, environment)))
    throw new Error(
      `Disposable local bootstrap stage already exists: ${localStagePath(configuration, environment)}`,
    );
  return {
    accountId: configuration.accountId,
    profile: configuration.profile,
    localStage: localStage(configuration),
  };
}

export function armBootstrapInterruption(
  configPath: string,
  environment = defaultEnvironment(),
): BootstrapInterruptionSummary & { readonly credentialCollisionPath: string } {
  const configuration = assertConfiguredIdentity(configPath, environment);
  const summary = assertCleanInterruptionSeam(configuration, environment);
  const collision = credentialPath(configuration, environment);
  if (existsSync(collision))
    throw new Error(`Experiment credential path already exists: ${collision}`);
  mkdirSync(collision, { recursive: true, mode: 0o700 });
  assertPrivateMode(
    credentialProfilePath(configuration, environment),
    "Credential profile directory",
  );
  assertPrivateMode(collision, "Credential collision directory");
  writeFileSync(markerPath(configuration, environment), expectedMarker(configuration), {
    flag: "wx",
    mode: 0o600,
  });
  return { ...summary, credentialCollisionPath: collision };
}

function assertArmedFixture(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): void {
  const collision = credentialPath(configuration, environment);
  if (!existsSync(collision) || !lstatSync(collision).isDirectory())
    throw new Error(`Armed interruption fixture is missing: ${collision}`);
  assertPrivateMode(
    credentialProfilePath(configuration, environment),
    "Credential profile directory",
  );
  assertPrivateMode(collision, "Credential collision directory");
  const entries = readdirSync(collision);
  if (entries.length !== 1 || entries[0] !== MARKER)
    throw new Error(`Armed interruption fixture contains unexpected entries: ${collision}`);
  if (
    readFileSync(markerPath(configuration, environment), "utf8") !== expectedMarker(configuration)
  )
    throw new Error(`Armed interruption marker does not match the disposable target: ${collision}`);
  assertPrivateMode(markerPath(configuration, environment), "Armed interruption marker");
}

function assertInterruptedBootstrapConfiguration(
  configuration: BootstrapInterruptionConfiguration,
  environment: BootstrapInterruptionEnvironment,
): InterruptedBootstrapSummary {
  const stateStoreOrigin = requireStateStoreOrigin(configuration);
  assertArmedFixture(configuration, environment);
  const stagePath = localStagePath(configuration, environment);
  if (!existsSync(stagePath) || !lstatSync(stagePath).isDirectory())
    throw new Error(`Interrupted local bootstrap stage is missing: ${stagePath}`);
  assertPrivateMode(stagePath, "Interrupted local bootstrap stage");
  const entries = readdirSync(stagePath);
  if (!entries.includes("__stack_output__.json"))
    throw new Error(
      "Interrupted bootstrap did not reach the completed local stack output checkpoint",
    );
  const unexpectedEntries = entries.filter(
    (entry) => entry !== "__stack_output__.json" && !entry.endsWith(".json"),
  );
  if (unexpectedEntries.length > 0)
    throw new Error(
      `Interrupted bootstrap checkpoint contains in-flight or unexpected files: ${unexpectedEntries.join(", ")}`,
    );
  const outputPath = resolve(stagePath, "__stack_output__.json");
  assertPrivateMode(outputPath, "Interrupted bootstrap stack output");
  const output = JSON.parse(readFileSync(outputPath, "utf8")) as unknown;
  if (typeof output !== "object" || output === null || Array.isArray(output))
    throw new Error("Interrupted bootstrap stack output is not an object");
  if (Reflect.get(output, "url") !== stateStoreOrigin)
    throw new Error("Interrupted bootstrap stack output has an unexpected state-store origin");
  const outputToken = Reflect.get(output, "authToken");
  if (typeof outputToken !== "string" || outputToken.trim().length === 0)
    throw new Error("Interrupted bootstrap stack output has no bearer token");

  const resourceFiles = entries.filter(
    (entry) => entry.endsWith(".json") && entry !== "__stack_output__.json",
  );
  if (resourceFiles.length === 0)
    throw new Error("Interrupted bootstrap checkpoint contains no resource state");
  const resources = resourceFiles.map((entry) => {
    const resourcePath = resolve(stagePath, entry);
    assertPrivateMode(resourcePath, "Interrupted bootstrap resource state");
    const value = JSON.parse(readFileSync(resourcePath, "utf8")) as unknown;
    if (typeof value !== "object" || value === null || Array.isArray(value))
      throw new Error(`Invalid resource state file: ${entry}`);
    const logicalId = Reflect.get(value, "logicalId");
    const status = Reflect.get(value, "status");
    const fqn = Reflect.get(value, "fqn");
    if (typeof logicalId !== "string" || typeof fqn !== "string" || typeof status !== "string")
      throw new Error(`Incomplete resource state file: ${entry}`);
    if (`${fqn.replaceAll("/", "__")}.json` !== entry)
      throw new Error(`Resource state filename does not match its FQN: ${entry}`);
    if (status !== "created" && status !== "updated")
      throw new Error(`Resource ${logicalId} is not settled at the interruption checkpoint`);
    return { logicalId, status };
  });
  const resourceLogicalIds = resources.map(({ logicalId }) => logicalId);
  const logicalIds = new Set(resourceLogicalIds);
  const missing = EXPECTED_STATE_STORE_LOGICAL_IDS.filter((id) => !logicalIds.has(id));
  const expected = new Set<string>(EXPECTED_STATE_STORE_LOGICAL_IDS);
  const unexpected = resourceLogicalIds.filter((id) => !expected.has(id));
  if (missing.length > 0 || unexpected.length > 0 || logicalIds.size !== resourceLogicalIds.length)
    throw new Error(
      `Interrupted bootstrap checkpoint resource identity mismatch (missing: ${missing.join(", ") || "none"}; unexpected: ${unexpected.join(", ") || "none"}; duplicates: ${logicalIds.size === resourceLogicalIds.length ? "none" : "present"})`,
    );

  return {
    accountId: configuration.accountId,
    profile: configuration.profile,
    localStage: localStage(configuration),
    resourceCount: resources.length,
    statuses: [...new Set(resources.map(({ status }) => status))].sort(),
  };
}

export function assertInterruptedBootstrap(
  configPath: string,
  environment = defaultEnvironment(),
): InterruptedBootstrapSummary {
  const configuration = assertConfiguredIdentity(configPath, environment);
  return assertInterruptedBootstrapConfiguration(configuration, environment);
}

export function disarmBootstrapInterruption(
  configPath: string,
  environment = defaultEnvironment(),
): BootstrapInterruptionSummary {
  const configuration = assertConfiguredIdentity(configPath, environment);
  assertInterruptedBootstrapConfiguration(configuration, environment);
  unlinkSync(markerPath(configuration, environment));
  rmdirSync(credentialPath(configuration, environment));
  return {
    accountId: configuration.accountId,
    profile: configuration.profile,
    localStage: localStage(configuration),
  };
}

export function assertRecoveredBootstrap(
  configPath: string,
  environment = defaultEnvironment(),
): BootstrapInterruptionSummary & {
  readonly localStageAbsent: true;
  readonly credentialAccountMatches: true;
} {
  const configuration = assertConfiguredIdentity(configPath, environment);
  const stateStoreOrigin = requireStateStoreOrigin(configuration);
  const stagePath = localStagePath(configuration, environment);
  if (existsSync(stagePath))
    throw new Error(`Recovered bootstrap left its local stage in place: ${stagePath}`);
  const cachePath = credentialPath(configuration, environment);
  if (!existsSync(cachePath) || !lstatSync(cachePath).isFile())
    throw new Error(`Recovered state credential cache is missing: ${cachePath}`);
  assertPrivateMode(
    credentialProfilePath(configuration, environment),
    "Credential profile directory",
  );
  assertPrivateMode(cachePath, "Recovered state credential cache");
  const cache = readJsonObject(cachePath, "Recovered state credential cache");
  if (cache.accountId !== configuration.accountId)
    throw new Error("Recovered state credential cache belongs to a different account");
  if (typeof cache.authToken !== "string" || cache.authToken.length === 0)
    throw new Error("Recovered state credential cache has no bearer token");
  if (cache.url !== stateStoreOrigin)
    throw new Error(
      "Recovered state credential cache does not match the verified state-store origin",
    );

  return {
    accountId: configuration.accountId,
    profile: configuration.profile,
    localStage: localStage(configuration),
    localStageAbsent: true,
    credentialAccountMatches: true,
  };
}

type Command = "preflight" | "arm" | "assert-interrupted" | "disarm" | "assert-recovered";

function parseCommand(args: readonly string[]): { command: Command; configPath: string } {
  const [command, selector, configPath, ...unexpected] = args;
  if (
    command !== "preflight" &&
    command !== "arm" &&
    command !== "assert-interrupted" &&
    command !== "disarm" &&
    command !== "assert-recovered"
  )
    throw new Error(
      "Expected action: preflight, arm, assert-interrupted, disarm, or assert-recovered",
    );
  if (selector !== "--config" || !configPath || unexpected.length > 0)
    throw new Error("Pass exactly one --config <path> selector and no other arguments");
  return { command, configPath: resolve(configPath) };
}

if (import.meta.main) {
  try {
    const { command, configPath } = parseCommand(process.argv.slice(2));
    const action =
      command === "preflight"
        ? preflightBootstrapInterruption
        : command === "arm"
          ? armBootstrapInterruption
          : command === "assert-interrupted"
            ? assertInterruptedBootstrap
            : command === "disarm"
              ? disarmBootstrapInterruption
              : assertRecoveredBootstrap;
    console.log(JSON.stringify(action(configPath), null, 2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
