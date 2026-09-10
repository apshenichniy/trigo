import { Effect, Schema } from "effect";

import type { AsrProbeLanguageCode } from "@trigo/contracts";

import { assemblyAIStereoProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { AssemblyAIJob, AssemblyAIJobId, decodeAssemblyAIJSON } from "./assemblyai-response.ts";
import { captureBoundedBody, readBoundedBody } from "./nova-3-transport.ts";
import {
  type TranscriptionError,
  transcriptionError,
  transcriptionJSON,
} from "./transcription-errors.ts";

export interface AssemblyAIResponse {
  readonly bytes: Uint8Array;
  readonly complete: boolean;
}
export interface AssemblyAIClient {
  readonly upload: (
    body: ReadableStream<Uint8Array>,
    byteLength: number,
  ) => Effect.Effect<string, TranscriptionError>;
  readonly submit: (
    uploadURL: string,
    language: AsrProbeLanguageCode,
  ) => Effect.Effect<AssemblyAIJob, TranscriptionError>;
  readonly get: (providerId: string) => Effect.Effect<AssemblyAIResponse, TranscriptionError>;
  readonly find: (uploadURL: string) => Effect.Effect<string | null, TranscriptionError>;
  readonly delete: (providerId: string) => Effect.Effect<void, TranscriptionError>;
}
type Fetch = (url: string, init: RequestInit) => Promise<Response>;
const UploadResponse = Schema.Struct({
  upload_url: Schema.NonEmptyString.check(Schema.isMaxLength(2048)),
});
const Listing = Schema.Struct({
  page_details: Schema.Struct({ prev_url: Schema.NullOr(Schema.String) }),
  transcripts: Schema.Array(Schema.Struct({ id: AssemblyAIJobId, audio_url: Schema.String })),
});

function responseFailure(status: number, paid: boolean): TranscriptionError {
  if (status === 401 || status === 403) {
    return transcriptionError("asr_configuration");
  }
  if (status === 402) {
    return transcriptionError("asr_funds");
  }
  if ([400, 413, 415, 422].includes(status)) {
    return transcriptionError("asr_input_rejected");
  }
  if (paid && status !== 429) {
    return transcriptionError("asr_admission_uncertain");
  }
  return transcriptionError("asr_provider_unavailable", "retryable", 503);
}

/** Cloudflare's fixed-length Web Stream is the raw HTTP upload boundary. There is no SDK
 * submit retry, no gateway, and no whole-master buffer. All secrets stay in this adapter. */
export function assemblyAIClient(
  apiKey: string | undefined,
  fetcher: Fetch = fetch,
): AssemblyAIClient {
  const headers = (json = true) => ({
    authorization: apiKey ?? "",
    "content-type": json ? "application/json" : "application/octet-stream",
  });
  const configured = Effect.suspend(() =>
    apiKey?.trim() ? Effect.void : Effect.fail(transcriptionError("asr_configuration")),
  );
  const request = Effect.fn("AssemblyAI.request")(function* (
    path: string,
    method: "GET" | "POST" | "DELETE",
    body?: string,
  ) {
    yield* configured;
    const response = yield* Effect.tryPromise({
      try: (signal) =>
        fetcher(`${assemblyAIStereoProfile.apiBase}${path}`, {
          method,
          headers: headers(),
          ...(body === undefined ? {} : { body }),
          signal,
          redirect: "error",
        }),
      catch: () =>
        transcriptionError(
          method === "POST" ? "asr_admission_uncertain" : "asr_provider_unavailable",
          method === "POST" ? "after_correction" : "retryable",
          503,
        ),
    });
    if (response.status !== 200 && !(method === "DELETE" && response.status === 404)) {
      yield* Effect.promise(() => response.body?.cancel().catch(() => {}) ?? Promise.resolve());
      return yield* responseFailure(response.status, method === "POST");
    }
    return response;
  });
  const decodeSmall = Effect.fn("AssemblyAI.decodeSmall")(function* (response: Response) {
    const bytes = yield* readBoundedBody(response.body, 262_144).pipe(
      Effect.mapError(() => transcriptionError("asr_result_invalid")),
    );
    return yield* decodeAssemblyAIJSON(bytes);
  });
  const idPath = (id: string) => `/transcript/${encodeURIComponent(AssemblyAIJobId.make(id))}`;
  return {
    upload: Effect.fn("AssemblyAI.upload")(function* (body, byteLength) {
      yield* configured;
      if (
        !Number.isSafeInteger(byteLength) ||
        byteLength <= 44 ||
        byteLength > assemblyAIStereoProfile.maxSubmissionByteLength
      ) {
        return yield* transcriptionError("asr_input_rejected");
      }
      const response = yield* Effect.tryPromise({
        // oxlint-disable-next-line effecttsgo/async-function -- FixedLengthStream and fetch share one native abort/lifetime boundary in workerd.
        try: async (signal) => {
          const controller = new AbortController();
          const abort = () => controller.abort();
          signal.addEventListener("abort", abort, { once: true });
          if (signal.aborted) {
            controller.abort();
          }
          const fixed = new FixedLengthStream(byteLength);
          const copied = body.pipeTo(fixed.writable, { signal: controller.signal }).then(
            () => true,
            () => false,
          );
          let finished = false;
          try {
            const response = await fetcher(`${assemblyAIStereoProfile.apiBase}/upload`, {
              method: "POST",
              headers: headers(false),
              body: fixed.readable,
              signal: controller.signal,
              redirect: "error",
            });
            if (response.status !== 200) {
              controller.abort();
            }
            const complete = await copied;
            if (response.status === 200 && !complete) {
              throw new Error("Incomplete upload");
            }
            finished = true;
            return response;
          } finally {
            if (!finished) {
              controller.abort();
            }
            await copied;
            signal.removeEventListener("abort", abort);
          }
        },
        catch: () => transcriptionError("asr_provider_unavailable", "retryable", 503),
      });
      if (response.status !== 200) {
        yield* Effect.promise(() => response.body?.cancel().catch(() => {}) ?? Promise.resolve());
        return yield* responseFailure(response.status, false);
      }
      const decoded = yield* Schema.decodeUnknownEffect(UploadResponse)(
        yield* decodeSmall(response),
      ).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid")));
      const url = yield* Effect.try({
        try: () => new URL(decoded.upload_url),
        catch: () => transcriptionError("asr_result_invalid"),
      });
      if (
        url.protocol !== "https:" ||
        url.username ||
        url.password ||
        !url.hostname.endsWith(".assemblyai.com")
      ) {
        return yield* transcriptionError("asr_result_invalid");
      }
      return decoded.upload_url;
    }),
    submit: Effect.fn("AssemblyAI.submit")(function* (uploadURL, language) {
      const response = yield* request(
        "/transcript",
        "POST",
        yield* transcriptionJSON({
          audio_url: uploadURL,
          speech_models: [assemblyAIStereoProfile.model],
          language_code: language,
          language_detection: false,
          multichannel: true,
          speaker_labels: true,
          punctuate: true,
          format_text: true,
        }),
      );
      const job = yield* decodeSmall(response).pipe(
        Effect.flatMap(Schema.decodeUnknownEffect(AssemblyAIJob)),
        Effect.mapError(() => transcriptionError("asr_admission_uncertain")),
      );
      if (job.audio_url !== uploadURL || job.is_deleted === true) {
        return yield* transcriptionError("asr_admission_uncertain");
      }
      return job;
    }),
    get: Effect.fn("AssemblyAI.get")(function* (providerId) {
      const response = yield* request(idPath(providerId), "GET");
      return yield* captureBoundedBody(response.body, assemblyAIStereoProfile.maxRawResponseBytes);
    }),
    find: Effect.fn("AssemblyAI.findAdmission")(function* (uploadURL) {
      let before: string | undefined;
      const seen = new Set<string>();
      const matches = new Set<string>();
      for (let page = 0; page < 10; page++) {
        const response = yield* request(
          `/transcript?limit=200${before === undefined ? "" : `&before_id=${encodeURIComponent(before)}`}`,
          "GET",
        );
        const listing = yield* Schema.decodeUnknownEffect(Listing)(
          yield* decodeSmall(response),
        ).pipe(
          Effect.mapError(() => transcriptionError("asr_provider_unavailable", "retryable", 503)),
        );
        for (const item of listing.transcripts) {
          if (item.audio_url === uploadURL) {
            matches.add(item.id);
          }
        }
        if (matches.size > 1) {
          return yield* transcriptionError("asr_admission_uncertain");
        }
        if (listing.page_details.prev_url === null || listing.transcripts.length === 0) {
          return [...matches][0] ?? null;
        }
        before = listing.transcripts.at(-1)?.id;
        if (before === undefined || seen.has(before)) {
          return yield* transcriptionError("asr_admission_uncertain");
        }
        seen.add(before);
      }
      // A bounded listing cannot prove absence. Do not turn incomplete recovery into a paid retry.
      return yield* transcriptionError("asr_admission_uncertain");
    }),
    delete: Effect.fn("AssemblyAI.deleteRetainedCopy")(function* (providerId) {
      const response = yield* request(idPath(providerId), "DELETE");
      if (response.status === 404) {
        return;
      }
      const deleted = yield* Schema.decodeUnknownEffect(
        Schema.Struct({ id: AssemblyAIJobId, is_deleted: Schema.Literal(true) }),
      )(yield* decodeSmall(response)).pipe(
        Effect.mapError(() => transcriptionError("asr_cleanup_pending", "retryable", 503)),
      );
      if (deleted.id !== providerId) {
        return yield* transcriptionError("asr_cleanup_pending", "retryable", 503);
      }
    }),
  };
}
