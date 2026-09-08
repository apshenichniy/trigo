import { Effect, Schema } from "effect";

import {
  FinalizeMasterUpload,
  VerifiedMasterReceipt,
  parseStored,
  storedByteHash,
  uploadPartBytes,
  validateArchive,
  type CaptureSourceDocument,
} from "@trigo/contracts";

import {
  executeUploadSQL,
  FinalizationRow,
  requireUpload,
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
  const callBytes = new TextEncoder().encode(input.callDocument);
  const audioBytes = new TextEncoder().encode(input.audioManifest);
  const audio = yield* Effect.try({
    try: () => parseStored("AudioManifest", audioBytes),
    catch: () => invalidUpload("The audio manifest is invalid."),
  });
  const archive = yield* Effect.tryPromise({
    try: () => validateArchive(callBytes, new Map([[audio.manifestId, audioBytes]])),
    catch: () => invalidUpload("The closed call and audio manifest do not agree."),
  });
  const call = archive.call;
  const microphone = call.tracks.find((track) => track.role === "microphone");
  const application = call.tracks.find((track) => track.role === "application");
  const source = yield* sourceHash(call.source);
  if (
    call.archiveId !== upload.archive_id ||
    call.callId !== upload.call_id ||
    call.captureState === "recording" ||
    call.durationMs === null ||
    !call.endedAt ||
    call.startedAt !== upload.started_at ||
    source !== upload.source_hash ||
    microphone?.trackId !== upload.microphone_track_id ||
    application?.trackId !== upload.application_track_id ||
    call.revisions.length !== 0 ||
    call.activeRevisionId !== null ||
    audio.mediaProfileId !== "caf-lpcm-s16le-16000-stereo-v1" ||
    Date.parse(call.endedAt) - Date.parse(call.startedAt) !== call.durationMs
  ) {
    return yield* invalidUpload(
      "Finalization must retain the registered call, sources and actual closed duration.",
    );
  }
  const object = audio.objects[0];
  if (
    call.durationMs > 0 &&
    (!object || object.objectId !== upload.master_id || object.sha256 !== input.masterSHA256)
  ) {
    return yield* invalidUpload(
      "The audio manifest must identify the complete registered master and checksum.",
    );
  }
  return {
    durationMs: call.durationMs,
    byteLength: 68 + call.durationMs * 64,
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
  archiveId: string,
  callId: string,
  value: unknown,
) {
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
       SELECT upload_id,?,?,?,? FROM trigo_master_uploads WHERE upload_id=? AND deletion_state='active'`,
      [
        input.operationId,
        requestHash,
        input.audioManifest,
        yield* encodeUploadJSON(receipt),
        upload.upload_id,
      ],
    );
    [finalization] = yield* uploadRows(
      db,
      FinalizationRow,
      "SELECT * FROM trigo_master_finalizations WHERE upload_id=?",
      [upload.upload_id],
    );
  }
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
     AND EXISTS (SELECT 1 FROM trigo_master_uploads u WHERE u.upload_id=trigo_master_finalizations.upload_id AND u.deletion_state='active')`,
    [writer.writer_id, yield* encodeUploadJSON(receipt), upload.upload_id],
  );
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
