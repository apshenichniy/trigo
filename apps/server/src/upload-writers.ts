import { DateTime, Effect } from "effect";

import type { OwnerContext } from "./owner-state.ts";
import {
  executeUploadSQL,
  requireUpload,
  requireUploadOwner,
  uploadOwnerFence,
  uploadOwnerParameters,
  uploadRows,
  WriterRow,
  type UploadDatabase,
  type UploadRow,
} from "./upload-catalog.ts";
import { uploadConflict, uploadStorage } from "./upload-errors.ts";
import { objectMatches, putVerified, type UploadBucket } from "./upload-streams.ts";

export const newUploadIdentity = Effect.fn("MasterUpload.newIdentity")(() =>
  // oxlint-disable-next-line effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Random is not cryptographically secure; immutable object identities use Web Crypto.
  Effect.sync(() => crypto.randomUUID()),
);

export const uploadTimestamp = Effect.fn("MasterUpload.timestamp")(function* () {
  return DateTime.formatIso(yield* DateTime.now);
});

export const reconcileWriter = Effect.fn("UploadWriter.reconcile")(function* (
  db: UploadDatabase,
  bucket: UploadBucket,
  writer: WriterRow,
) {
  const object = yield* uploadStorage("write reconciliation", () => bucket.head(writer.object_key));
  if (!object || !objectMatches(object, writer)) {
    // Absence never proves an admitted PUT has stopped; #22 must keep draining.
    return false;
  }
  yield* executeUploadSQL(db, "UPDATE trigo_upload_writers SET state='stored' WHERE writer_id=?", [
    writer.writer_id,
  ]);
  return true;
});

export const recoverStoredWriter = Effect.fn("UploadWriter.recover")(function* (
  db: UploadDatabase,
  bucket: UploadBucket,
  uploadId: string,
  kind: "part" | "master",
  index: number | null,
) {
  let after = "";
  while (true) {
    const writers = yield* uploadRows(
      db,
      WriterRow,
      `SELECT * FROM trigo_upload_writers
       WHERE upload_id=? AND kind=? AND part_index IS ? AND writer_id>?
       ORDER BY writer_id LIMIT 32`,
      [uploadId, kind, index, after],
    );
    for (const writer of writers) {
      if (yield* reconcileWriter(db, bucket, writer)) {
        return writer;
      }
      after = writer.writer_id;
    }
    if (writers.length < 32) {
      return undefined;
    }
  }
});

/** A row authorizes exactly this invocation's PUT. Retries allocate another immutable key. */
export const storeAdmittedWriter = Effect.fn("UploadWriter.store")(function* (
  db: UploadDatabase,
  bucket: UploadBucket,
  owner: OwnerContext,
  upload: UploadRow,
  kind: "part" | "master",
  index: number | null,
  byteLength: number,
  sha256: string,
  body: ReadableStream<Uint8Array>,
) {
  const writerId = yield* newUploadIdentity();
  const key = `calls/${upload.archive_id}/${upload.call_id}/uploads/${upload.upload_id}/${writerId}`;
  const admittedAt = yield* uploadTimestamp();
  const result = yield* executeUploadSQL(
    db,
    `INSERT INTO trigo_upload_writers
     (writer_id,upload_id,kind,part_index,object_key,byte_length,sha256,state,admitted_at)
     SELECT ?,upload_id,?,?,?,?,?,'admitted',? FROM trigo_master_uploads u
     WHERE upload_id=? AND deletion_state='active' AND ${uploadOwnerFence} AND (
       (?='part' AND NOT EXISTS (SELECT 1 FROM trigo_master_finalizations f WHERE f.upload_id=u.upload_id)) OR
       (?='master' AND EXISTS (SELECT 1 FROM trigo_master_finalizations f WHERE f.upload_id=u.upload_id AND f.writer_id IS NULL))
     )`,
    [
      writerId,
      kind,
      index,
      key,
      byteLength,
      sha256,
      admittedAt,
      upload.upload_id,
      ...uploadOwnerParameters(owner),
      kind,
      kind,
    ],
  );
  if (result.meta.changes !== 1) {
    yield* requireUploadOwner(db, owner);
    yield* requireUpload(db, upload.archive_id, upload.call_id, upload.upload_id);
    return yield* uploadConflict(
      "Finalization has already sealed this upload. Replay its existing operation.",
    );
  }
  const writer: WriterRow = {
    writer_id: writerId,
    upload_id: upload.upload_id,
    kind,
    part_index: index,
    object_key: key,
    byte_length: byteLength,
    sha256,
    state: "admitted",
    admitted_at: admittedAt,
  };
  yield* uploadStorage("object write", () =>
    putVerified(bucket, writer, body, kind === "master"),
  ).pipe(
    Effect.tapError(() =>
      executeUploadSQL(db, "UPDATE trigo_upload_writers SET state='uncertain' WHERE writer_id=?", [
        writerId,
      ]).pipe(Effect.ignore),
    ),
  );
  // Record completion even if deletion fenced the call while the external PUT was active.
  yield* executeUploadSQL(db, "UPDATE trigo_upload_writers SET state='stored' WHERE writer_id=?", [
    writerId,
  ]);
  return writer;
});
