// Incremental hashing measures the production Web Streams boundary without retaining fixture audio.
// oxlint-disable-next-line effecttsgo/node-builtin-import
import { createHash } from "node:crypto";

import { DateTime } from "effect";
import { expect, it } from "vitest";

import { maximumMasterBytes, uploadPartBytes } from "@trigo/contracts";

import {
  assembleMaster,
  cafMasterHeader,
  putVerified,
  type StoredRange,
  type UploadBucket,
} from "../src/upload-streams.ts";

function metadata(range: StoredRange) {
  const digest = new Uint8Array(
    range.sha256.match(/../g)!.map((byte) => Number.parseInt(byte, 16)),
  );
  return {
    key: range.object_key,
    version: "fixture",
    size: range.byte_length,
    etag: "deliberately-not-a-sha256",
    httpEtag: '"deliberately-not-a-sha256"',
    checksums: { sha256: digest.buffer, toJSON: () => ({ sha256: range.sha256 }) },
    uploaded: DateTime.toDate(DateTime.makeUnsafe("2026-09-08T00:00:00.000Z")),
    storageClass: "Standard",
    writeHttpMetadata() {},
  };
}

it("streams the entire three-hour master with one open range and less than one MiB queued", async () => {
  const chunkBytes = 65_536;
  const chunk = (offset: number, count: number) => {
    const bytes = new Uint8Array(count);
    if (offset === 0) {
      bytes.set(cafMasterHeader);
    }
    return bytes;
  };
  const whole = createHash("sha256");
  const ranges: StoredRange[] = [];
  for (let offset = 0; offset < maximumMasterBytes; offset += uploadPartBytes) {
    const length = Math.min(uploadPartBytes, maximumMasterBytes - offset);
    const part = createHash("sha256");
    for (let local = 0; local < length; local += chunkBytes) {
      const bytes = chunk(offset + local, Math.min(chunkBytes, length - local));
      part.update(bytes);
      whole.update(bytes);
    }
    ranges.push({ object_key: String(offset), byte_length: length, sha256: part.digest("hex") });
  }
  const target = {
    object_key: "master",
    byte_length: maximumMasterBytes,
    sha256: whole.digest("hex"),
  };
  let opened = 0;
  let maximumOpen = 0;
  let queuedBytes = 0;
  let maximumQueued = 0;
  let maximumChunk = 0;
  let consumed = 0;
  let reads = 0;
  const forbidMaterialization = async (): Promise<never> => {
    throw new Error("Full object materialization is forbidden in this resource proof");
  };
  const bucket: UploadBucket = {
    async get(key) {
      const range = ranges.find((range) => range.object_key === key);
      if (!range) {
        return null;
      }
      reads += 1;
      opened += 1;
      maximumOpen = Math.max(maximumOpen, opened);
      let local = 0;
      const body = new ReadableStream<Uint8Array>({
        pull(controller) {
          if (local === range.byte_length) {
            opened -= 1;
            controller.close();
            return;
          }
          const bytes = chunk(Number(key) + local, Math.min(chunkBytes, range.byte_length - local));
          local += bytes.byteLength;
          queuedBytes += bytes.byteLength;
          maximumQueued = Math.max(maximumQueued, queuedBytes);
          controller.enqueue(bytes);
        },
        cancel() {
          opened -= 1;
        },
      });
      return {
        ...metadata(range),
        body,
        bodyUsed: false,
        writeHttpMetadata() {},
        arrayBuffer: forbidMaterialization,
        bytes: forbidMaterialization,
        text: forbidMaterialization,
        json: forbidMaterialization,
        blob: forbidMaterialization,
      };
    },
    async put(key, body, options) {
      expect(key).toBe(target.object_key);
      expect(options?.sha256).toBe(target.sha256);
      expect(options?.onlyIf).toEqual({ etagDoesNotMatch: "*" });
      if (!(body instanceof ReadableStream)) {
        throw new Error("The complete master must arrive as a stream");
      }
      const hash = createHash("sha256");
      const reader = body.getReader();
      while (true) {
        const next = await reader.read();
        if (next.done) {
          break;
        }
        const bytes: Uint8Array = next.value;
        consumed += bytes.byteLength;
        queuedBytes -= bytes.byteLength;
        maximumChunk = Math.max(maximumChunk, bytes.byteLength);
        hash.update(bytes);
        // Deliberately yield the sink, exercising backpressure through all production stages.
        await Promise.resolve();
      }
      expect(hash.digest("hex")).toBe(target.sha256);
      return metadata(target);
    },
    async head() {
      throw new Error("No complete-object read is needed for a fresh streamed write");
    },
  };
  await putVerified(bucket, target, assembleMaster(bucket, ranges), true);
  expect(consumed).toBe(691_200_068);
  expect(reads).toBe(83);
  expect(maximumOpen).toBe(1);
  expect(opened).toBe(0);
  expect(maximumChunk).toBeLessThanOrEqual(chunkBytes);
  expect(maximumQueued).toBeLessThan(1_048_576);
  expect(queuedBytes).toBe(0);
  // oxlint-disable-next-line effecttsgo/global-console -- Export attributable resource acceptance measurements.
  console.log(
    `MASTER_UPLOAD_STREAM bytes=${consumed} ranges=${reads} maximumOpen=${maximumOpen} maximumQueued=${maximumQueued} maximumChunk=${maximumChunk}`,
  );
}, 60000);
