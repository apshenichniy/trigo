import { Effect } from "effect";
import { fakeAsr, type Asr } from "./asr.ts";
export interface LocalEnv {
  LOCAL_ARCHIVE: R2Bucket;
}
export function localHandler(asr: Asr) {
  return {
    async fetch(request: Request, env: LocalEnv): Promise<Response> {
      const url = new URL(request.url);
      if (url.pathname === "/__local/health")
        return Response.json({ mode: "local", asr: "fake", schemaVersion: 1 });
      const match = /^\/__local\/transcriptions\/([a-z-]+)$/.exec(url.pathname);
      if (!match) return Response.json({ error: "unavailable", issue: 12 }, { status: 501 });
      const fixture = match[1]!;
      if (fixture !== "no-speech")
        return Response.json({ error: "unknown_fixture" }, { status: 400 });
      const key = `fixtures/${fixture}.json`;
      if (request.method === "GET") {
        const object = await env.LOCAL_ARCHIVE.get(key);
        return object
          ? new Response(object.body, { headers: { "content-type": "application/json" } })
          : new Response(null, { status: 404 });
      }
      if (request.method !== "POST") return new Response(null, { status: 405 });
      return Effect.runPromise(
        Effect.gen(function* () {
          const result = yield* asr.transcribe(fixture);
          yield* Effect.promise(() => env.LOCAL_ARCHIVE.put(key, JSON.stringify(result)));
          return Response.json(result, { status: 201 });
        }).pipe(
          Effect.catch(() =>
            Effect.succeed(Response.json({ error: "local_asr_failed" }, { status: 500 })),
          ),
        ),
      );
    },
  };
}
export default localHandler(fakeAsr);
