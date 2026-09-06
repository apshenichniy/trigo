import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  cloudConfigPath,
  cloudDeploymentIdentity,
  cloudInvocationFor,
  cloudTargetFor,
  executeCloudInvocation,
  parseCloudStage,
  preflightCloudConfiguration,
  readCloudConfiguration,
  validateAlchemyProfileAccount,
} from "./cloud.ts";

describe("cloud target mapping", () => {
  it("keeps dev and personal identities stable and isolated", () => {
    expect(cloudTargetFor("dev")).toEqual({
      stage: "dev",
      stack: "trigo-cloud",
      profile: "trigo-cloud-dev",
      configPath: "config/cloud/dev.json",
      resources: {
        archiveBucket: "trigo-dev-archive",
        catalogDatabase: "trigo-dev-catalog",
        apiWorker: "trigo-dev-api",
        workflow: "trigo-dev-archive-workflow",
      },
    });
    expect(cloudTargetFor("personal")).toEqual({
      stage: "personal",
      stack: "trigo-cloud",
      profile: "trigo-cloud-personal",
      configPath: "config/cloud/personal.json",
      resources: {
        archiveBucket: "trigo-personal-archive",
        catalogDatabase: "trigo-personal-catalog",
        apiWorker: "trigo-personal-api",
        workflow: "trigo-personal-archive-workflow",
      },
    });
    expect(cloudTargetFor("dev").resources).not.toEqual(cloudTargetFor("personal").resources);
  });

  it("derives a stable non-secret identity from the account and Worker target", () => {
    expect(cloudDeploymentIdentity(cloudTargetFor("dev"), "0123456789abcdef0123456789abcdef")).toBe(
      "trigo-dev-api:9236f745b86ef20f",
    );
    expect(
      cloudDeploymentIdentity(cloudTargetFor("dev"), "fedcba9876543210fedcba9876543210"),
    ).not.toBe("trigo-dev-api:9236f745b86ef20f");
  });
});

