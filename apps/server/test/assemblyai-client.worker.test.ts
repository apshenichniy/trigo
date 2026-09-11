/* oxlint-disable effecttsgo/async-function -- Tests exercise fetch and FixedLengthStream in workerd. */
import { Effect } from "effect";
import { expect, it, vi } from "vitest";

import { assemblyAIClient } from "../src/assemblyai-client.ts";
import { assemblyAIResponse } from "./assemblyai-fixture.ts";

it("uploads the exact bounded stream to EU and submits only explicit stereo options", async () => {
  const response = assemblyAIResponse();
  const fetcher = vi.fn(async (url: string, init: RequestInit) => {
    expect(init.headers).toMatchObject({ authorization: "fixture-secret" });
    expect(init.redirect).toBe("manual");
    if (url.endsWith("/upload")) {
      expect(new Uint8Array(await new Response(init.body).arrayBuffer())).toEqual(
        new Uint8Array(64),
      );
      return Response.json({ upload_url: response.audio_url });
    }
    expect(url).toBe("https://api.eu.assemblyai.com/v2/transcript");
    if (typeof init.body !== "string") {
      throw new Error("Expected a JSON request body");
    }
    expect(JSON.parse(init.body)).toEqual({
      audio_url: response.audio_url,
      speech_models: ["universal-2"],
      language_code: "uk",
      language_detection: false,
      multichannel: true,
      speaker_labels: true,
      punctuate: true,
      format_text: true,
    });
    return Response.json({ ...response, status: "queued" });
  });
  const client = assemblyAIClient("fixture-secret", fetcher);
  const upload = await Effect.runPromise(client.upload(new Response(new Uint8Array(64)).body!, 64));
  await Effect.runPromise(client.submit(upload, "uk"));
  expect(fetcher).toHaveBeenCalledTimes(2);
});

it.each([401, 402, 422, 429, 500])("does not retry POST on HTTP %i", async (status) => {
  const fetcher = vi.fn(async () => new Response("failure", { status }));
  const result = await Effect.runPromise(
    assemblyAIClient("secret", fetcher)
      .submit(assemblyAIResponse().audio_url, "en")
      .pipe(Effect.result),
  );
  const code = {
    401: "asr_configuration",
    402: "asr_funds",
    422: "asr_input_rejected",
    429: "asr_provider_unavailable",
    500: "asr_admission_uncertain",
  }[status];
  expect(result).toMatchObject({ _tag: "Failure", failure: { code } });
  expect(fetcher).toHaveBeenCalledTimes(1);
});

it("preserves unknown admission after a lost or malformed POST acknowledgment", async () => {
  for (const kind of ["transport", "json"] as const) {
    const fetcher = vi.fn(async () => {
      if (kind === "transport") {
        throw new Error("response lost");
      }
      return new Response("not JSON");
    });
    const result = await Effect.runPromise(
      assemblyAIClient("secret", fetcher)
        .submit(assemblyAIResponse().audio_url, "en")
        .pipe(Effect.result),
    );
    expect(result).toMatchObject({ _tag: "Failure", failure: { code: "asr_admission_uncertain" } });
    expect(fetcher).toHaveBeenCalledTimes(1);
  }
});

it("uses only its fixed API origin while recovering an exact upload identity", async () => {
  const fetcher = vi.fn(async (url: string) => {
    if (url.includes("before_id")) {
      return Response.json({
        page_details: { prev_url: null },
        transcripts: [{ id: "provider-1", audio_url: assemblyAIResponse().audio_url }],
      });
    }
    return Response.json({
      page_details: { prev_url: "https://untrusted.invalid/page" },
      transcripts: [{ id: "other", audio_url: "other" }],
    });
  });
  expect(
    await Effect.runPromise(
      assemblyAIClient("secret", fetcher).find(assemblyAIResponse().audio_url),
    ),
  ).toBe("provider-1");
  expect(fetcher.mock.calls.map(([url]) => url)).toEqual([
    "https://api.eu.assemblyai.com/v2/transcript?limit=200",
    "https://api.eu.assemblyai.com/v2/transcript?limit=200&before_id=other",
  ]);
});

it("rejects ambiguous lookup and wrong deletion identity", async () => {
  const url = assemblyAIResponse().audio_url;
  const client = assemblyAIClient("secret", async (_url, init) =>
    Response.json(
      init.method === "DELETE"
        ? { id: "other", is_deleted: true }
        : {
            page_details: { prev_url: null },
            transcripts: [
              { id: "one", audio_url: url },
              { id: "two", audio_url: url },
            ],
          },
    ),
  );
  expect(await Effect.runPromise(client.find(url).pipe(Effect.result))).toMatchObject({
    _tag: "Failure",
    failure: { code: "asr_admission_uncertain" },
  });
  expect(await Effect.runPromise(client.delete("provider-1").pipe(Effect.result))).toMatchObject({
    _tag: "Failure",
    failure: { code: "asr_cleanup_pending" },
  });
});
