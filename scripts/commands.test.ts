import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { expect, it } from "vitest";
it.each([
  "doctor",
  "format",
  "format:check",
  "lint",
  "typecheck",
  "test",
  "build",
  "check",
  "check:server",
  "check:macos",
  "check:quick",
  "test:native",
  "check:files",
  "check:macos:smoke",
])("%s rejects ignored target arguments before executing its operations", (command) => {
  const result = spawnSync("bun", ["run", command, "--stage", "dev"], { encoding: "utf8" });
  expect(result.status).toBe(1);
  expect(result.stderr).toContain(`Unexpected ${command} argument: --stage`);
  expect(result.stdout).not.toContain("Target: local");
  expect(result.stdout).not.toContain("[timing]");
});

it.each([
  ["check:quick", ["--scope", "cloud"], "--scope must be"],
  ["check:quick", ["--scope"], "Pass a value after --scope"],
  ["test:native", ["--suite", "quick"], "--suite must be"],
  ["test:native", ["--suite", "fast", "--suite", "all"], "Pass --suite at most once"],
  ["test:native", ["--filter", "["], "Invalid regular expression"],
  ["macos:build", ["--variant", "dev", "--variant", "personal"], "Pass --variant at most once"],
  ["macos:build", ["--variant"], "Pass a value after --variant"],
  ["macos:build", ["--local-config", "--ad-hoc"], "Pass a value after --local-config"],
  ["macos:build", ["--replace-worktree"], "Unexpected native build argument"],
  ["macos:install", ["--ad-hoc", "--ad-hoc"], "Pass --ad-hoc at most once"],
  ["macos:setup", ["--ad-hoc"], "Unexpected native setup argument"],
  ["macos:archive", ["--local-config", "/tmp/unused"], "Unexpected native archive argument"],
  ["macos:run", ["--bogus"], "Unexpected native run argument"],
  ["contracts:generate", ["--chek"], "Unexpected contract generation argument"],
  ["contracts:check", ["--check"], "Pass --check at most once"],
  ["test:local", ["--test"], "Pass --test at most once"],
  ["test:asr", ["--stage", "dev", "--language"], "Pass a value after --language"],
  [
    "test:asr",
    ["--stage", "dev", "--language", "en", "--language", "ru"],
    "Pass --language at most once",
  ],
  ["test:asr", ["--stage", "dev", "--bogus"], "Unexpected asr probe argument"],
  ["test:asr", ["--stage", "dev"], "Pass --handoff <private dev owner handoff>"],
] as const)(
  "%s rejects malformed options before build, write or credential access: %j",
  (command, args, message) => {
    const result = spawnSync("bun", ["run", command, ...args], { encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(message);
    expect(result.stdout).not.toContain("[timing]");
    expect(result.stderr).not.toContain("Cannot read the dev cloud configuration");
  },
);

it.each(["cloud:preflight", "cloud:bootstrap", "cloud:deploy", "test:cloud"])(
  "%s runs the explicit cloud preflight instead of an ownership placeholder",
  (command) => {
    const missing = resolve(tmpdir(), `trigo-cloud-${randomUUID()}.json`);
    const result = spawnSync("bun", ["run", command, "--stage", "dev", "--config", missing], {
      encoding: "utf8",
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(`Cloud configuration not found: ${missing}`);
    expect(result.stderr).not.toContain("#12");
  },
);
it.each(["preflight", "bootstrap", "deploy"])(
  "cloud:%s rejects forwarded arguments before local profile validation",
  (action) => {
    const missing = resolve(tmpdir(), `trigo-cloud-${randomUUID()}.json`);
    const result = spawnSync(
      "bun",
      ["run", `cloud:${action}`, "--stage", "dev", "--config", missing, "--bogus"],
      { encoding: "utf8" },
    );

    expect(result.status).toBe(1);
    expect(result.stderr).toContain(`Unexpected ${action} argument: --bogus`);
    expect(result.stdout).not.toContain("Cloud preflight passed");
  },
);
it("test:asr refuses the personal stage before generating a fixture", () => {
  const result = spawnSync("bun", ["run", "test:asr", "--stage", "personal"], {
    encoding: "utf8",
  });
  expect(result.status).toBe(1);
  expect(result.stderr).toContain("Nova-3 probes may target only --stage dev");
});
it("doctor remains a read-only local diagnostic after cloud commands are available", () => {
  const result = spawnSync("bun", ["run", "doctor"], { encoding: "utf8" });
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("Target: local; fake ASR");
  expect(result.stdout).toContain("Cloud commands require an explicit stage and stage config");
  expect(result.stdout).not.toContain("Cloudflare State Store");
});
it("local dev refuses cloud stage arguments", () => {
  const result = spawnSync("bun", ["run", "dev", "--stage", "personal"], { encoding: "utf8" });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("cloud stages");
});
it("local smoke refuses an occupied port before starting Alchemy", async () => {
  const { createServer } = await import("node:net");
  const server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  try {
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("No test port");
    const result = spawnSync("bun", ["run", "test:local"], {
      encoding: "utf8",
      env: { ...process.env, TRIGO_LOCAL_PORT: String(address.port) },
      timeout: 5000,
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("Local port unavailable");
  } finally {
    server.close();
  }
});
