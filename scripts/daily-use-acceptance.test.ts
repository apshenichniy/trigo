import { expect, it } from "vitest";

import { parseDailyUseOptions } from "./daily-use-acceptance.ts";

const hosted = [
  "--stage",
  "dev",
  "--profile",
  "one-hour",
  "--directory",
  ".local/daily-use-acceptance-one-hour",
  "--config",
  "/private/dev.json",
];
const plan = "a".repeat(64);

it("keeps preparation separate from explicit paid admission to one immutable plan", () => {
  expect(parseDailyUseOptions(["prepare", ...hosted], "/repo").allowPaid).toBe(false);
  expect(() => parseDailyUseOptions(["prepare", ...hosted, "--allow-paid"], "/repo")).toThrow(
    "cannot admit",
  );
  expect(() => parseDailyUseOptions(["run", ...hosted], "/repo")).toThrow("exact");
  expect(() => parseDailyUseOptions(["run", ...hosted, "--plan-sha256", plan], "/repo")).toThrow(
    "--allow-paid",
  );
  expect(
    parseDailyUseOptions(["run", ...hosted, "--plan-sha256", plan, "--allow-paid"], "/repo")
      .planSHA256,
  ).toBe(plan);
});

it("rejects implicit or Personal targets, foreign directories and mixed local/cloud configuration", () => {
  for (const flags of [
    hosted.map((v) => (v === "dev" ? "personal" : v)),
    hosted.map((v) => (v === ".local/daily-use-acceptance-one-hour" ? "/private/archive" : v)),
    hosted.map((v) => (v === "one-hour" ? "local-smoke" : v)),
    [...hosted, "--local-config", "/private/local.json"],
    [...hosted, "--unexpected"],
  ]) {
    expect(() => parseDailyUseOptions(["prepare", ...flags], "/repo")).toThrow();
  }
});

it("runs the local one-minute rehearsal without granting hosted permission", () => {
  const local = hosted.map((v) =>
    v === "one-hour" ? "local-smoke" : v === "--config" ? "--local-config" : v,
  );
  expect(parseDailyUseOptions(["run", ...local, "--plan-sha256", plan], "/repo").local).toBe(true);
  expect(() =>
    parseDailyUseOptions(["run", ...local, "--plan-sha256", plan, "--allow-paid"], "/repo"),
  ).toThrow();
});
