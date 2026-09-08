import { Context, Effect, Layer } from "effect";

import {
  MasterUploadSession,
  RegisterMasterUpload,
  UploadPartDescriptor,
  UploadPartReceipt,
  parseStored,
  uploadPartBytes,
  type VerifiedMasterReceipt,
} from "@trigo/contracts";

import { finalizeMaster, sourceHash, textHash } from "./master-finalization.ts";
import { type OwnerContext } from "./owner-state.ts";
import {
  executeUploadSQL,
  PartRow,
  requireUpload,
  uploadRows,
  type UploadDatabase,
  type UploadRow,
} from "./upload-catalog.ts";
import {
  decodeUpload,
  encodeUploadJSON,
  invalidUpload,
  uploadConflict,
  uploadStorage,
  type UploadError,
} from "./upload-errors.ts";
import { verifyRepeatedBody, type UploadBucket } from "./upload-streams.ts";
import { newUploadIdentity, recoverStoredWriter, storeAdmittedWriter } from "./upload-writers.ts";

export interface MasterUploadEnvironment {
  readonly CATALOG: UploadDatabase;
  readonly ARCHIVE: UploadBucket;
}

function sessionReceipt(upload: UploadRow): MasterUploadSession {
  return {
    schemaVersion: 1,
    archiveId: upload.archive_id,
    callId: upload.call_id,
    masterId: upload.master_id,
    uploadId: upload.upload_id,
    partBytes: uploadPartBytes,
    mediaProfileId: "caf-lpcm-s16le-16000-stereo-v1",
  };
}

const registerMaster = Effect.fn("MasterUpload.register")(function* (
  db: UploadDatabase,
  archiveId: string,
  value: unknown,
) {
  const input = yield* decodeUpload(RegisterMasterUpload, value);
  const call = yield* Effect.try({
    try: () => parseStored("CallDocument", new TextEncoder().encode(input.callDocument)),
    catch: () => invalidUpload("The initial call document is invalid."),
  });
  const microphone = call.tracks.find((track) => track.role === "microphone");
  const application = call.tracks.find((track) => track.role === "application");
  if (
    call.archiveId !== archiveId ||
    call.captureState !== "recording" ||
    call.documentVersion !== 1 ||
    call.audioManifest !== null ||
    call.revisions.length !== 0 ||
    !microphone ||
    !application ||
    call.tracks.some(
      (track) =>
        track.mediaProfileId !== "caf-lpcm-s16le-16000-stereo-v1" || track.intervals.length !== 0,
    )
  ) {
    return yield* invalidUpload(
      "Register the original local call and its two capture-master tracks in the bound archive.",
    );
  }
  const hash = yield* encodeUploadJSON(input).pipe(Effect.flatMap(textHash));
  if (
    new Set([call.callId, input.masterId, input.uploadId, microphone.trackId, application.trackId])
      .size !== 5
  ) {
    return yield* invalidUpload(
      "Call, master, upload and source tracks require independent identities.",
    );
  }
  const source = yield* sourceHash(call.source);
  yield* executeUploadSQL(
    db,
    `INSERT OR IGNORE INTO trigo_master_uploads
     (call_id,archive_id,upload_id,master_id,registration_hash,microphone_track_id,application_track_id,started_at,source_hash)
     VALUES (?,?,?,?,?,?,?,?,?)`,
    [
      call.callId,
      archiveId,
      input.uploadId,
      input.masterId,
      hash,
      microphone.trackId,
      application.trackId,
      call.startedAt,
      source,
    ],
  );
  const upload = yield* requireUpload(db, archiveId, call.callId);
  if (upload.registration_hash !== hash) {
    return yield* uploadConflict(
      "This call is already registered with different content or upload identities.",
    );
  }
  return sessionReceipt(upload);
});

function partReceipt(upload: UploadRow, part: PartRow): UploadPartReceipt {
  return {
    schemaVersion: 1,
    archiveId: upload.archive_id,
    callId: upload.call_id,
    uploadId: upload.upload_id,
    masterId: upload.master_id,
    receiptId: part.receipt_id,
    index: part.part_index,
    byteOffset: part.part_index * uploadPartBytes,
    byteLength: part.byte_length,
    sha256: part.sha256,
  };
}

