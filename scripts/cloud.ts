import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type CloudStage = "dev" | "personal";
export type CloudInvocationAction = "bootstrap" | "deploy" | "test";
export type CloudAction = "preflight" | CloudInvocationAction;

export interface CloudTarget {
  readonly stage: CloudStage;
  readonly stack: "trigo-cloud";
  readonly profile: `trigo-cloud-${CloudStage}`;
  readonly configPath: `config/cloud/${CloudStage}.json`;
  readonly resources: {
    readonly archiveBucket: string;
    readonly catalogDatabase: string;
    readonly apiWorker: string;
    readonly workflow: string;
  };
}

export interface CloudConfiguration {
  readonly stage: CloudStage;
  readonly accountId: string;
  readonly profile: `trigo-cloud-${CloudStage}`;
  readonly apiUrl?: string;
  readonly personalDeploymentGate?: "blocked-by-32" | "approved-after-32";
}

export interface CloudInvocation {
  readonly program: "alchemy" | "cloud-verifier";
  readonly args: readonly string[];
  readonly env: {
    readonly ALCHEMY_PROFILE: string;
    readonly CLOUDFLARE_ACCOUNT_ID: string;
    readonly TRIGO_CLOUD_STAGE: CloudStage;
    readonly TRIGO_CLOUD_API_URL?: string;
  };
}

export interface CloudExecutionEnvironment {
  readonly root: string;
  readonly bun: string;
  readonly baseEnv: NodeJS.ProcessEnv;
}

export type CloudProcessSpawner = (
  program: string,
  args: readonly string[],
  options: { readonly cwd: string; readonly env: NodeJS.ProcessEnv },
) => {
  readonly status: number | null;
  readonly signal?: NodeJS.Signals | null | undefined;
  readonly error?: Error | undefined;
};

export function cloudTargetFor(stage: CloudStage): CloudTarget {
  return {
    stage,
    stack: "trigo-cloud",
    profile: `trigo-cloud-${stage}`,
    configPath: `config/cloud/${stage}.json`,
    resources: {
      archiveBucket: `trigo-${stage}-archive`,
      catalogDatabase: `trigo-${stage}-catalog`,
      apiWorker: `trigo-${stage}-api`,
      workflow: `trigo-${stage}-archive-workflow`,
    },
  };
}

export function cloudDeploymentIdentity(target: CloudTarget, accountId: string): string {
  const hash = createHash("sha256")
    .update(`${target.resources.apiWorker}:${accountId.toLowerCase()}`)
    .digest("hex")
    .slice(0, 16);
  return `${target.resources.apiWorker}:${hash}`;
}

function parseAction(value: string | undefined): CloudAction {
  if (value === "preflight" || value === "bootstrap" || value === "deploy" || value === "test")
    return value;
  throw new Error("Expected cloud action: preflight, bootstrap, deploy, or test");
}

export function parseCloudStage(args: readonly string[]): CloudStage {
  const stageIndexes = args.flatMap((value, index) => (value === "--stage" ? [index] : []));
  if (stageIndexes.length > 1) throw new Error("Pass exactly one --stage selector");
  const stageIndex = stageIndexes[0];
  const value = stageIndex === undefined ? undefined : args[stageIndex + 1];
  if (value !== "dev" && value !== "personal")
    throw new Error("Pass an explicit --stage dev or --stage personal");
  return value;
}

export function cloudConfigPath(args: readonly string[], target: CloudTarget): string {
  const configIndexes = args.flatMap((value, index) => (value === "--config" ? [index] : []));
  if (configIndexes.length > 1) throw new Error("Pass at most one --config selector");
  const configIndex = configIndexes[0];
  const configured = configIndex === undefined ? target.configPath : args[configIndex + 1];
  if (!configured || configured.startsWith("-"))
    throw new Error("Pass a configuration path after --config");
  return resolve(configured);
}

