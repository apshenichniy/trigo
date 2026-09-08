import { Effect, Schema } from "effect";

import {
  FinalizeMasterUpload,
  VerifiedMasterReceipt,
  parseStored,
  storedByteHash,
  uploadPartBytes,
  type CaptureSourceDocument,
} from "@trigo/contracts";

import type { OwnerContext } from "./owner-state.ts";
import {
  executeUploadSQL,
  FinalizationRow,
  requireUpload,
  requireUploadOwner,
  uploadOwnerFence,
  uploadOwnerParameters,
  uploadRows,
  WriterRow,
  type UploadDatabase,
  type UploadRow,
} from "./upload-catalog.ts";
import {
  decodeUpload,
  encodeUploadJSON,
  incompleteUpload,
  invalidUpload,
  uploadConflict,
  uploadStorage,
} from "./upload-errors.ts";
import { sourceStatesHash } from "./upload-source-states.ts";
import { assembleMaster, type UploadBucket } from "./upload-streams.ts";
import {
  newUploadIdentity,
  recoverStoredWriter,
  storeAdmittedWriter,
  uploadTimestamp,
} from "./upload-writers.ts";

export const textHash = Effect.fn("MasterUpload.hashMetadata")((text: string) =>
  uploadStorage("metadata checksum", () => storedByteHash(new TextEncoder().encode(text))),
);

export const sourceHash = (source: CaptureSourceDocument) =>
  encodeUploadJSON([
    source.applicationName,
    source.bundleId,
    source.processId,
    source.windowId,
    source.windowTitle,
  ]).pipe(Effect.flatMap(textHash));

const decodeFinalReceipt = (text: string) =>
  Schema.decodeEffect(Schema.fromJsonString(VerifiedMasterReceipt))(text).pipe(
    Effect.mapError(() =>
      invalidUpload("The stored final receipt is invalid. Retain local media."),
    ),
  );

const finalManifest = Effect.fn("MasterUpload.validateFinalManifest")(function* (
  upload: UploadRow,
  input: FinalizeMasterUpload,
) {
  const audioBytes = new TextEncoder().encode(input.audioManifest);
  const audio = yield* Effect.try({
    try: () => parseStored("AudioManifest", audioBytes),
    catch: () => invalidUpload("The audio manifest is invalid."),
  });
  // The registered immutable call already owns source and track identities. Closing it
  // supplies only bounded duration/state evidence, never the fragmented canonical JSON.
  if (
    audio.callId !== upload.call_id ||
    audio.durationMs !== input.durationMs ||
    audio.mediaProfileId !== "caf-lpcm-s16le-16000-stereo-v1"
  ) {
    return yield* invalidUpload(
      "Finalization must retain the registered call, sources and actual closed duration.",
    );
  }
  const object = audio.objects[0];
  if (
    input.durationMs > 0 &&
    (!object ||
      object.objectId !== upload.master_id ||
      object.sha256 !== input.masterSHA256 ||
      !object.channelMap.some(
        (channel) => channel.channelIndex === 0 && channel.trackId === upload.microphone_track_id,
      ) ||
      !object.channelMap.some(
        (channel) => channel.channelIndex === 1 && channel.trackId === upload.application_track_id,
      ))
  ) {
    return yield* invalidUpload(
      "The audio manifest must identify the complete registered master and checksum.",
    );
  }
  return {
    durationMs: input.durationMs,
    byteLength: 68 + input.durationMs * 64,
    sourceStatesSHA256: yield* sourceStatesHash(input),
    audioManifest: { manifestId: audio.manifestId, sha256: yield* textHash(input.audioManifest) },
  };
});

const completedRanges = Effect.fn("MasterUpload.completedRanges")(function* (
  db: UploadDatabase,
  uploadId: string,
  byteLength: number,
) {
  const ranges = yield* uploadRows(
    db,
    WriterRow,
    `SELECT w.* FROM trigo_upload_parts p
     JOIN trigo_upload_writers w ON w.writer_id=p.writer_id
     WHERE p.upload_id=? AND w.state='stored'
     ORDER BY p.part_index LIMIT 84`,
    [uploadId],
  );
  if (ranges.length !== Math.ceil(byteLength / uploadPartBytes)) {
    return yield* incompleteUpload();
  }
  for (const [index, range] of ranges.entries()) {
    if (
      range.part_index !== index ||
      range.byte_length !== Math.min(uploadPartBytes, byteLength - index * uploadPartBytes)
    ) {
      return yield* incompleteUpload();
    }
  }
  // Also reject admitted excess/partial identities; they must not disappear from the manifest.
  const counts = yield* uploadRows(
    db,
    Schema.Struct({ count: Schema.Int }),
    "SELECT count(*) AS count FROM trigo_upload_parts WHERE upload_id=?",
    [uploadId],
  );
  if (counts[0]?.count !== ranges.length) {
    return yield* incompleteUpload();
  }
  return ranges;
});