describe("cloud command preflight", () => {
  it("rejects a missing profile through the project preflight despite Alchemy's zero exit", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-cloud-preflight-"));
    const alchemyRoot = resolve(directory, ".alchemy");
    try {
      const config = resolve(directory, "dev.json");
      mkdirSync(alchemyRoot);
      writeFileSync(
        config,
        JSON.stringify({
          stage: "dev",
          accountId: "0123456789abcdef0123456789abcdef",
          profile: "trigo-cloud-dev",
        }),
      );

      expect(() => preflightCloudConfiguration(config, cloudTargetFor("dev"), alchemyRoot)).toThrow(
        "Alchemy profile trigo-cloud-dev is not configured for Cloudflare; run alchemy login --configure --profile trigo-cloud-dev and confirm the intended account",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("documents the project preflight instead of trusting Alchemy profile-show status", () => {
    const runbook = readFileSync(new URL("../docs/development/cloud.md", import.meta.url), "utf8");
    const setup = readFileSync(new URL("../docs/development/setup.md", import.meta.url), "utf8");

    expect(runbook).toContain("mise exec -- bun run cloud:preflight --stage dev");
    expect(runbook).not.toContain("alchemy.js profile show");
    expect(setup).toContain("`cloud:preflight --stage dev`");
  });

  it("requires an explicit stage before invoking cloud tooling", () => {
    const result = spawnSync("bun", ["scripts/cloud.ts", "deploy"], {
      cwd: new URL("..", import.meta.url),
      encoding: "utf8",
    });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Pass an explicit --stage dev or --stage personal");
    expect(result.stderr).not.toContain("Cloudflare State Store");
  });

  it("rejects duplicate stage and configuration selectors", () => {
    expect(() => parseCloudStage(["--stage", "dev", "--stage", "personal"])).toThrow(
      "Pass exactly one --stage selector",
    );
    expect(() =>
      cloudConfigPath(
        ["--stage", "dev", "--config", "first.json", "--config", "second.json"],
        cloudTargetFor("dev"),
      ),
    ).toThrow("Pass at most one --config selector");
  });

  it("rejects missing stage configuration before invoking cloud tooling", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-cloud-preflight-"));
    try {
      const config = resolve(directory, "missing.json");
      const result = spawnSync(
        "bun",
        ["scripts/cloud.ts", "deploy", "--stage", "dev", "--config", config],
        { cwd: new URL("..", import.meta.url), encoding: "utf8" },
      );

      expect(result.status).toBe(1);
      expect(result.stderr).toContain(`Cloud configuration not found: ${config}`);
      expect(result.stderr).not.toContain("Cloudflare State Store");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects configuration for a different target before invoking cloud tooling", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-cloud-preflight-"));
    try {
      const config = resolve(directory, "dev.json");
      writeFileSync(
        config,
        JSON.stringify({
          stage: "dev",
          accountId: "0123456789abcdef0123456789abcdef",
          profile: "trigo-cloud-personal",
        }),
      );

      expect(() => readCloudConfiguration(config, cloudTargetFor("dev"))).toThrow(
        "Cloud profile mismatch: expected trigo-cloud-dev",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("requires the dedicated Alchemy profile even when credentials come from the environment", () => {
    const alchemyRoot = mkdtempSync(resolve(tmpdir(), "trigo-cloud-profile-"));
    try {
      const expected =
        "Alchemy profile trigo-cloud-dev is not configured for Cloudflare; run alchemy login --configure --profile trigo-cloud-dev and confirm the intended account";
      expect(() =>
        validateAlchemyProfileAccount(
          {
            stage: "dev",
            accountId: "0123456789abcdef0123456789abcdef",
            profile: "trigo-cloud-dev",
          },
          alchemyRoot,
        ),
      ).toThrow(expected);

      writeFileSync(
        resolve(alchemyRoot, "profiles.json"),
        JSON.stringify({ version: 0, profiles: { "trigo-cloud-dev": {} } }),
      );
      expect(() =>
        validateAlchemyProfileAccount(
          {
            stage: "dev",
            accountId: "0123456789abcdef0123456789abcdef",
            profile: "trigo-cloud-dev",
          },
          alchemyRoot,
        ),
      ).toThrow(expected);
    } finally {
      rmSync(alchemyRoot, { recursive: true, force: true });
    }
  });

  it("rejects an OAuth profile bound to another account before remote state", () => {
    const alchemyRoot = mkdtempSync(resolve(tmpdir(), "trigo-cloud-profile-"));
    try {
      writeFileSync(
        resolve(alchemyRoot, "profiles.json"),
        JSON.stringify({
          version: 0,
          profiles: {
            "trigo-cloud-dev": {
              Cloudflare: {
                method: "oauth",
                scopes: [],
                accountId: "fedcba9876543210fedcba9876543210",
              },
            },
          },
        }),
      );

      expect(() =>
        validateAlchemyProfileAccount(
          {
            stage: "dev",
            accountId: "0123456789abcdef0123456789abcdef",
            profile: "trigo-cloud-dev",
          },
          alchemyRoot,
        ),
      ).toThrow(
        "Alchemy profile trigo-cloud-dev belongs to a different Cloudflare account; rerun alchemy login --configure --profile trigo-cloud-dev and confirm the intended account",
      );
    } finally {
      rmSync(alchemyRoot, { recursive: true, force: true });
    }
  });

  it("rejects a stored profile bound to another account before remote state", () => {
    const alchemyRoot = mkdtempSync(resolve(tmpdir(), "trigo-cloud-profile-"));
    try {
      writeFileSync(
        resolve(alchemyRoot, "profiles.json"),
        JSON.stringify({
          version: 0,
          profiles: { "trigo-cloud-dev": { Cloudflare: { method: "stored" } } },
        }),
      );
      const credentials = resolve(alchemyRoot, "credentials", "trigo-cloud-dev");
      mkdirSync(credentials, { recursive: true });
      writeFileSync(
        resolve(credentials, "cf-stored.json"),
        JSON.stringify({
          type: "apiToken",
          apiToken: "never-read-by-validation",
          accountId: "fedcba9876543210fedcba9876543210",
        }),
      );

      expect(() =>
        validateAlchemyProfileAccount(
          {
            stage: "dev",
            accountId: "0123456789abcdef0123456789abcdef",
            profile: "trigo-cloud-dev",
          },
          alchemyRoot,
        ),
      ).toThrow(
        "Alchemy profile trigo-cloud-dev belongs to a different Cloudflare account; rerun alchemy login --configure --profile trigo-cloud-dev and confirm the intended account",
      );
    } finally {
      rmSync(alchemyRoot, { recursive: true, force: true });
    }
  });

  it("validates the account stored with non-OAuth profile credentials", () => {
    const alchemyRoot = mkdtempSync(resolve(tmpdir(), "trigo-cloud-profile-"));
    try {
      writeFileSync(
        resolve(alchemyRoot, "profiles.json"),
        JSON.stringify({
          version: 0,
          profiles: { "trigo-cloud-dev": { Cloudflare: { method: "stored" } } },
        }),
      );
      const credentials = resolve(alchemyRoot, "credentials", "trigo-cloud-dev");
      mkdirSync(credentials, { recursive: true });
      writeFileSync(
        resolve(credentials, "cf-stored.json"),
        JSON.stringify({
          type: "apiToken",
          apiToken: "never-read-by-validation",
          accountId: "0123456789abcdef0123456789abcdef",
        }),
      );

      expect(() =>
        validateAlchemyProfileAccount(
          {
            stage: "dev",
            accountId: "0123456789abcdef0123456789abcdef",
            profile: "trigo-cloud-dev",
          },
          alchemyRoot,
        ),
      ).not.toThrow();
    } finally {
      rmSync(alchemyRoot, { recursive: true, force: true });
    }
  });

  it("rejects a non-HTTPS cloud API URL", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-cloud-preflight-"));
    try {
      const config = resolve(directory, "dev.json");
      writeFileSync(
        config,
        JSON.stringify({
          stage: "dev",
          accountId: "0123456789abcdef0123456789abcdef",
          profile: "trigo-cloud-dev",
          apiUrl: "http://trigo-dev-api.example.test",
        }),
      );

      expect(() => readCloudConfiguration(config, cloudTargetFor("dev"))).toThrow(
        "Cloud apiUrl must be an HTTPS origin without credentials, path, query, or fragment",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("constructs the pinned deploy invocation only after successful preflight", () => {
    const target = cloudTargetFor("dev");
    expect(
      cloudInvocationFor("deploy", target, {
        stage: "dev",
        accountId: "0123456789abcdef0123456789abcdef",
        profile: "trigo-cloud-dev",
      }),
    ).toEqual({
      program: "alchemy",
      args: ["deploy", "--stage", "dev", "--profile", "trigo-cloud-dev", "--yes", "infra/cloud.ts"],
      env: {
        ALCHEMY_PROFILE: "trigo-cloud-dev",
        CLOUDFLARE_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
        TRIGO_CLOUD_STAGE: "dev",
      },
    });
  });

  it("rejects unsupported bootstrap and deploy arguments", () => {
    const target = cloudTargetFor("dev");
    const configuration = {
      stage: "dev",
      accountId: "0123456789abcdef0123456789abcdef",
      profile: "trigo-cloud-dev",
    } as const;

    expect(() => cloudInvocationFor("bootstrap", target, configuration, ["--force"])).toThrow(
      "Unexpected bootstrap argument: --force",
    );
    expect(() => cloudInvocationFor("deploy", target, configuration, ["--destroy"])).toThrow(
      "Unexpected deploy argument: --destroy",
    );
  });

  it("rejects cloud fixture checks against the personal target", () => {
    const target = cloudTargetFor("personal");
    expect(() =>
      cloudInvocationFor("test", target, {
        stage: "personal",
        accountId: "fedcba9876543210fedcba9876543210",
        profile: "trigo-cloud-personal",
        personalDeploymentGate: "blocked-by-32",
      }),
    ).toThrow("test:cloud fixtures are destructive and may target only --stage dev");
  });

  it("requires the deployed HTTPS origin for cloud verification", () => {
    expect(() =>
      cloudInvocationFor("test", cloudTargetFor("dev"), {
        stage: "dev",
        accountId: "0123456789abcdef0123456789abcdef",
        profile: "trigo-cloud-dev",
      }),
    ).toThrow("test:cloud requires apiUrl in config/cloud/dev.json");
  });

  it("reports the exact missing verifier credential before a remote request", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-cloud-preflight-"));
    try {
      const config = resolve(directory, "dev.json");
      writeFileSync(
        config,
        JSON.stringify({
          stage: "dev",
          accountId: "0123456789abcdef0123456789abcdef",
          profile: "trigo-cloud-dev",
          apiUrl: "https://trigo-dev.example.test",
        }),
      );
      const result = spawnSync(
        "bun",
        ["scripts/cloud.ts", "test", "--stage", "dev", "--config", config],
        {
          cwd: new URL("..", import.meta.url),
          encoding: "utf8",
          env: { ...process.env, CLOUDFLARE_API_TOKEN: undefined },
        },
      );

      expect(result.status).toBe(1);
      expect(result.stderr).toContain("Missing CLOUDFLARE_API_TOKEN for test:cloud");
      expect(result.stderr).not.toContain("Cloud infrastructure request failed");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("forwards an explicit persistence fixture check to the cloud verifier", () => {
    const fixtureId = "00000000-0000-4000-8000-000000000029";
    expect(
      cloudInvocationFor(
        "test",
        cloudTargetFor("dev"),
        {
          stage: "dev",
          accountId: "0123456789abcdef0123456789abcdef",
          profile: "trigo-cloud-dev",
          apiUrl: "https://trigo-dev.example.test",
        },
        ["--verify", fixtureId],
      ),
    ).toMatchObject({
      program: "cloud-verifier",
      args: ["--stage", "dev", "--verify", fixtureId],
      env: { TRIGO_CLOUD_API_URL: "https://trigo-dev.example.test" },
    });
  });

  it("keeps the first personal deployment behind the #32 recovery gate", () => {
    const target = cloudTargetFor("personal");
    const blocked = {
      stage: "personal",
      accountId: "fedcba9876543210fedcba9876543210",
      profile: "trigo-cloud-personal",
      personalDeploymentGate: "blocked-by-32",
    } as const;

    expect(() => cloudInvocationFor("deploy", target, blocked)).toThrow(
      "Personal deployment is blocked until #32 is accepted",
    );
    expect(
      cloudInvocationFor("deploy", target, {
        ...blocked,
        personalDeploymentGate: "approved-after-32",
      }).args,
    ).toContain("personal");
  });

  it("executes the planned child command and propagates its failure", () => {
    const invocation = cloudInvocationFor("bootstrap", cloudTargetFor("dev"), {
      stage: "dev",
      accountId: "0123456789abcdef0123456789abcdef",
      profile: "trigo-cloud-dev",
    });
    const observed: Array<{ program: string; args: readonly string[] }> = [];

    const status = executeCloudInvocation(
      invocation,
      {
        root: "/workspace/trigo",
        bun: "/pinned/bun",
        baseEnv: { PATH: "/bin" },
      },
      (program, args) => {
        observed.push({ program, args });
        return { status: 23 };
      },
    );

    expect(status).toBe(23);
    expect(observed).toEqual([
      {
        program: "/pinned/bun",
        args: [
          "--bun",
          "/workspace/trigo/infra/node_modules/alchemy/bin/alchemy.js",
          "cloudflare",
          "bootstrap",
          "--profile",
          "trigo-cloud-dev",
        ],
      },
    ]);
  });
});
