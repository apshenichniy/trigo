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