export const finalizeMaster = Effect.fn("MasterUpload.finalize")(function* (
  db: UploadDatabase,
  bucket: UploadBucket,
  owner: OwnerContext,
  callId: string,
  value: unknown,
) {
  const { archiveId } = owner;
  yield* requireUploadOwner(db, owner);
  const input = yield* decodeUpload(FinalizeMasterUpload, value);
  const upload = yield* requireUpload(db, archiveId, callId, input.uploadId);
  const manifest = yield* finalManifest(upload, input);
  const requestHash = yield* encodeUploadJSON(input).pipe(Effect.flatMap(textHash));
  let [finalization] = yield* uploadRows(
    db,
    FinalizationRow,
    "SELECT * FROM trigo_master_finalizations WHERE upload_id=?",
    [upload.upload_id],
  );
  if (!finalization) {
    yield* completedRanges(db, upload.upload_id, manifest.byteLength);
    const receipt: VerifiedMasterReceipt = {
      schemaVersion: 1,
      archiveId,
      callId,
      masterId: upload.master_id,
      uploadId: upload.upload_id,
      operationId: input.operationId,
      receiptId: yield* newUploadIdentity(),
      verification: "complete-master-sha256-v1",
      mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
      masterSHA256: input.masterSHA256,
      ...manifest,
      channelMap: [
        { channelIndex: 0, trackId: upload.microphone_track_id },
        { channelIndex: 1, trackId: upload.application_track_id },
      ],
      storedAt: yield* uploadTimestamp(),
    };
    yield* executeUploadSQL(
      db,
      `INSERT OR IGNORE INTO trigo_master_finalizations
       (upload_id,operation_id,request_hash,audio_manifest,receipt)
       SELECT upload_id,?,?,?,? FROM trigo_master_uploads WHERE upload_id=? AND deletion_state='active'
       AND ${uploadOwnerFence}`,
      [
        input.operationId,
        requestHash,
        input.audioManifest,
        yield* encodeUploadJSON(receipt),
        upload.upload_id,
        ...uploadOwnerParameters(owner),
      ],
    );
    [finalization] = yield* uploadRows(
      db,
      FinalizationRow,
      "SELECT * FROM trigo_master_finalizations WHERE upload_id=?",
      [upload.upload_id],
    );
  }
  yield* requireUploadOwner(db, owner);
  yield* requireUpload(db, archiveId, callId, input.uploadId);
  if (
    !finalization ||
    finalization.operation_id !== input.operationId ||
    finalization.request_hash !== requestHash
  ) {
    return yield* uploadConflict(
      "A different finalization already owns this call or operation identity.",
    );
  }
  if (finalization.writer_id !== null) {
    return yield* decodeFinalReceipt(finalization.receipt);
  }
  let writer = yield* recoverStoredWriter(db, bucket, upload.upload_id, "master", null);
  if (!writer) {
    const ranges = yield* completedRanges(db, upload.upload_id, manifest.byteLength);
    writer = yield* storeAdmittedWriter(
      db,
      bucket,
      owner,
      upload,
      "master",
      null,
      manifest.byteLength,
      input.masterSHA256,
      assembleMaster(bucket, ranges),
    );
  }
  const receipt = {
    ...(yield* decodeFinalReceipt(finalization.receipt)),
    storedAt: yield* uploadTimestamp(),
  };
  yield* executeUploadSQL(
    db,
    `UPDATE trigo_master_finalizations SET writer_id=?,receipt=? WHERE upload_id=? AND writer_id IS NULL
     AND EXISTS (SELECT 1 FROM trigo_master_uploads u WHERE u.upload_id=trigo_master_finalizations.upload_id AND u.deletion_state='active')
     AND ${uploadOwnerFence}`,
    [
      writer.writer_id,
      yield* encodeUploadJSON(receipt),
      upload.upload_id,
      ...uploadOwnerParameters(owner),
    ],
  );
  yield* requireUploadOwner(db, owner);
  const stored = yield* storedMaster(db, archiveId, callId);
  return stored.receipt;
});

/** #18 and #73 consume this authenticated, deletion-fenced complete-master pointer. */
export const storedMaster = Effect.fn("MasterUpload.storedMaster")(function* (
  db: UploadDatabase,
  archiveId: string,
  callId: string,
) {
  const upload = yield* requireUpload(db, archiveId, callId);
  const [finalization] = yield* uploadRows(
    db,
    FinalizationRow,
    "SELECT * FROM trigo_master_finalizations WHERE upload_id=? AND writer_id IS NOT NULL",
    [upload.upload_id],
  );
  if (!finalization) {
    return yield* incompleteUpload();
  }
  const [writer] = yield* uploadRows(
    db,
    WriterRow,
    "SELECT * FROM trigo_upload_writers WHERE writer_id=? AND state='stored' AND kind='master'",
    [finalization.writer_id],
  );
  if (!writer) {
    return yield* incompleteUpload();
  }
  return {
    receipt: yield* decodeFinalReceipt(finalization.receipt),
    objectKey: writer.object_key,
    audioManifest: finalization.audio_manifest,
  };
});
