import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, mkdirSync, realpathSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { validateDocument } from "../packages/contracts/src/index.ts";
import { commandOptions } from "./arguments.ts";
import { localConfiguration, localWorkerEnvironment } from "./local-configuration.ts";
import { canReuseNativeTests, lockedSwiftArguments } from "./native-check.ts";
import { assertNativeTestOutput } from "./native-suites.ts";
import { beginTiming, timedAsync, timingEnvironment } from "./timing.ts";
const options = commandOptions(
  "local dev (cloud stages and resource configuration are unavailable)",
  process.argv.slice(2),
  {
    "--test": "flag",
    "--native-client": "flag",
  },
);
const root = realpathSync(new URL("..", import.meta.url).pathname);
const testing = options.has("--test");
const nativeClient = options.has("--native-client");
if (nativeClient && !testing) {
  throw new Error(
    "Local dev accepts only --test [--native-client]; cloud stages and resource configuration are unavailable.",
  );
}
if (nativeClient && process.platform !== "darwin") {
  throw new Error("Native local acceptance requires macOS");
}
beginTiming(testing ? "test:local" : "dev", { nativeClient });
const id = createHash("sha256").update(root).digest("hex").slice(0, 12);
const requestedPort = Number(process.env.TRIGO_LOCAL_PORT ?? (testing ? 0 : 19371));
if (
  !Number.isInteger(requestedPort) ||
  (requestedPort !== 0 && requestedPort < 1024) ||
  requestedPort > 65535
) {
  throw new Error("TRIGO_LOCAL_PORT must be an integer in 1024..65535");
}
const port = await new Promise<number>((resolvePort, reject) => {
  const server = createServer();
  server.once("error", (error) =>
    reject(new Error(`Local port unavailable: ${requestedPort}`, { cause: error })),
  );
  server.listen(requestedPort, "127.0.0.1", () => {
    const address = server.address();
    if (!address || typeof address === "string") {
      server.close();
      reject(new Error("No local port"));
      return;
    }
    server.close(() => resolvePort(address.port));
  });
});
const directory = testing
  ? mkdtempSync(resolve(tmpdir(), "trigo-local-test-"))
  : resolve(root, ".local", id);
mkdirSync(directory, { recursive: true, mode: 0o700 });
const configurationPath = resolve(directory, "connection.json");
const base = `http://127.0.0.1:${port}`;
const configuration = localConfiguration(configurationPath, id, base);
const runId = randomUUID();
const env = localWorkerEnvironment(configuration, runId, port);
const command = [
  process.execPath,
  "--bun",
  resolve(root, "infra/node_modules/alchemy/bin/alchemy.js"),
  "dev",
  "--stage",
  `local-${id}`,
  "--profile",
  `trigo-local-${id}`,
  resolve(root, "infra/local.ts"),
];
if (process.platform === "darwin") {
  command.unshift("/usr/bin/sandbox-exec", "-f", resolve(root, "scripts/offline.sb"));
}