const putPart = Effect.fn("MasterUpload.putPart")(function* (
  env: MasterUploadEnvironment,
  archiveId: string,
  callId: string,
  uploadId: string,
  descriptor: unknown,
  body: ReadableStream<Uint8Array>,
) {
  const input = yield* decodeUpload(UploadPartDescriptor, descriptor);
  if (
    input.byteOffset !== input.index * uploadPartBytes ||
    input.byteOffset + input.byteLength > 691_200_068
  ) {
    return yield* invalidUpload("The range must use the registered fixed transport boundaries.");
  }
  const upload = yield* requireUpload(env.CATALOG, archiveId, callId, uploadId);
  const receiptId = yield* newUploadIdentity();
  yield* executeUploadSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_upload_parts (upload_id,part_index,byte_length,sha256,receipt_id)
     SELECT upload_id,?,?,?,? FROM trigo_master_uploads u WHERE upload_id=? AND deletion_state='active'
     AND NOT EXISTS (SELECT 1 FROM trigo_master_finalizations f WHERE f.upload_id=u.upload_id)`,
    [input.index, input.byteLength, input.sha256, receiptId, uploadId],
  );
  const [part] = yield* uploadRows(
    env.CATALOG,
    PartRow,
    "SELECT * FROM trigo_upload_parts WHERE upload_id=? AND part_index=?",
    [uploadId, input.index],
  );
  if (!part || part.byte_length !== input.byteLength || part.sha256 !== input.sha256) {
    yield* requireUpload(env.CATALOG, archiveId, callId, uploadId);
    return yield* uploadConflict(
      "The part identity is sealed or already contains different content.",
    );
  }
  let writer =
    part.writer_id === null
      ? yield* recoverStoredWriter(env.CATALOG, env.ARCHIVE, uploadId, "part", input.index)
      : undefined;
  if (part.writer_id !== null || writer) {
    // Even a duplicate body must match its declaration; a claimed SHA is not trusted content.
    yield* uploadStorage("duplicate body verification", () =>
      verifyRepeatedBody(body, input.byteLength, input.sha256),
    );
  } else {
    writer = yield* storeAdmittedWriter(
      env.CATALOG,
      env.ARCHIVE,
      upload,
      "part",
      input.index,
      input.byteLength,
      input.sha256,
      body,
    );
  }
  if (writer) {
    yield* executeUploadSQL(
      env.CATALOG,
      `UPDATE trigo_upload_parts SET writer_id=? WHERE upload_id=? AND part_index=? AND writer_id IS NULL
       AND EXISTS (SELECT 1 FROM trigo_master_uploads u WHERE u.upload_id=trigo_upload_parts.upload_id AND u.deletion_state='active')`,
      [writer.writer_id, uploadId, input.index],
    );
  }
  yield* requireUpload(env.CATALOG, archiveId, callId, uploadId);
  return partReceipt(upload, part);
});

export class MasterUploads extends Context.Service<
  MasterUploads,
  {
    readonly register: (input: unknown) => Effect.Effect<MasterUploadSession, UploadError>;
    readonly part: (
      callId: string,
      uploadId: string,
      descriptor: unknown,
      body: ReadableStream<Uint8Array>,
    ) => Effect.Effect<UploadPartReceipt, UploadError>;
    readonly finalize: (
      callId: string,
      input: unknown,
    ) => Effect.Effect<VerifiedMasterReceipt, UploadError>;
  }
>()("trigo/MasterUploads") {}

export const masterUploadsLayer = (env: MasterUploadEnvironment, owner: OwnerContext) =>
  Layer.effect(
    MasterUploads,
    Effect.sync(() => {
      return MasterUploads.of({
        register: (input) => registerMaster(env.CATALOG, owner.archiveId, input),
        part: (callId, uploadId, descriptor, body) =>
          putPart(env, owner.archiveId, callId, uploadId, descriptor, body),
        finalize: (callId, input) =>
          finalizeMaster(env.CATALOG, env.ARCHIVE, owner.archiveId, callId, input),
      });
    }),
  );
