import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./apps/server/src/local-worker.ts",
      remoteBindings: false,
      miniflare: {
        compatibilityDate: "2026-08-15",
        compatibilityFlags: ["nodejs_compat"],
        r2Buckets: ["LOCAL_ARCHIVE"],
        d1Databases: ["CATALOG"],
        workflows: { ARCHIVE_WORKFLOW: { name: "offline-probe", className: "LocalProbeWorkflow" } },
        bindings: {
          LOCAL_RUN_ID: "00000000-0000-4000-8000-000000000054",
          LOCAL_ARCHIVE_ID: "00000000-0000-4000-8000-000000000054",
          LOCAL_OWNER_VERIFIER: "f".repeat(64),
        },
        outboundService: () => new Response("External service access denied", { status: 403 }),
      },
    }),
  ],
  test: { hookTimeout: 20000, testTimeout: 10000, include: ["apps/server/test/*.worker.test.ts"] },
});
