import type { LocalEnv } from "./local-worker.ts";
declare global {
  namespace Cloudflare {
    interface Env extends LocalEnv {
      CATALOG: D1Database;
    }
    interface GlobalProps {
      mainModule: typeof import("./local-worker.ts");
    }
  }
}
