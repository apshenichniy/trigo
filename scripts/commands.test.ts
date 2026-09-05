import { spawnSync } from "node:child_process";
import { expect, it } from "vitest";
it.each(["cloud:bootstrap", "cloud:deploy", "test:cloud", "test:asr"])(
  "%s is a nonzero ownership placeholder",
  (command) => {
    const result = spawnSync("bun", ["run", command, "--stage", "dev"], { encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(command === "test:asr" ? "#13" : "#12");
  },
);
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
