import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  APPROVED_DISPOSABLE_ACCOUNT_ID,
  APPROVED_DISPOSABLE_STATE_STORE_ORIGIN,
  EXPECTED_STATE_STORE_LOGICAL_IDS,
  PROTECTED_DEV_ACCOUNT_ID,
  armBootstrapInterruption,
  assertInterruptedBootstrap,
  assertRecoveredBootstrap,
  disarmBootstrapInterruption,
  preflightBootstrapInterruption,
  readBootstrapInterruptionConfiguration,
} from "./cloud-bootstrap-interruption.ts";

const disposableAccountId = APPROVED_DISPOSABLE_ACCOUNT_ID;
const profile = "trigo-cloud-issue-29-interrupt-a1b2c3";
const stateStoreOrigin = APPROVED_DISPOSABLE_STATE_STORE_ORIGIN;
const pendingStateStoreOrigin = "pending-workers-dev-initialization";

function writeConfiguration(directory: string, overrides: Record<string, unknown> = {}): string {
  const path = resolve(directory, "issue-29-interrupt.json");
  writeFileSync(
    path,
    JSON.stringify({
      purpose: "issue-29-interrupted-bootstrap",
      accountId: disposableAccountId,
      profile,
      stateStoreOrigin,
      protectedAccountIds: [PROTECTED_DEV_ACCOUNT_ID],
      ...overrides,
    }),
  );
  return path;
}

function writeEnvironmentProfile(alchemyRoot: string): void {
  mkdirSync(alchemyRoot, { recursive: true, mode: 0o700 });
  writeFileSync(
    resolve(alchemyRoot, "profiles.json"),
    JSON.stringify({
      version: 0,
      profiles: {
        [profile]: { Cloudflare: { method: "env" } },
        "trigo-cloud-dev": { Cloudflare: { method: "env" } },
      },
    }),
  );
}

function environment(): NodeJS.ProcessEnv {
  return {
    CLOUDFLARE_ACCOUNT_ID: disposableAccountId,
    CLOUDFLARE_API_TOKEN: "present-but-never-read-by-the-probe",
    ALCHEMY_PROFILE: profile,
  };
}

function writeSettledLocalStack(workspaceRoot: string): void {
  const stage = resolve(
    workspaceRoot,
    ".alchemy/state/CloudflareStateStore",
    `${profile}_alchemy-state-store`,
  );
  mkdirSync(stage, { recursive: true, mode: 0o700 });
  for (const logicalId of EXPECTED_STATE_STORE_LOGICAL_IDS) {
    writeFileSync(
      resolve(stage, `${logicalId}.json`),
      JSON.stringify({
        kind: "resource",
        fqn: logicalId,
        logicalId,
        resourceType: "fixture",
        status: "created",
      }),
      { mode: 0o600 },
    );
  }
  writeFileSync(
    resolve(stage, "__stack_output__.json"),
    JSON.stringify({ url: stateStoreOrigin, authToken: "not-read" }),
    { mode: 0o600 },
  );
}

function probeEnvironment(alchemyRoot: string, workspaceRoot: string, env = environment()) {
  return { alchemyRoot, workspaceRoot, env, umask: 0o077 } as const;
}

