import { expect, it } from "@effect/vitest";
import { Effect } from "effect";
import { cloudTargetFor } from "./cloud.ts";
import {
  inspectCloudInfrastructure,
  makeWranglerBoundary,
  parseCloudVerification,
  seedCloudFixture,
  verifyCloudFixture,
} from "./cloud-verify.ts";

it("parses explicit inspect, seed, and verify modes", () => {
  expect(parseCloudVerification(["--stage", "dev"])).toEqual({
    stage: "dev",
    mode: "inspect",
  });
  expect(
    parseCloudVerification(["--stage", "dev", "--seed", "00000000-0000-4000-8000-000000000029"]),
  ).toEqual({
    stage: "dev",
    mode: "seed",
    fixtureId: "00000000-0000-4000-8000-000000000029",
  });
  expect(
    parseCloudVerification(["--stage", "dev", "--verify", "00000000-0000-4000-8000-000000000029"]),
  ).toEqual({
    stage: "dev",
    mode: "verify",
    fixtureId: "00000000-0000-4000-8000-000000000029",
  });
});

it.effect("inspects the deployed dev infrastructure without invoking AI or fixtures", () =>
  Effect.gen(function* () {
    const target = cloudTargetFor("dev");
    const result = yield* inspectCloudInfrastructure(
      target,
      "0123456789abcdef0123456789abcdef",
      "https://trigo-dev.example.test",
      {
        workerDeployment: Effect.succeed('{"id":"deployment-1"}'),
        r2Exposure: Effect.succeed({ publicAccess: false, customDomainCount: 0 }),
        infrastructure: Effect.succeed({
          status: 200,
          body: {
            stage: "dev",
            identity: "trigo-dev-api:9236f745b86ef20f",
            bindings: {
              archive: "configured",
              catalog: "configured",
              workflow: "configured",
              workersAi: "configured-not-verified",
            },
          },
        }),
      },
    );

    expect(result).toEqual({
      stage: "dev",
      identity: "trigo-dev-api:9236f745b86ef20f",
      worker: "trigo-dev-api",
      archiveBucket: "trigo-dev-archive",
      r2PublicAccess: "disabled",
      r2CustomDomains: 0,
      bindings: {
        archive: "configured",
        catalog: "configured",
        workflow: "configured",
        workersAi: "configured-not-verified",
      },
    });
  }),
);

it.effect("rejects malformed deployment status output", () =>
  Effect.gen(function* () {
    const error = yield* inspectCloudInfrastructure(
      cloudTargetFor("dev"),
      "0123456789abcdef0123456789abcdef",
      "https://trigo-dev.example.test",
      {
        workerDeployment: Effect.succeed('"unexpected"'),
        r2Exposure: Effect.succeed({ publicAccess: false, customDomainCount: 0 }),
        infrastructure: Effect.succeed({
          status: 200,
          body: {
            stage: "dev",
            identity: "trigo-dev-api:9236f745b86ef20f",
            bindings: {
              archive: "configured",
              catalog: "configured",
              workflow: "configured",
              workersAi: "configured-not-verified",
            },
          },
        }),
      },
    ).pipe(Effect.flip);

    expect(error.message).toContain("Cloud Worker deployment status is malformed: trigo-dev-api");
  }),
);

it.effect("rejects a diagnostic URL from another account or Worker", () =>
  Effect.gen(function* () {
    const error = yield* inspectCloudInfrastructure(
      cloudTargetFor("dev"),
      "0123456789abcdef0123456789abcdef",
      "https://stale-dev.example.test",
      {
        workerDeployment: Effect.succeed('{"id":"deployment-1"}'),
        r2Exposure: Effect.succeed({ publicAccess: false, customDomainCount: 0 }),
        infrastructure: Effect.succeed({
          status: 200,
          body: {
            stage: "dev",
            identity: "trigo-dev-api:different-account",
            bindings: {
              archive: "configured",
              catalog: "configured",
              workflow: "configured",
              workersAi: "configured-not-verified",
            },
          },
        }),
      },
    ).pipe(Effect.flip);

    expect(error.message).toContain("unexpected target identity");
  }),
);

it.effect("adapts pinned Wrangler R2 messages into typed exposure state", () =>
  Effect.gen(function* () {
    const boundary = makeWranglerBoundary(
      cloudTargetFor("dev"),
      (args) =>
        Effect.succeed(
          args.includes("dev-url")
            ? "Public access via the r2.dev URL is disabled."
            : "There are no custom domains connected to this bucket.",
        ),
      Effect.succeed({ status: 200, body: {} }),
    );

    expect(yield* boundary.r2Exposure).toEqual({
      publicAccess: false,
      customDomainCount: 0,
    });
  }),
);

it.effect("seeds and verifies the same private R2 and D1 fixture across deployments", () =>
  Effect.gen(function* () {
    const target = cloudTargetFor("dev");
    const fixtureId = "00000000-0000-4000-8000-000000000029";
    let object = "";
    let catalogFixture = "";
    const boundary = {
      putObject: (_bucket: string, _key: string, content: string) =>
        Effect.sync(() => {
          object = content;
        }),
      getObject: () => Effect.sync(() => object),
      writeCatalog: (_database: string, id: string) =>
        Effect.sync(() => {
          catalogFixture = id;
        }),
      readCatalog: () =>
        Effect.sync(() => `[{"results":[{"fixture_id":"${catalogFixture}"}],"success":true}]`),
    };

    yield* seedCloudFixture(target, fixtureId, boundary);
    expect(yield* verifyCloudFixture(target, fixtureId, boundary)).toEqual({
      fixtureId,
      objectKey: `acceptance/issue-29/${fixtureId}.json`,
      archiveBucket: "trigo-dev-archive",
      catalogDatabase: "trigo-dev-catalog",
    });
  }),
);

it.effect("writes acceptance objects through the remote Wrangler boundary", () =>
  Effect.gen(function* () {
    const calls: Array<{ args: readonly string[]; input: string | undefined }> = [];
    const boundary = makeWranglerBoundary(
      cloudTargetFor("dev"),
      (args, input) =>
        Effect.sync(() => {
          calls.push({ args, input });
          return "";
        }),
      Effect.succeed({ status: 200, body: {} }),
    );

    yield* boundary.putObject("trigo-dev-archive", "acceptance/fixture.json", "fixture\n");

    expect(calls).toEqual([
      {
        args: [
          "r2",
          "object",
          "put",
          "trigo-dev-archive/acceptance/fixture.json",
          "--remote",
          "--pipe",
          "--content-type",
          "application/json",
          "--force",
        ],
        input: "fixture\n",
      },
    ]);
  }),
);
