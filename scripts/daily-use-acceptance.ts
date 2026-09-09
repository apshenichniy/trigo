import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { commandOptions } from "./arguments.ts";
import { generateMasterTemplate } from "./asr-master-fixtures.ts";
import { sourceState } from "./check-inputs.ts";
import { cloudTargetFor, readCloudConfiguration } from "./cloud.ts";
import { lockedSwiftArguments, swiftTestBuild } from "./native-check.ts";
import { beginTiming, timedRun } from "./timing.ts";

export function parseDailyUseOptions(args: readonly string[], root = process.cwd()) {
  const [action, ...flags] = args;
  if (action !== "prepare" && action !== "run") {
    throw new Error("Expected prepare or run.");
  }
  const options = commandOptions("daily-use-acceptance", flags, {
    "--stage": "value",
    "--profile": "value",
    "--directory": "value",
    "--config": "value",
    "--local-config": "value",
    "--plan-sha256": "value",
    "--allow-paid": "flag",
  });
  const profile = options.get("--profile");
  const directory = options.get("--directory");
  if (
    options.get("--stage") !== "dev" ||
    (profile !== "one-hour" && profile !== "three-hour" && profile !== "local-smoke") ||
    typeof directory !== "string"
  ) {
    throw new Error("Pass --stage dev, --profile one-hour|three-hour|local-smoke and --directory.");
  }
  const destination = resolve(root, directory);
  if (
    dirname(destination) !== resolve(root, ".local") ||
    !/^daily-use-acceptance-[a-z0-9-]+$/.test(destination.slice(dirname(destination).length + 1))
  ) {
    throw new Error(
      "Use a dedicated .local/daily-use-acceptance-<name> directory in this checkout.",
    );
  }
  const local = profile === "local-smoke";
  const configuration = options.get(local ? "--local-config" : "--config");
  if (typeof configuration !== "string" || options.has(local ? "--config" : "--local-config")) {
    throw new Error(
      "The local-smoke profile requires only --local-config; hosted profiles require --config.",
    );
  }
  const planSHA256 = options.get("--plan-sha256");
  const allowPaid = options.has("--allow-paid");
  if (action === "prepare" && (allowPaid || planSHA256 !== undefined)) {
    throw new Error("Preparation cannot admit a paid run.");
  }
  if (
    action === "run" &&
    (typeof planSHA256 !== "string" || !/^[a-f0-9]{64}$/.test(planSHA256) || allowPaid === local)
  ) {
    throw new Error(
      "Run requires the exact --plan-sha256 and --allow-paid only for a hosted profile.",
    );
  }
  return {
    action,
    profile,
    directory: destination,
    configuration: resolve(root, configuration),
    local,
    planSHA256: typeof planSHA256 === "string" ? planSHA256 : null,
    allowPaid,
  };
}

const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

function main() {
  const root = realpathSync(fileURLToPath(new URL("..", import.meta.url)));
  process.chdir(root);
  const options = parseDailyUseOptions(process.argv.slice(2), root);
  const source = sourceState(root);
  if (!options.local && source.dirty) {
    throw new Error(
      "Commit the reviewed hosted acceptance sources before preparing or running a plan.",
    );
  }
  beginTiming("daily-use-acceptance", { action: options.action, profile: options.profile });
  const cloud = options.local
    ? null
    : readCloudConfiguration(options.configuration, cloudTargetFor("dev"));
  if (cloud && (!cloud.apiUrl || !process.env.TRIGO_ASR_OPERATOR_TOKEN)) {
    throw new Error("The validated Dev configuration needs apiUrl and TRIGO_ASR_OPERATOR_TOKEN.");
  }
  mkdirSync(resolve(root, ".local"), { recursive: true });
  if (realpathSync(resolve(root, ".local")) !== resolve(root, ".local")) {
    throw new Error("The acceptance parent cannot be a symlink.");
  }
  if (existsSync(options.directory)) {
    if (
      lstatSync(options.directory).isSymbolicLink() ||
      realpathSync(options.directory) !== options.directory
    ) {
      throw new Error("The acceptance directory cannot be a symlink.");
    }
  } else if (options.action === "prepare") {
    mkdirSync(options.directory, { mode: 0o700 });
  } else {
    throw new Error("Prepare the fixed input directory first.");
  }
  const configurationSHA256 = hash(readFileSync(options.configuration));
  const ownerPath = resolve(options.directory, "owner.json");
  const owner = JSON.stringify({
    kind: "trigo-synthetic-daily-use-v1",
    root,
    profile: options.profile,
    source,
    configurationSHA256,
  });
  if (existsSync(ownerPath)) {
    if (
      !lstatSync(ownerPath).isFile() ||
      lstatSync(ownerPath).isSymbolicLink() ||
      lstatSync(ownerPath).size > 16_384 ||
      readFileSync(ownerPath, "utf8") !== owner
    ) {
      throw new Error(
        "This prepared directory belongs to different inputs; evidence was preserved.",
      );
    }
  } else {
    if (options.action !== "prepare" || readdirSync(options.directory).length !== 0) {
      throw new Error(
        "Refusing to claim an existing nonempty directory without its exact ownership record.",
      );
    }
    writeFileSync(ownerPath, owner, { mode: 0o600, flag: "wx" });
  }
  const planPath = resolve(options.directory, "plan.json");
  if (options.action === "run") {
    if (
      !existsSync(planPath) ||
      lstatSync(planPath).size > 16_384 ||
      hash(readFileSync(planPath)) !== options.planSHA256
    ) {
      throw new Error("The prepared plan differs from the exact admitted hash.");
    }
  } else if (!existsSync(resolve(options.directory, "template.caf"))) {
    generateMasterTemplate("en", resolve(options.directory, "template.caf"));
  }
  const invocationId = randomUUID();
  const invocationPath = resolve(options.directory, "invocation-" + invocationId + ".json");
  const resultPath = resolve(options.directory, "result-" + invocationId + ".json");
  writeFileSync(
    invocationPath,
    JSON.stringify({
      schemaVersion: 1,
      invocationId,
      ...options,
      root,
      source,
      configurationSHA256,
      apiURL: cloud?.apiUrl ?? null,
      accountID: cloud?.accountId ?? null,
      resultPath,
    }),
    { mode: 0o600, flag: "wx" },
  );
  swiftTestBuild("apps/macos", "release");
  if (sourceState(root).fingerprint !== source.fingerprint) {
    throw new Error("Acceptance sources changed during compilation.");
  }
  timedRun(
    "Native daily-use " + options.action,
    [
      "swift",
      "test",
      ...lockedSwiftArguments("apps/macos"),
      "--configuration",
      "release",
      "--skip-build",
      "--filter",
      "DailyUseAcceptanceTests/executesOnlyTheExplicitPreparedAcceptanceInvocation",
    ],
    { env: { ...process.env, TRIGO_DAILY_USE_INVOCATION: invocationPath } },
  );
  if (sourceState(root).fingerprint !== source.fingerprint) {
    throw new Error("Acceptance sources changed during execution.");
  }
  const result: unknown = JSON.parse(readFileSync(resultPath, "utf8"));
  if (
    typeof result !== "object" ||
    result === null ||
    Reflect.get(result, "invocationId") !== invocationId ||
    Reflect.get(result, "action") !== options.action ||
    Reflect.get(result, "profile") !== options.profile ||
    Reflect.get(result, "passed") !== true
  ) {
    throw new Error(
      "The native acceptance did not produce the current invocation's successful receipt.",
    );
  }
  console.log(JSON.stringify(result));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
