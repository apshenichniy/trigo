import { Stack, localState } from "alchemy";
import { Bucket } from "alchemy/Cloudflare/R2";
import { Worker } from "alchemy/Cloudflare/Workers";
import { providers, D1, Workflows } from "alchemy/Cloudflare";
import { Config, Effect } from "effect";

// This closed composition declares only supported local Worker/D1/R2/workflow resources. No AI binding,
// remote state, domain, remote resource opt-in or user supplied resource config.
export default Stack(
  "trigo-local",
  {
    providers: providers(),
    state: localState(),
  },
  Effect.gen(function* () {
    yield* Config.literal("true", "ALCHEMY_DEV");
    yield* Config.literal("1", "TRIGO_LOCAL");
    const runId = yield* Config.nonEmptyString("TRIGO_LOCAL_RUN_ID");
    const port = yield* Config.finite("TRIGO_LOCAL_PORT").pipe(Config.withDefault(19371));
    const bucket = yield* Bucket("Archive");
    const catalog = yield* D1.Database("Catalog", {
      migrations: new URL("../apps/server/migrations", import.meta.url).pathname,
    });
    const workflow = Workflows.Workflow<{ runId: string }>("OfflineProbe", {
      className: "LocalProbeWorkflow",
    });
    const archiveId = yield* Config.nonEmptyString("TRIGO_LOCAL_ARCHIVE_ID");
    const verifier = yield* Config.nonEmptyString("TRIGO_LOCAL_OWNER_VERIFIER");
    const worker = yield* Worker("Api", {
      main: new URL("../apps/server/src/local-worker.ts", import.meta.url).pathname,
      env: {
        LOCAL_ARCHIVE: bucket,
        CATALOG: catalog,
        ARCHIVE_WORKFLOW: workflow,
        LOCAL_RUN_ID: runId,
        LOCAL_ARCHIVE_ID: archiveId,
        LOCAL_OWNER_VERIFIER: verifier,
      },
      compatibility: { date: "2026-07-04", flags: ["nodejs_compat"] },
      dev: {
        host: "127.0.0.1",
        port,
        strictPort: true,
      },
    });
    return { url: worker.url };
  }),
);