export function readCloudConfiguration(path: string, target: CloudTarget): CloudConfiguration {
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Cloud configuration is not valid JSON: ${path}`, { cause: error });
  }
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error(`Cloud configuration must be a JSON object: ${path}`);

  const allowed = new Set(["stage", "accountId", "profile", "apiUrl", "personalDeploymentGate"]);
  const unexpected = Object.keys(value).filter((key) => !allowed.has(key));
  if (unexpected.length > 0)
    throw new Error(`Unknown cloud configuration field: ${unexpected.join(", ")}`);

  const stage = Reflect.get(value, "stage");
  const accountId = Reflect.get(value, "accountId");
  const profile = Reflect.get(value, "profile");
  const apiUrl = Reflect.get(value, "apiUrl");
  const personalDeploymentGate = Reflect.get(value, "personalDeploymentGate");

  if (stage !== target.stage) throw new Error(`Cloud stage mismatch: expected ${target.stage}`);
  if (profile !== target.profile)
    throw new Error(`Cloud profile mismatch: expected ${target.profile}`);
  if (typeof accountId !== "string" || !/^[0-9a-f]{32}$/i.test(accountId))
    throw new Error("Cloud accountId must be exactly 32 hexadecimal characters");
  let normalizedApiUrl: string | undefined;
  if (apiUrl !== undefined) {
    try {
      if (typeof apiUrl !== "string") throw new Error("not a string");
      const parsed = new URL(apiUrl);
      if (
        parsed.protocol !== "https:" ||
        parsed.username !== "" ||
        parsed.password !== "" ||
        parsed.pathname !== "/" ||
        parsed.search !== "" ||
        parsed.hash !== ""
      )
        throw new Error("not an HTTPS origin");
      normalizedApiUrl = parsed.origin;
    } catch (error) {
      throw new Error(
        "Cloud apiUrl must be an HTTPS origin without credentials, path, query, or fragment",
        { cause: error },
      );
    }
  }
  if (
    personalDeploymentGate !== undefined &&
    personalDeploymentGate !== "blocked-by-32" &&
    personalDeploymentGate !== "approved-after-32"
  )
    throw new Error(
      "personalDeploymentGate must be blocked-by-32 or approved-after-32 when present",
    );

  return {
    stage: target.stage,
    accountId: accountId.toLowerCase(),
    profile: target.profile,
    ...(normalizedApiUrl === undefined ? {} : { apiUrl: normalizedApiUrl }),
    ...(personalDeploymentGate === undefined ? {} : { personalDeploymentGate }),
  };
}

function readJsonObject(path: string, description: string): object {
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`${description} is missing or invalid: ${path}`, { cause: error });
  }
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new Error(`${description} must be a JSON object: ${path}`);
  return value;
}

export function validateAlchemyProfileAccount(
  configuration: CloudConfiguration,
  alchemyRoot = resolve(homedir(), ".alchemy"),
): void {
  const profilesPath = resolve(alchemyRoot, "profiles.json");
  const configureProfile = `alchemy login --configure --profile ${configuration.profile}`;
  if (!existsSync(profilesPath))
    throw new Error(
      `Alchemy profile ${configuration.profile} is not configured for Cloudflare; run ${configureProfile} and confirm the intended account`,
    );
  const config = readJsonObject(profilesPath, "Alchemy profile registry");
  const profiles = Reflect.get(config, "profiles");
  const profile =
    typeof profiles === "object" && profiles !== null
      ? Reflect.get(profiles, configuration.profile)
      : undefined;
  const provider =
    typeof profile === "object" && profile !== null
      ? Reflect.get(profile, "Cloudflare")
      : undefined;
  if (typeof provider !== "object" || provider === null)
    throw new Error(
      `Alchemy profile ${configuration.profile} is not configured for Cloudflare; run ${configureProfile} and confirm the intended account`,
    );

  const method = Reflect.get(provider, "method");
  let profileAccountId: unknown;
  if (method === "env") return;
  if (method === "oauth") {
    profileAccountId = Reflect.get(provider, "accountId");
  } else if (method === "stored") {
    const credentialsPath = resolve(
      alchemyRoot,
      "credentials",
      configuration.profile,
      "cf-stored.json",
    );
    const credentials = readJsonObject(credentialsPath, "Alchemy stored Cloudflare credentials");
    profileAccountId = Reflect.get(credentials, "accountId");
    if (profileAccountId === undefined || profileAccountId === "") return;
  } else {
    throw new Error(
      `Alchemy profile ${configuration.profile} uses unsupported Cloudflare method: ${String(method)}`,
    );
  }

  if (
    typeof profileAccountId !== "string" ||
    profileAccountId.toLowerCase() !== configuration.accountId
  )
    throw new Error(
      `Alchemy profile ${configuration.profile} belongs to a different Cloudflare account; rerun ${configureProfile} and confirm the intended account`,
    );
}

export function preflightCloudConfiguration(
  configPath: string,
  target: CloudTarget,
  alchemyRoot = resolve(homedir(), ".alchemy"),
): CloudConfiguration {
  if (!existsSync(configPath)) throw new Error(`Cloud configuration not found: ${configPath}`);
  const configuration = readCloudConfiguration(configPath, target);
  validateAlchemyProfileAccount(configuration, alchemyRoot);
  return configuration;
}

function rejectUnexpectedCloudActionArgument(
  action: CloudAction,
  actionArgs: readonly string[],
): void {
  const unsupportedArgument = action === "test" ? undefined : actionArgs[0];
  if (unsupportedArgument !== undefined)
    throw new Error(`Unexpected ${action} argument: ${unsupportedArgument}`);
}

export function cloudInvocationFor(
  action: CloudInvocationAction,
  target: CloudTarget,
  configuration: CloudConfiguration,
  actionArgs: readonly string[] = [],
): CloudInvocation {
  rejectUnexpectedCloudActionArgument(action, actionArgs);
  if (action === "test" && target.stage !== "dev")
    throw new Error("test:cloud fixtures are destructive and may target only --stage dev");
  if (action === "test" && configuration.apiUrl === undefined)
    throw new Error(`test:cloud requires apiUrl in ${target.configPath}`);
  if (
    action === "deploy" &&
    target.stage === "personal" &&
    configuration.personalDeploymentGate !== "approved-after-32"
  )
    throw new Error(
      "Personal deployment is blocked until #32 is accepted and personalDeploymentGate is approved-after-32",
    );
  const env = {
    ALCHEMY_PROFILE: configuration.profile,
    CLOUDFLARE_ACCOUNT_ID: configuration.accountId,
    TRIGO_CLOUD_STAGE: target.stage,
    ...(configuration.apiUrl === undefined ? {} : { TRIGO_CLOUD_API_URL: configuration.apiUrl }),
  };
  if (action === "bootstrap")
    return {
      program: "alchemy",
      args: ["cloudflare", "bootstrap", "--profile", target.profile],
      env,
    };
  if (action === "deploy")
    return {
      program: "alchemy",
      args: [
        "deploy",
        "--stage",
        target.stage,
        "--profile",
        target.profile,
        "--yes",
        "infra/cloud.ts",
      ],
      env,
    };
  return {
    program: "cloud-verifier",
    args: ["--stage", target.stage, ...actionArgs],
    env,
  };
}

export function cloudActionArguments(args: readonly string[]): readonly string[] {
  const forwarded: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const value = args[index];
    if (value === "--stage" || value === "--config") {
      index += 1;
      continue;
    }
    if (value !== undefined) forwarded.push(value);
  }
  return forwarded;
}

export function executeCloudInvocation(
  invocation: CloudInvocation,
  environment: CloudExecutionEnvironment,
  spawn: CloudProcessSpawner = (program, args, options) =>
    spawnSync(program, [...args], { ...options, stdio: "inherit" }),
): number {
  const entrypoint =
    invocation.program === "alchemy"
      ? resolve(environment.root, "infra/node_modules/alchemy/bin/alchemy.js")
      : resolve(environment.root, "scripts/cloud-verify.ts");
  const prefix = invocation.program === "alchemy" ? ["--bun", entrypoint] : [entrypoint];
  const result = spawn(environment.bun, [...prefix, ...invocation.args], {
    cwd: environment.root,
    env: { ...environment.baseEnv, ...invocation.env },
  });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

if (import.meta.main) {
  try {
    const [action, ...args] = process.argv.slice(2);
    const parsedAction = parseAction(action);
    const target = cloudTargetFor(parseCloudStage(args));
    const actionArgs = cloudActionArguments(args);
    rejectUnexpectedCloudActionArgument(parsedAction, actionArgs);
    const config = cloudConfigPath(args, target);
    const configuration =
      parsedAction === "test"
        ? (() => {
            if (!existsSync(config)) throw new Error(`Cloud configuration not found: ${config}`);
            return readCloudConfiguration(config, target);
          })()
        : preflightCloudConfiguration(config, target);
    if (parsedAction === "preflight") {
      console.log(`Cloud preflight passed for profile ${configuration.profile}`);
    } else {
      const invocation = cloudInvocationFor(parsedAction, target, configuration, actionArgs);
      process.exitCode = executeCloudInvocation(invocation, {
        root: fileURLToPath(new URL("..", import.meta.url)),
        bun: process.execPath,
        baseEnv: process.env,
      });
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