function start() {
  const child = spawn(command[0]!, command.slice(1), {
    cwd: directory,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  let output = "";
  child.stdout.on("data", (data) => {
    output += data;
    if (!testing) {
      process.stdout.write(data);
    }
  });
  child.stderr.on("data", (data) => {
    output += data;
    if (!testing) {
      process.stderr.write(data);
    }
  });
  return { child, output: () => output };
}
let server = start();
async function stop() {
  const child = server.child;
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  const exited = new Promise<void>((done) => child.once("exit", () => done()));
  try {
    process.kill(-child.pid!, "SIGTERM");
  } catch {}
  await exited;
}
process.on("SIGINT", () => {
  void stop();
});
process.on("SIGTERM", () => {
  void stop();
});
const request = (path: string, init: RequestInit = {}) =>
  fetch(`${base}${path}`, { ...init, signal: AbortSignal.timeout(5000) });
const ownerHeaders = { authorization: `Bearer ${configuration.ownerToken}` };
const probeHeaders = { "x-trigo-local-run": runId };
async function ready() {
  for (let i = 0; i < 120; i++) {
    if (
      server.child.exitCode !== null ||
      server.child.signalCode !== null ||
      /alchemy dev: (apply|run) failed/.test(server.output())
    ) {
      throw new Error(`Alchemy failed: ${server.output()}`);
    }
    try {
      const response = await request("/__local/health");
      const health: unknown = await response.json();
      if (
        response.ok &&
        typeof health === "object" &&
        health !== null &&
        "runId" in health &&
        health.runId === runId
      ) {
        return;
      }
    } catch {}
    await new Promise((done) => setTimeout(done, 500));
  }
  throw new Error(`Alchemy did not become ready: ${server.output()}`);
}
async function status() {
  const response = await request("/v1/status", { headers: ownerHeaders });
  const value = validateDocument("StatusResponse", await response.json());
  if (
    response.status !== 200 ||
    value.archiveId !== configuration.namespaceId ||
    value.stage !== "dev" ||
    value.readiness.callOperations !== "ready"
  ) {
    throw new Error("Local product status differs");
  }
  return value;
}
async function nativeAcceptance() {
  const env = timingEnvironment({
    PATH: process.env.PATH,
    TMPDIR: process.env.TMPDIR,
    DEVELOPER_DIR: process.env.DEVELOPER_DIR,
  });
  const receipt = process.env.TRIGO_NATIVE_BUILD_RECEIPT;
  if (receipt && canReuseNativeTests(receipt)) {
    console.log("Reused the parent check's verified current-source native test build.");
  } else {
    await timedAsync(
      "Local native current-source build",
      async () => {
        // Use the same current-source test build command as the full native gate.
        const build = spawn(
          "swift",
          [
            "build",
            ...lockedSwiftArguments("apps/macos"),
            "--configuration",
            "release",
            "--build-tests",
            "-Xswiftc",
            "-enable-testing",
          ],
          { cwd: root, env, stdio: "inherit" },
        );
        const buildCode = await new Promise<number | null>((done, reject) => {
          build.once("error", reject);
          build.once("exit", done);
        });
        if (buildCode !== 0) {
          throw new Error(`Native local acceptance build failed: ${buildCode}`);
        }
      },
      "release",
    );
  }
  const args = [
    "test",
    "--skip-build",
    // macOS cannot nest SwiftPM's manifest sandbox inside our offline process sandbox.
    // The outer offline.sb profile remains active for SwiftPM and the native client.
    "--disable-sandbox",
    ...lockedSwiftArguments("apps/macos"),
    "--configuration",
    "release",
    "--filter",
    "LocalServerAcceptanceTests",
  ];
  await timedAsync(
    "Native local transport acceptance",
    async () => {
      const child = spawn(
        "/usr/bin/sandbox-exec",
        ["-f", resolve(root, "scripts/offline.sb"), "swift", ...args],
        {
          cwd: root,
          env: {
            ...env,
            TRIGO_LOCAL_ACCEPTANCE_CONFIG: configurationPath,
            TRIGO_LOCAL_ACCEPTANCE_WORKTREE: id,
          },
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let output = "";
      child.stdout.on("data", (data: Buffer) => {
        process.stdout.write(data);
        output = (output + data.toString()).slice(-256 * 1024);
      });
      child.stderr.on("data", (data: Buffer) => {
        process.stderr.write(data);
        output = (output + data.toString()).slice(-256 * 1024);
      });
      const code = await new Promise<number | null>((done, reject) => {
        child.once("error", reject);
        child.once("close", done);
      });
      if (code !== 0) {
        throw new Error(`Native local transport acceptance failed: ${code}`);
      }
      assertNativeTestOutput(output);
    },
    "release",
  );
}
try {
  await ready();
  if (!testing) {
    console.log(
      `Local product API: ${base}\nPair in an isolated Dev namespace (set TRIGO_SIGNING_TEAM first; ad-hoc installs require explicit --ad-hoc):\nbun run macos:run --variant dev --local-config '${configurationPath.replaceAll("'", "'\\''")}'\nClick Connect in the app. The local token is prefilled and is never printed.`,
    );
    await new Promise((done) => server.child.once("exit", done));
    process.exitCode = server.child.exitCode ?? 0;
  } else {
    const initial = await status();
    for (const [path, headers, expected, code] of [
      ["/v1/status", {}, 401, "owner_unauthorized"],
      ["/v1/status", { authorization: "Bearer invalid" }, 401, "owner_unauthorized"],
    ] as const) {
      const response = await request(path, { headers });
      const error = validateDocument("ErrorEnvelope", await response.json());
      if (
        response.status !== expected ||
        error.error.code !== code ||
        error.error.retry !== "after_correction"
      ) {
        throw new Error(`Local contract mismatch: ${path}`);
      }
    }
    const catalogResponse = await request("/v1/calls", { headers: ownerHeaders });
    const catalog = validateDocument("CallCatalogPage", await catalogResponse.json());
    if (
      catalogResponse.status !== 200 ||
      catalog.archiveId !== configuration.namespaceId ||
      catalog.calls.length !== 0 ||
      catalog.nextCursor !== null
    ) {
      throw new Error("Initial local call catalog differs");
    }
    const created = await request("/__local/probe", { method: "POST", headers: probeHeaders });
    if (created.status !== 201) {
      throw new Error(`Local workflow creation failed: ${created.status} ${await created.text()}`);
    }
    let completed = false;
    for (let i = 0; i < 100; i++) {
      const response = await request("/__local/probe", { headers: probeHeaders });
      const state: unknown = await response.json();
      if (typeof state === "object" && state !== null && "status" in state) {
        if (state.status === "complete") {
          completed = true;
          break;
        }
        if (state.status === "errored") {
          throw new Error(`Offline workflow failed: ${JSON.stringify(state)}`);
        }
      }
      await new Promise((done) => setTimeout(done, 100));
    }
    if (!completed) {
      throw new Error("Local workflow did not complete");
    }
    const revisionBytes = await (
      await request("/__local/probe/revision", { headers: probeHeaders })
    ).text();
    const revision = validateDocument("TranscriptRevision", JSON.parse(revisionBytes));
    if (
      revision.asr.adapter !== "fake" ||
      revision.asr.model !== "no-speech" ||
      revision.turns.length !== 0 ||
      revision.speakers.length !== 0
    ) {
      throw new Error("Unexpected canonical fake ASR result");
    }
    if (nativeClient) {
      await nativeAcceptance();
    }
    await stop();
    server = start();
    await ready();
    if (JSON.stringify(await status()) !== JSON.stringify(initial)) {
      throw new Error("D1 identity changed after local restart");
    }
    const reopened = await (
      await request("/__local/probe/revision", { headers: probeHeaders })
    ).text();
    const workflow = await (await request("/__local/probe", { headers: probeHeaders })).json();
    if (
      reopened !== revisionBytes ||
      typeof workflow !== "object" ||
      workflow === null ||
      !("status" in workflow) ||
      workflow.status !== "complete"
    ) {
      throw new Error("R2/workflow state did not survive restart");
    }
    if (process.platform === "darwin") {
      const probe = spawnSync(
        "/usr/bin/sandbox-exec",
        [
          "-f",
          resolve(root, "scripts/offline.sb"),
          "/usr/bin/curl",
          "--max-time",
          "2",
          "--noproxy",
          "*",
          "http://1.1.1.1",
        ],
        { stdio: "ignore" },
      );
      if (probe.status === 0) {
        throw new Error("External network unexpectedly available");
      }
    }
    console.log(
      "Shared product status/auth + Alchemy local D1/R2/workflow + canonical fake ASR + persistent restart passed; external network denied on macOS.",
    );
  }
} finally {
  await stop();
  if (testing) {
    rmSync(directory, { recursive: true, force: true });
  }
}
