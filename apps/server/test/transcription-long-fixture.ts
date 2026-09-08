/* oxlint-disable effecttsgo/async-function -- This isolated Worker storage fixture implements native SDK callbacks. */
import { createHash } from "node:crypto";

import { env } from "cloudflare:workers";
import { vi } from "vitest";

import { storedByteHash, validateDocument } from "@trigo/contracts";

import { type TranscriptionExecutionEnvironment } from "../src/transcription-submissions.ts";
import { cafMasterHeader } from "../src/upload-streams.ts";
import { createUploadedCall } from "./transcription-fixture.ts";

/** Only this isolated test replaces a completed one-second witness with deterministic virtual
 * ranges. It exercises the real production extraction and orchestration without writing 691 MB
 * per test. Real retained long-master/provider acceptance remains the separate hosted gate. */
export async function createVirtualLongCall(runtime: TranscriptionExecutionEnvironment) {
  const fixture = await createUploadedCall(runtime);
  const durationMs = 10_800_000;
  const byteLength = 68 + durationMs * 64;
  const digest = createHash("sha256").update(cafMasterHeader);
  const zeroes = new Uint8Array(2_097_152);
  for (let remaining = byteLength - 68; remaining > 0; remaining -= zeroes.byteLength) {
    digest.update(zeroes.subarray(0, Math.min(remaining, zeroes.byteLength)));
  }
  const sha256 = digest.digest("hex");
  const finalization = await env.CATALOG.prepare(
    "SELECT audio_manifest FROM trigo_master_finalizations WHERE upload_id=?",
  )
    .bind(fixture.uploadId)
    .first<{ audio_manifest: string }>();
  if (!finalization) {
    throw new Error("Missing completed fixture");
  }
  const audio = validateDocument("AudioManifest", JSON.parse(finalization.audio_manifest));
  const audioManifest = JSON.stringify({
    ...audio,
    durationMs,
    objects: audio.objects.map((object) => ({ ...object, byteLength, sha256, endMs: durationMs })),
  });
  const receipt = {
    // oxlint-disable-next-line typescript/no-misused-spread -- The upload service returns a plain exchange receipt, not a runtime class.
    ...fixture.receipt,
    durationMs,
    byteLength,
    masterSHA256: sha256,
    audioManifest: {
      manifestId: audio.manifestId,
      sha256: await storedByteHash(new TextEncoder().encode(audioManifest)),
    },
  };
  await env.CATALOG.prepare(
    "UPDATE trigo_master_finalizations SET audio_manifest=?,receipt=? WHERE upload_id=?",
  )
    .bind(audioManifest, JSON.stringify(receipt), fixture.uploadId)
    .run();
  await env.CATALOG.prepare(
    "UPDATE trigo_upload_writers SET byte_length=?,sha256=? WHERE upload_id=? AND kind='master'",
  )
    .bind(byteLength, sha256, fixture.uploadId)
    .run();
  const writer = await env.CATALOG.prepare(
    "SELECT object_key FROM trigo_upload_writers WHERE upload_id=? AND kind='master' AND state='stored'",
  )
    .bind(fixture.uploadId)
    .first<{ object_key: string }>();
  if (!writer) {
    throw new Error("Missing stored master writer");
  }
  const get = runtime.ARCHIVE.get.bind(runtime.ARCHIVE);
  const template = await get(writer.object_key);
  if (!template || !("body" in template)) {
    throw new Error("Missing fixture master");
  }
  await template.body.cancel();
  vi.spyOn(runtime.ARCHIVE, "get").mockImplementation(async (key, options) => {
    if (key !== writer.object_key) {
      return get(key, options);
    }
    const range = options?.range;
    if (
      !range ||
      !("offset" in range) ||
      !("length" in range) ||
      typeof range.offset !== "number" ||
      typeof range.length !== "number"
    ) {
      throw new Error("Long fixture only supports exact bounded ranges");
    }
    const bytes = new Uint8Array(range.length);
    if (range.offset < 68) {
      bytes.set(cafMasterHeader.subarray(range.offset, Math.min(68, range.offset + range.length)));
    }
    return {
      ...template,
      size: byteLength,
      etag: "virtual-three-hour-master",
      body: new Response(bytes).body!,
      writeHttpMetadata: (headers: Headers) => template.writeHttpMetadata(headers),
    };
  });
  return { ...fixture, receipt };
}