describe("issue #29 interrupted bootstrap probe", () => {
  it("documents the deterministic seam without exposing remote mutation through the project wrapper", () => {
    const runbook = readFileSync(new URL("../docs/development/cloud.md", import.meta.url), "utf8");
    const wrapper = readFileSync(new URL("./cloud.ts", import.meta.url), "utf8");

    expect(runbook).toContain("## Disposable interrupted-bootstrap rehearsal");
    expect(runbook).toMatch(/completed local stack output\s+checkpoint/);
    expect(runbook).toContain("Resuming Cloudflare State Store");
    expect(runbook).toContain("pending-workers-dev-initialization");
    expect(runbook).toContain("/workers/subdomain");
    expect(runbook).toContain(PROTECTED_DEV_ACCOUNT_ID);
    expect(runbook).toContain('git clone --no-local "$TRIGO_SOURCE_REPOSITORY"');
    expect(runbook).toContain('cd "$TRIGO_RECOVERY_ROOT/trigo"');
    expect(wrapper).not.toContain('cloudflare", "teardown');
    expect(wrapper).not.toContain("--worker-name");
  });

  it("rejects any account that is not isolated from the protected dev account", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    try {
      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, { accountId: PROTECTED_DEV_ACCOUNT_ID }),
        ),
      ).toThrow("accountId must be the approved Trigo Recovery Disposable account");

      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, { accountId: "0123456789abcdef0123456789abcdef" }),
        ),
      ).toThrow(`accountId must be the approved Trigo Recovery Disposable account`);

      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, { protectedAccountIds: [] }),
        ),
      ).toThrow(`protectedAccountIds must include working dev account ${PROTECTED_DEV_ACCOUNT_ID}`);

      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, {
            profile: "trigo-cloud-issue-29-interrupt-replace-me",
          }),
        ),
      ).toThrow("Replace the example profile suffix with a unique one-use value");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("requires a unique env profile, matching account environment, token, and clean local seam", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);

      expect(
        preflightBootstrapInterruption(config, probeEnvironment(alchemyRoot, workspaceRoot)),
      ).toMatchObject({ accountId: disposableAccountId, profile });

      expect(() =>
        preflightBootstrapInterruption(
          config,
          probeEnvironment(alchemyRoot, workspaceRoot, {
            ...environment(),
            CLOUDFLARE_ACCOUNT_ID: PROTECTED_DEV_ACCOUNT_ID,
          }),
        ),
      ).toThrow("CLOUDFLARE_ACCOUNT_ID does not match the disposable configuration");

      expect(() =>
        preflightBootstrapInterruption(
          config,
          probeEnvironment(alchemyRoot, workspaceRoot, {
            ...environment(),
            CLOUDFLARE_API_TOKEN: undefined,
          }),
        ),
      ).toThrow("CLOUDFLARE_API_TOKEN is required");

      expect(() =>
        preflightBootstrapInterruption(
          config,
          probeEnvironment(alchemyRoot, workspaceRoot, {
            ...environment(),
            ALCHEMY_PROFILE: undefined,
          }),
        ),
      ).toThrow("ALCHEMY_PROFILE does not match the disposable configuration");

      expect(() =>
        preflightBootstrapInterruption(config, {
          ...probeEnvironment(alchemyRoot, workspaceRoot),
          umask: 0o022,
        }),
      ).toThrow("Set umask 077");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("allows the unresolved origin only for preflight before dashboard initialization", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory, {
        stateStoreOrigin: pendingStateStoreOrigin,
      });
      writeEnvironmentProfile(alchemyRoot);
      const probe = probeEnvironment(alchemyRoot, workspaceRoot);

      expect(preflightBootstrapInterruption(config, probe)).toMatchObject({
        accountId: disposableAccountId,
        profile,
      });
      expect(() => armBootstrapInterruption(config, probe)).toThrow(
        "Resolve stateStoreOrigin after the owner initializes the workers.dev subdomain",
      );

      writeConfiguration(directory);
      armBootstrapInterruption(config, probe);
      writeSettledLocalStack(workspaceRoot);
      writeConfiguration(directory, { stateStoreOrigin: pendingStateStoreOrigin });
      expect(() => assertInterruptedBootstrap(config, probe)).toThrow(
        "Resolve stateStoreOrigin after the owner initializes the workers.dev subdomain",
      );
      expect(() => disarmBootstrapInterruption(config, probe)).toThrow(
        "Resolve stateStoreOrigin after the owner initializes the workers.dev subdomain",
      );

      writeConfiguration(directory);
      assertInterruptedBootstrap(config, probe);
      disarmBootstrapInterruption(config, probe);
      const credentialDirectory = resolve(alchemyRoot, "credentials", profile);
      writeFileSync(
        resolve(credentialDirectory, "cloudflare-state-store.json"),
        JSON.stringify({
          accountId: disposableAccountId,
          url: stateStoreOrigin,
          authToken: "sensitive-and-never-returned",
        }),
        { mode: 0o600 },
      );
      writeConfiguration(directory, { stateStoreOrigin: pendingStateStoreOrigin });
      expect(() => assertRecoveredBootstrap(config, probe)).toThrow(
        "Resolve stateStoreOrigin after the owner initializes the workers.dev subdomain",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects malformed or non-approved state-store origins", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    try {
      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, { stateStoreOrigin: "pending" }),
        ),
      ).toThrow(
        "stateStoreOrigin must be the pending sentinel or verified state-store HTTPS origin",
      );
      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, {
            stateStoreOrigin: "http://alchemy-state-store.disposable.workers.dev",
          }),
        ),
      ).toThrow(
        "stateStoreOrigin must be the pending sentinel or verified state-store HTTPS origin",
      );
      expect(() =>
        readBootstrapInterruptionConfiguration(
          writeConfiguration(directory, {
            stateStoreOrigin: "https://alchemy-state-store.disposable.workers.dev",
          }),
        ),
      ).toThrow("stateStoreOrigin must match the approved disposable account origin");
      for (const stateStoreOrigin of [
        "https://alchemy-state-store.disposable.extra.workers.dev",
        "https://alchemy-state-store.disposable.workers.dev:8443",
      ]) {
        expect(() =>
          readBootstrapInterruptionConfiguration(
            writeConfiguration(directory, { stateStoreOrigin }),
          ),
        ).toThrow(
          "stateStoreOrigin must be the pending sentinel or verified state-store HTTPS origin",
        );
      }
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("arms only an empty marker-owned credential collision and disarms only that fixture", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);

      const probe = probeEnvironment(alchemyRoot, workspaceRoot);
      const armed = armBootstrapInterruption(config, probe);
      expect(armed.credentialCollisionPath).toBe(
        resolve(alchemyRoot, "credentials", profile, "cloudflare-state-store.json"),
      );
      expect(readFileSync(resolve(armed.credentialCollisionPath, "ARMED"), "utf8")).toContain(
        "issue-29-interrupted-bootstrap",
      );
      expect(() => armBootstrapInterruption(config, probe)).toThrow(
        "Disposable credential profile path already exists",
      );

      expect(() => disarmBootstrapInterruption(config, probe)).toThrow(
        "Interrupted local bootstrap stage is missing",
      );
      writeSettledLocalStack(workspaceRoot);
      disarmBootstrapInterruption(config, probe);
      expect(() => disarmBootstrapInterruption(config, probe)).toThrow(
        "Armed interruption fixture is missing",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("never disarms a wrong marker, extra entry, or symlinked collision", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);
      const probe = probeEnvironment(alchemyRoot, workspaceRoot);
      const { credentialCollisionPath } = armBootstrapInterruption(config, probe);
      const marker = resolve(credentialCollisionPath, "ARMED");
      const expectedMarker = readFileSync(marker, "utf8");

      writeFileSync(marker, "wrong-target\n", { mode: 0o600 });
      expect(() => disarmBootstrapInterruption(config, probe)).toThrow(
        "marker does not match the disposable target",
      );
      expect(existsSync(credentialCollisionPath)).toBe(true);

      writeFileSync(marker, expectedMarker, { mode: 0o600 });
      writeFileSync(resolve(credentialCollisionPath, "foreign"), "do-not-delete", { mode: 0o600 });
      expect(() => disarmBootstrapInterruption(config, probe)).toThrow(
        "fixture contains unexpected entries",
      );
      expect(existsSync(credentialCollisionPath)).toBe(true);

      const symlinkTarget = resolve(directory, "symlink-target");
      mkdirSync(symlinkTarget, { mode: 0o700 });
      writeFileSync(resolve(symlinkTarget, "ARMED"), expectedMarker, { mode: 0o600 });
      rmSync(credentialCollisionPath, { recursive: true });
      symlinkSync(symlinkTarget, credentialCollisionPath, "dir");
      expect(() => disarmBootstrapInterruption(config, probe)).toThrow(
        "Armed interruption fixture is missing",
      );
      expect(existsSync(credentialCollisionPath)).toBe(true);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("recognizes the settled local checkpoint without exposing its secret-bearing content", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);
      const probe = probeEnvironment(alchemyRoot, workspaceRoot);
      armBootstrapInterruption(config, probe);
      writeSettledLocalStack(workspaceRoot);

      const result = assertInterruptedBootstrap(config, probe);
      expect(result).toEqual({
        accountId: disposableAccountId,
        profile,
        localStage: `${profile}_alchemy-state-store`,
        resourceCount: EXPECTED_STATE_STORE_LOGICAL_IDS.length,
        statuses: ["created"],
      });
      expect(JSON.stringify(result)).not.toContain("not-read");

      writeFileSync(
        resolve(
          workspaceRoot,
          ".alchemy/state/CloudflareStateStore",
          `${profile}_alchemy-state-store`,
          "__stack_output__.json",
        ),
        JSON.stringify({ url: stateStoreOrigin, authToken: "" }),
        { mode: 0o600 },
      );
      expect(() => assertInterruptedBootstrap(config, probe)).toThrow(
        "stack output has no bearer token",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects an in-flight local checkpoint", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);
      const probe = probeEnvironment(alchemyRoot, workspaceRoot);
      armBootstrapInterruption(config, probe);
      writeSettledLocalStack(workspaceRoot);
      writeFileSync(
        resolve(
          workspaceRoot,
          ".alchemy/state/CloudflareStateStore",
          `${profile}_alchemy-state-store`,
          "Api.json.123.tmp",
        ),
        "partial",
      );

      expect(() => assertInterruptedBootstrap(config, probe)).toThrow(
        "checkpoint contains in-flight or unexpected files",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects an unexpected resource row at the pinned checkpoint", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);
      const probe = probeEnvironment(alchemyRoot, workspaceRoot);
      armBootstrapInterruption(config, probe);
      writeSettledLocalStack(workspaceRoot);
      writeFileSync(
        resolve(
          workspaceRoot,
          ".alchemy/state/CloudflareStateStore",
          `${profile}_alchemy-state-store`,
          "Unexpected.json",
        ),
        JSON.stringify({
          kind: "resource",
          fqn: "Unexpected",
          logicalId: "Unexpected",
          resourceType: "fixture",
          status: "created",
        }),
        { mode: 0o600 },
      );

      expect(() => assertInterruptedBootstrap(config, probe)).toThrow(
        "checkpoint resource identity mismatch",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects group/world-readable secret-bearing checkpoint files", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);
      const probe = probeEnvironment(alchemyRoot, workspaceRoot);
      armBootstrapInterruption(config, probe);
      writeSettledLocalStack(workspaceRoot);
      chmodSync(
        resolve(
          workspaceRoot,
          ".alchemy/state/CloudflareStateStore",
          `${profile}_alchemy-state-store`,
          "__stack_output__.json",
        ),
        0o644,
      );

      expect(() => assertInterruptedBootstrap(config, probe)).toThrow(
        "stack output must not be readable or writable by group/other",
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("accepts recovery only after local hoist cleanup and an account-bound credential cache", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "trigo-bootstrap-interruption-"));
    const alchemyRoot = resolve(directory, "home-alchemy");
    const workspaceRoot = resolve(directory, "workspace");
    try {
      mkdirSync(workspaceRoot);
      const config = writeConfiguration(directory);
      writeEnvironmentProfile(alchemyRoot);
      const credentialDirectory = resolve(alchemyRoot, "credentials", profile);
      mkdirSync(credentialDirectory, { recursive: true, mode: 0o700 });
      writeFileSync(
        resolve(credentialDirectory, "cloudflare-state-store.json"),
        JSON.stringify({
          accountId: disposableAccountId,
          url: stateStoreOrigin,
          authToken: "sensitive-and-never-returned",
        }),
        { mode: 0o600 },
      );

      const result = assertRecoveredBootstrap(config, probeEnvironment(alchemyRoot, workspaceRoot));
      expect(result).toEqual({
        accountId: disposableAccountId,
        profile,
        localStage: `${profile}_alchemy-state-store`,
        localStageAbsent: true,
        credentialAccountMatches: true,
      });
      expect(JSON.stringify(result)).not.toContain("sensitive-and-never-returned");

      writeFileSync(
        resolve(credentialDirectory, "cloudflare-state-store.json"),
        JSON.stringify({
          accountId: disposableAccountId,
          url: "https://alchemy-state-store.wrong-account.workers.dev",
          authToken: "sensitive-and-never-returned",
        }),
        { mode: 0o600 },
      );
      expect(() =>
        assertRecoveredBootstrap(config, probeEnvironment(alchemyRoot, workspaceRoot)),
      ).toThrow("does not match the verified state-store origin");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
