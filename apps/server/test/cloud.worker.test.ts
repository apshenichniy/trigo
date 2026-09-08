import { describe, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import cloudWorker from "../src/cloud-worker.ts";

function cloudBindings() {
  return {
    ARCHIVE: { get: vi.fn(), put: vi.fn(), head: vi.fn(), delete: vi.fn() },
    CATALOG: { prepare: vi.fn() },
    ARCHIVE_WORKFLOW: { create: vi.fn(), get: vi.fn() },
    AI: { run: vi.fn() },
    DEPLOYMENT_STAGE: "dev" as const,
    DEPLOYMENT_IDENTITY: "trigo-dev-api:9236f745b86ef20f",
  };
}

describe("cloud Worker boundary", () => {
  it("reports configured bindings without invoking Workflow or Workers AI", async () => {
    const env = cloudBindings();
    const response = await cloudWorker.fetch(
      new Request("https://trigo.invalid/__trigo/infrastructure"),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      stage: "dev",
      identity: "trigo-dev-api:9236f745b86ef20f",
      bindings: {
        archive: "configured",
        catalog: "configured",
        workflow: "configured",
        workersAi: "configured-not-verified",
      },
    });
    expect(env.ARCHIVE.get).not.toHaveBeenCalled();
    expect(env.CATALOG.prepare).not.toHaveBeenCalled();
    expect(env.ARCHIVE_WORKFLOW.create).not.toHaveBeenCalled();
    expect(env.AI.run).not.toHaveBeenCalled();
  });

  it("protects product routes before any unavailable operation is revealed", async () => {
    const response = await cloudWorker.fetch(
      new Request("https://trigo.invalid/v1/status"),
      cloudBindings(),
    );

    expect(response.status).toBe(401);
    expect(validateDocument("ErrorEnvelope", await response.json())).toMatchObject({
      schemaVersion: 1,
      error: {
        code: "owner_unauthorized",
        retry: "after_correction",
      },
    });
  });
});
