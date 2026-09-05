import { Effect, Schema } from "effect";
import { fakeAsr, type Asr, LocalTranscript } from "./asr.ts";

export interface LocalEnv {
  LOCAL_ARCHIVE: R2Bucket;
  LOCAL_RUN_ID: string;
}

const encodeTranscript = Schema.encodeEffect(Schema.fromJsonString(LocalTranscript));

const readStoredTranscript = Effect.fn("LocalWorker.readStoredTranscript")(
  (archive: R2Bucket, key: string) =>
    Effect.promise(() => archive.get(key)).pipe(
      Effect.map((object) =>
        object
          ? new Response(object.body, { headers: { "content-type": "application/json" } })
          : new Response(null, { status: 404 }),
      ),
    ),
);

const transcribeAndStore = Effect.fn("LocalWorker.transcribeAndStore")(function* (
  asr: Asr,
  archive: R2Bucket,
  fixture: string,
) {
  const result = yield* asr.transcribe(fixture);
  const encoded = yield* encodeTranscript(result).pipe(Effect.orDie);
  yield* Effect.promise(() => archive.put(`fixtures/${fixture}.json`, encoded));
  return Response.json(result, { status: 201 });
});

export function localHandler(asr: Asr) {
  return {
    fetch(request: Request, env: LocalEnv): Response | Promise<Response> {
      const url = new URL(request.url);
      if (url.pathname === "/__local/health")
        return Response.json({
          mode: "local",
          asr: "fake",
          schemaVersion: 1,
          runId: env.LOCAL_RUN_ID,
        });
      const match = /^\/__local\/transcriptions\/([a-z-]+)$/.exec(url.pathname);
      if (!match) return Response.json({ error: "unavailable", issue: 12 }, { status: 501 });
      const fixture = match[1];
      if (fixture === undefined)
        return Response.json({ error: "unknown_fixture" }, { status: 400 });
      if (fixture !== "no-speech")
        return Response.json({ error: "unknown_fixture" }, { status: 400 });
      const key = `fixtures/${fixture}.json`;
      if (request.method === "GET")
        return Effect.runPromise(readStoredTranscript(env.LOCAL_ARCHIVE, key));
      if (request.method !== "POST") return new Response(null, { status: 405 });
      return Effect.runPromise(
        transcribeAndStore(asr, env.LOCAL_ARCHIVE, fixture).pipe(
          Effect.orElseSucceed(() => Response.json({ error: "local_asr_failed" }, { status: 500 })),
        ),
      );
    },
  };
}
export default localHandler(fakeAsr);
