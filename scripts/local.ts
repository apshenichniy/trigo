import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { createServer } from "node:net";
const root = realpathSync(new URL("..", import.meta.url).pathname);
const testing = process.argv.includes("--test");
if (process.argv.slice(2).some((arg: string) => arg !== "--test"))
  throw new Error(
    "Local dev accepts only --test; cloud stages and resource configuration are unavailable (#12).",
  );
const id = createHash("sha256").update(root).digest("hex").slice(0, 12);
const requestedPort = Number(process.env.TRIGO_LOCAL_PORT ?? (testing ? 0 : 19371));
if (
  !Number.isInteger(requestedPort) ||
  (requestedPort !== 0 && requestedPort < 1024) ||
  requestedPort > 65535
)
  throw new Error("TRIGO_LOCAL_PORT must be an integer in 1024..65535");
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
const runId = randomUUID();
const directory = testing
  ? mkdtempSync(resolve(tmpdir(), "trigo-local-test-"))
  : resolve(root, ".local", id);
mkdirSync(directory, { recursive: true });
// Pass an allowlist; operator credentials, profiles, proxy variables and dotenv
// files cannot enter the local composition. The token is deliberately invalid.
const env: NodeJS.ProcessEnv = {
  PATH: process.env.PATH,
  TMPDIR: process.env.TMPDIR,
  LANG: "en_US.UTF-8",
  CI: "1",
  TRIGO_LOCAL: "1",
  TRIGO_LOCAL_PORT: String(port),
  TRIGO_LOCAL_RUN_ID: runId,
  ALCHEMY_TELEMETRY_DISABLED: "1",
  DO_NOT_TRACK: "1",
  CLOUDFLARE_ACCOUNT_ID: "00000000000000000000000000000000",
  CLOUDFLARE_API_TOKEN: "trigo-local-invalid-token",
};
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
// macOS also enforces the local-only boundary for every child including workerd.
if (process.platform === "darwin")
  command.unshift("/usr/bin/sandbox-exec", "-f", resolve(root, "scripts/offline.sb"));
const child = spawn(command[0]!, command.slice(1), {
  cwd: directory,
  env,
  stdio: testing ? ["ignore", "pipe", "pipe"] : "inherit",
  detached: true,
});
let output = "";
child.stdout?.on("data", (data) => {
  output += data;
});
child.stderr?.on("data", (data) => {
  output += data;
});
let stopped = false;
function stop() {
  if (stopped) return;
  stopped = true;
  try {
    process.kill(-child.pid!, "SIGTERM");
  } catch {}
}
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
if (testing) {
  try {
    const base = `http://127.0.0.1:${port}`;
    let ready = false;
    for (let i = 0; i < 120; i++) {
      if (
        child.exitCode !== null ||
        child.signalCode !== null ||
        /alchemy dev: (apply|run) failed/.test(output)
      )
        throw new Error(`Alchemy failed: ${output}`);
      try {
        const response = await fetch(`${base}/__local/health`, {
          signal: AbortSignal.timeout(1000),
        });
        const health: unknown = await response.json();
        ready =
          response.ok &&
          typeof health === "object" &&
          health !== null &&
          "runId" in health &&
          health.runId === runId;
      } catch {}
      if (ready) break;
      await new Promise((done) => setTimeout(done, 500));
    }
    if (!ready) throw new Error(`Alchemy did not become ready: ${output}`);
    const post = await fetch(`${base}/__local/transcriptions/no-speech`, {
      method: "POST",
      signal: AbortSignal.timeout(5000),
    });
    if (post.status !== 201) throw new Error(`Fake ASR failed: ${post.status}`);
    const result = await (
      await fetch(`${base}/__local/transcriptions/no-speech`, { signal: AbortSignal.timeout(5000) })
    ).json();
    if (
      JSON.stringify(result) !==
      JSON.stringify({ fixture: "no-speech", turns: [], provider: "fake" })
    )
      throw new Error("Local R2 readback differs");
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
      if (probe.status === 0) throw new Error("External network unexpectedly available");
    }
    console.log("Alchemy local Worker + R2 + fake ASR passed; external network denied on macOS.");
  } finally {
    stop();
    if (child.exitCode === null && child.signalCode === null)
      await new Promise((done) => child.once("exit", done));
    rmSync(directory, { recursive: true, force: true });
  }
} else {
  child.on("exit", (code) => {
    process.exitCode = code ?? 1;
  });
}
