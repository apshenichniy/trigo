import { Effect, Schema } from "effect";

import { ExchangeUUID, SHA256 } from "@trigo/contracts";

import { fencedUpload, UploadError, uploadStorage } from "./upload-errors.ts";

export type UploadDatabase = Pick<D1Database, "prepare">;
type Parameter = string | number | null;

export const UploadRow = Schema.Struct({
  call_id: ExchangeUUID,
  archive_id: ExchangeUUID,
  upload_id: ExchangeUUID,
  master_id: ExchangeUUID,
  registration_hash: SHA256,
  microphone_track_id: ExchangeUUID,
  application_track_id: ExchangeUUID,
  started_at: Schema.String,
  source_hash: SHA256,
  deletion_state: Schema.Literals(["active", "fenced"]),
});
export interface UploadRow extends Schema.Schema.Type<typeof UploadRow> {}

export const PartRow = Schema.Struct({
  upload_id: ExchangeUUID,
  part_index: Schema.Int,
  byte_length: Schema.Int,
  sha256: SHA256,
  receipt_id: ExchangeUUID,
  writer_id: Schema.NullOr(ExchangeUUID),
});
export interface PartRow extends Schema.Schema.Type<typeof PartRow> {}

export const WriterRow = Schema.Struct({
  writer_id: ExchangeUUID,
  upload_id: ExchangeUUID,
  kind: Schema.Literals(["part", "master"]),
  part_index: Schema.NullOr(Schema.Int),
  object_key: Schema.String,
  byte_length: Schema.Int,
  sha256: SHA256,
  state: Schema.Literals(["admitted", "uncertain", "stored"]),
  admitted_at: Schema.String,
});
export interface WriterRow extends Schema.Schema.Type<typeof WriterRow> {}

export const FinalizationRow = Schema.Struct({
  upload_id: ExchangeUUID,
  operation_id: ExchangeUUID,
  request_hash: SHA256,
  audio_manifest: Schema.String,
  receipt: Schema.String,
  writer_id: Schema.NullOr(ExchangeUUID),
});
export interface FinalizationRow extends Schema.Schema.Type<typeof FinalizationRow> {}

export const executeUploadSQL = Effect.fn("UploadCatalog.execute")(
  (db: UploadDatabase, sql: string, parameters: readonly Parameter[] = []) =>
    uploadStorage("catalog write", () =>
      db
        .prepare(sql)
        .bind(...parameters)
        .run(),
    ),
);

export const uploadRows = Effect.fn("UploadCatalog.read")(function* <
  S extends Schema.ConstraintDecoder<unknown>,
>(db: UploadDatabase, schema: S, sql: string, parameters: readonly Parameter[] = []) {
  const result = yield* uploadStorage("catalog read", () =>
    db
      .prepare(sql)
      .bind(...parameters)
      .all(),
  );
  const persisted: unknown = result.results;
  return yield* Schema.decodeUnknownEffect(Schema.Array(schema))(persisted).pipe(
    Effect.mapError(
      () =>
        new UploadError({
          status: 503,
          code: "upload_catalog_invalid",
          retry: "after_correction",
          message: "Upload catalog data could not be validated. Retain local media.",
        }),
    ),
  );
});

export const requireUpload = Effect.fn("UploadCatalog.requireActive")(function* (
  db: UploadDatabase,
  archiveId: string,
  callId: string,
  uploadId?: string,
) {
  const [row] = yield* uploadRows(
    db,
    UploadRow,
    "SELECT * FROM trigo_master_uploads WHERE archive_id=? AND call_id=?",
    [archiveId, callId],
  );
  if (!row || (uploadId !== undefined && row.upload_id !== uploadId)) {
    return yield* new UploadError({
      status: 404,
      code: "upload_not_found",
      retry: "after_correction",
      message: "Register this call and its master upload first.",
    });
  }
  if (row.deletion_state !== "active") {
    return yield* fencedUpload();
  }
  return row;
});

/** Internal #22 seam: this atomic fence precedes draining and object deletion. */
export const fenceMasterUploads = Effect.fn("UploadCatalog.fence")(function* (
  db: UploadDatabase,
  archiveId: string,
  callId: string,
) {
  yield* executeUploadSQL(
    db,
    "UPDATE trigo_master_uploads SET deletion_state='fenced' WHERE archive_id=? AND call_id=?",
    [archiveId, callId],
  );
});

/** Keyset paging includes admitted writers even when their HTTP acknowledgement was lost. */
export const inspectUploadWriters = Effect.fn("UploadCatalog.inspectWriters")(
  (db: UploadDatabase, uploadId: string, after = "") =>
    uploadRows(
      db,
      WriterRow,
      "SELECT * FROM trigo_upload_writers WHERE upload_id=? AND writer_id>? ORDER BY writer_id LIMIT 128",
      [uploadId, after],
    ),
);
