import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { expect, it } from "vitest";
it.each(["cloud:bootstrap", "cloud:deploy", "test:cloud"])(
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
it("test:asr remains the #13 ownership placeholder", () => {
  const result = spawnSync("bun", ["run", "test:asr", "--stage", "dev"], {
    encoding: "utf8",
  });
  expect(result.status).toBe(1);
  expect(result.stderr).toContain("#13");
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
