// Web Streams and R2 require promise callbacks; domain operations remain in Effect services.
/* oxlint-disable effecttsgo/async-function, effecttsgo/node-builtin-import */
import { createHash } from "node:crypto";

import { Schema } from "effect";

import { uploadPartBytes } from "@trigo/contracts";

import { invalidUpload, UploadError } from "./upload-errors.ts";

export type UploadBucket = Pick<R2Bucket, "get" | "put" | "head">;
export interface StoredRange {
  readonly object_key: string;
  readonly byte_length: number;
  readonly sha256: string;
}

/** Matches the immutable CAF header of the proven native capture profile, byte for byte. */
export const cafMasterHeader = new Uint8Array([
  99, 97, 102, 102, 0, 1, 0, 0, 100, 101, 115, 99, 0, 0, 0, 0, 0, 0, 0, 32, 64, 207, 64, 0, 0, 0, 0,
  0, 108, 112, 99, 109, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 16, 100, 97, 116,
  97, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0,
]);

export function verifyStream(byteLength: number, sha256: string, masterHeader = false) {
  let count = 0;
  const hash = createHash("sha256");
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      if (count + chunk.byteLength > byteLength) {
        throw invalidUpload("The body exceeds its admitted byte length.");
      }
      if (masterHeader) {
        const end = Math.min(chunk.byteLength, cafMasterHeader.length - count);
        for (let i = 0; i < end; i++) {
          if (chunk[i] !== cafMasterHeader[count + i]) {
            throw invalidUpload("The master header does not match the CAF capture profile.");
          }
        }
      }
      count += chunk.byteLength;
      hash.update(chunk);
      controller.enqueue(chunk);
    },
    flush() {
      if (count !== byteLength || hash.digest("hex") !== sha256) {
        throw invalidUpload("The body length or SHA-256 differs from the admitted content.");
      }
    },
  });
}

export function objectMatches(object: R2Object, expected: StoredRange): boolean {
  const digest = object.checksums.sha256;
  return (
    object.size === expected.byte_length &&
    digest !== undefined &&
    Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("") ===
      expected.sha256
  );
}

export function verifyRepeatedBody(
  body: ReadableStream<Uint8Array>,
  length: number,
  sha256: string,
) {
  return body.pipeThrough(verifyStream(length, sha256)).pipeTo(new WritableStream({ write() {} }));
}

/** One stream, bounded backpressure, and a runtime-enforced length; no whole-master buffer. */
export async function putVerified(
  bucket: UploadBucket,
  target: StoredRange,
  body: ReadableStream<Uint8Array>,
  master: boolean,
): Promise<void> {
  const fixed = new FixedLengthStream(target.byte_length);
  const abort = new AbortController();
  const producing = body
    .pipeThrough(verifyStream(target.byte_length, target.sha256, master))
    .pipeTo(fixed.writable, { signal: abort.signal });
  const storing = bucket
    .put(target.object_key, fixed.readable, {
      sha256: target.sha256,
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: master ? "audio/x-caf" : "application/octet-stream" },
    })
    .then(
      (object) => {
        if (!object) {
          abort.abort(invalidUpload("The immutable storage key already exists."));
        }
        return object;
      },
      (error: unknown) => {
        abort.abort(error);
        throw error;
      },
    );
  try {
    const [produced, stored] = await Promise.allSettled([producing, storing]);
    if (produced.status === "rejected") {
      throw produced.reason;
    }
    if (stored.status === "rejected") {
      throw stored.reason;
    }
    const object = stored.value;
    if (!object || !objectMatches(object, target)) {
      throw invalidUpload("Storage did not verify the complete object checksum.");
    }
  } finally {
    abort.abort();
  }
}

/** Open only one range at a time. Every range and the resulting complete master are hashed. */
export function assembleMaster(bucket: UploadBucket, parts: readonly StoredRange[]) {
  let index = 0;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        while (true) {
          if (!reader) {
            const part = parts[index++];
            if (!part) {
              controller.close();
              return;
            }
            const object = await bucket.get(part.object_key);
            if (!object || !objectMatches(object, part)) {
              throw invalidUpload("A retained range is missing or its checksum differs.");
            }
            reader = object.body
              .pipeThrough(verifyStream(part.byte_length, part.sha256))
              .getReader();
          }
          const next = await reader.read();
          if (next.done) {
            reader.releaseLock();
            reader = undefined;
          } else {
            controller.enqueue(next.value);
            return;
          }
        }
      } catch (error) {
        await reader?.cancel(error).catch(() => {});
        controller.error(error);
      }
    },
    async cancel(reason) {
      await reader?.cancel(reason);
    },
  });
}

/** JSON metadata is bounded independently of both the call size and its transport parts. */
export async function boundedJson(request: Request): Promise<unknown> {
  if (
    !request.headers
      .get("content-type")
      ?.split(";")[0]
      ?.trim()
      .match(/^application\/json$/i)
  ) {
    throw invalidUpload("Use application/json for this request.");
  }
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > uploadPartBytes)) {
    throw oversizedUpload();
  }
  if (!request.body) {
    throw invalidUpload("A JSON body is required.");
  }
  const reader = request.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let count = 0;
  let text = "";
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) {
        break;
      }
      count += next.value.byteLength;
      if (count > uploadPartBytes) {
        throw oversizedUpload();
      }
      text += decoder.decode(next.value, { stream: true });
    }
    text += decoder.decode();
    return Schema.decodeSync(Schema.fromJsonString(Schema.Unknown))(text);
  } catch (error) {
    await reader.cancel(error).catch(() => {});
    if (Schema.is(UploadError)(error)) {
      throw error;
    }
    throw invalidUpload("The body must be valid UTF-8 JSON.");
  } finally {
    reader.releaseLock();
  }
}

export function oversizedUpload() {
  return new UploadError({
    status: 413,
    code: "upload_too_large",
    retry: "after_correction",
    message: "An upload request cannot exceed 8 MiB.",
  });
}
