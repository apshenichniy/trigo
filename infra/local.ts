import { Stack, localState } from "alchemy";
import { Bucket } from "alchemy/Cloudflare/R2";
import { Worker } from "alchemy/Cloudflare/Workers";
import { providers } from "alchemy/Cloudflare";
import { Effect } from "effect";
if (process.env.ALCHEMY_DEV !== "true" || process.env.TRIGO_LOCAL !== "1")
  throw new Error("Use bun run dev: this composition is local only");
// This closed composition declares only local Worker/R2 resources. No AI binding,
// remote state, domain, remote resource opt-in or user supplied resource config.
export default Stack(
  "trigo-local",
  {
    providers: providers(),
    state: localState(),
  },
  Effect.gen(function* () {
    const bucket = yield* Bucket("Archive");
    const worker = yield* Worker("Api", {
      main: new URL("../apps/server/src/local-worker.ts", import.meta.url).pathname,
      env: { LOCAL_ARCHIVE: bucket, LOCAL_RUN_ID: process.env.TRIGO_LOCAL_RUN_ID! },
      compatibility: { date: "2026-07-04", flags: ["nodejs_compat"] },
      dev: {
        host: "127.0.0.1",
        port: Number(process.env.TRIGO_LOCAL_PORT ?? 19371),
        strictPort: true,
      },
    });
    return { url: worker.url };
  }),
);
