import { expect, it } from "vitest";

import { parseServiceProbeOptions } from "./transcription-service-probe.ts";

const options = [
  "--stage",
  "dev",
  "--directory",
  "/tmp/trigo-prepared-fixture",
  "--config",
  "config/cloud/dev.json",
  "--language",
  "en",
];

it("prepares without a paid flag and requires one for execution", () => {
  expect(parseServiceProbeOptions(["prepare", ...options]).action).toBe("prepare");
  expect(() => parseServiceProbeOptions(["run", ...options])).toThrow("--allow-paid");
  expect(parseServiceProbeOptions(["run", ...options, "--allow-paid"]).action).toBe("run");
});

it("rejects personal, unknown options, unsupported languages and duplicate selectors before credential or network access", () => {
  expect(() =>
    parseServiceProbeOptions([
      "run",
      ...options.map((value) => (value === "dev" ? "personal" : value)),
      "--allow-paid",
    ]),
  ).toThrow("--stage dev");
  expect(() => parseServiceProbeOptions(["prepare", ...options, "--model", "other"])).toThrow(
    "Unexpected",
  );
  expect(() =>
    parseServiceProbeOptions([
      "prepare",
      ...options.map((value) => (value === "en" ? "uk" : value)),
    ]),
  ).toThrow("en or ru");
  expect(() => parseServiceProbeOptions(["prepare", ...options, "--stage", "dev"])).toThrow(
    "at most once",
  );
});
