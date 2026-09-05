import { Stack, localState } from "alchemy";
import { Bucket } from "alchemy/Cloudflare/R2";
import { Worker } from "alchemy/Cloudflare/Workers";
import { providers } from "alchemy/Cloudflare";
import { Config, Effect } from "effect";

// This closed composition declares only local Worker/R2 resources. No AI binding,
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
    const worker = yield* Worker("Api", {
      main: new URL("../apps/server/src/local-worker.ts", import.meta.url).pathname,
      env: { LOCAL_ARCHIVE: bucket, LOCAL_RUN_ID: runId },
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
