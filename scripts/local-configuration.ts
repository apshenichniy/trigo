import { createHash, randomBytes, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  writeFileSync,
  constants,
} from "node:fs";
import { dirname } from "node:path";
import { validateStructure, type LocalDevelopmentBridge } from "../packages/contracts/src/index.ts";

export type LocalConfiguration = LocalDevelopmentBridge;
const decode = (value: unknown): LocalConfiguration =>
  validateStructure("LocalDevelopmentBridge", value);

export function readLocalConfiguration(path: string, worktreeId: string): LocalConfiguration {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (
      !stat.isFile() ||
      stat.size > 8192 ||
      (stat.mode & 0o777) !== 0o600 ||
      (process.getuid && stat.uid !== process.getuid())
    )
      throw new Error("Local configuration must be an owned regular file with mode 0600");
    let value: LocalConfiguration;
    try {
      value = decode(JSON.parse(readFileSync(fd, "utf8")));
    } catch {
      throw new Error("Local configuration is invalid");
    }
    const port = Number(new URL(value.serverURL).port);
    if (
      value.worktreeId !== worktreeId ||
      !Number.isInteger(port) ||
      port < 1024 ||
      port > 65535 ||
      value.serverURL !== `http://127.0.0.1:${port}`
    )
      throw new Error("Local configuration does not match this worktree or loopback endpoint");
    return value;
  } finally {
    closeSync(fd);
  }
}

export function localConfiguration(
  path: string,
  worktreeId: string,
  serverURL: string,
): LocalConfiguration {
  if (existsSync(path)) {
    const value = readLocalConfiguration(path, worktreeId);
    if (value.serverURL !== serverURL)
      throw new Error(
        "Local endpoint changed; use the existing port or a new disposable local namespace",
      );
    return value;
  }
  const directory = dirname(path);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (lstatSync(directory).isSymbolicLink())
    throw new Error("Local configuration directory cannot be a symbolic link");
  const value = decode({
    formatVersion: 1,
    worktreeId,
    namespaceId: randomUUID(),
    serverURL,
    ownerToken: `trigo_v1_${Array.from(randomBytes(32), (byte) => byte.toString(16).padStart(2, "0")).join("")}`,
  });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  return readLocalConfiguration(path, worktreeId);
}

export function localWorkerEnvironment(
  configuration: LocalConfiguration,
  runId: string,
  port: number,
): NodeJS.ProcessEnv {
  return {
    PATH: process.env.PATH,
    TMPDIR: process.env.TMPDIR,
    LANG: "en_US.UTF-8",
    CI: "1",
    TRIGO_LOCAL: "1",
    TRIGO_LOCAL_PORT: String(port),
    TRIGO_LOCAL_RUN_ID: runId,
    TRIGO_LOCAL_ARCHIVE_ID: configuration.namespaceId,
    TRIGO_LOCAL_OWNER_VERIFIER: createHash("sha256").update(configuration.ownerToken).digest("hex"),
    ALCHEMY_TELEMETRY_DISABLED: "1",
    DO_NOT_TRACK: "1",
    CLOUDFLARE_ACCOUNT_ID: "00000000000000000000000000000000",
    CLOUDFLARE_API_TOKEN: "trigo-local-invalid-token",
  };
}
