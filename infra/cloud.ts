import { Stack } from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import * as RemovalPolicy from "alchemy/RemovalPolicy";
import { Config, Effect } from "effect";

import type { PendingArchiveWorkflowInput } from "../apps/server/src/cloud-worker.ts";
import { cloudDeploymentIdentity, cloudTargetFor } from "../scripts/cloud.ts";

const cloudStage = Config.literals(["dev", "personal"], "TRIGO_CLOUD_STAGE");

export default Stack(
  "trigo-cloud",
  {
    providers: Cloudflare.providers(),
    state: Cloudflare.state(),
  },
  Effect.gen(function* () {
    const stage = yield* cloudStage;
    const target = cloudTargetFor(stage);
    const accountId = yield* Config.nonEmptyString("CLOUDFLARE_ACCOUNT_ID");

    const archive = yield* Cloudflare.R2.Bucket("Archive", {
      name: target.resources.archiveBucket,
      publicAccess: false,
      domains: [],
      forceDestroy: false,
    }).pipe(RemovalPolicy.retain());
    const catalog = yield* Cloudflare.D1.Database("Catalog", {
      name: target.resources.catalogDatabase,
      jurisdiction: "default",
      readReplication: { mode: "disabled" },
      migrations: "./apps/server/migrations",
    }).pipe(RemovalPolicy.retain());
    const workflow = Cloudflare.Workflows.Workflow<PendingArchiveWorkflowInput>(
      target.resources.workflow,
      {
        className: "PendingArchiveWorkflow",
        limits: { steps: 1 },
      },
    );
    const api = yield* Cloudflare.Worker("Api", {
      name: target.resources.apiWorker,
      main: new URL("../apps/server/src/cloud-worker.ts", import.meta.url).pathname,
      workersDev: true,
      compatibility: { date: "2026-08-15", flags: ["nodejs_compat"] },
      env: {
        ARCHIVE: archive,
        CATALOG: catalog,
        ARCHIVE_WORKFLOW: workflow,
        AI: Cloudflare.Workers.AI(),
        DEPLOYMENT_STAGE: stage,
        DEPLOYMENT_IDENTITY: cloudDeploymentIdentity(target, accountId),
      },
    });

    return {
      stage,
      stack: target.stack,
      resources: target.resources,
      apiUrl: api.url,
      archiveBucket: archive.bucketName,
      catalogDatabaseId: catalog.databaseId,
    };
  }),
);
