import { DateTime, Effect, Schema } from "effect";

import {
  ExchangeUUID,
  PositiveInteger,
  SHA256,
  UTCDateTime,
  type ReplicaReceipt,
  type ReplicaReference,
} from "@trigo/contracts";

import { type OwnerContext } from "./owner-state.ts";
import { syncError, syncStorage } from "./sync-errors.ts";
import { requireUpload, requireUploadOwner, type UploadDatabase } from "./upload-catalog.ts";

export const ReplicaRow = Schema.Struct({
  operation_id: ExchangeUUID,
  archive_id: ExchangeUUID,
  call_id: ExchangeUUID,
  owner_generation: PositiveInteger,
  command_hash: SHA256,
  document_version: PositiveInteger,
  schema_version: Schema.Literals([1, 2]),
  sha256: SHA256,
  byte_length: PositiveInteger,
  expected_version: Schema.NullOr(PositiveInteger),
  object_key: Schema.NullOr(Schema.String),
  writer_id: Schema.NullOr(ExchangeUUID),
  state: Schema.Literals(["admitted", "published"]),
  created_at: UTCDateTime,
  published_at: Schema.NullOr(UTCDateTime),
});
export interface ReplicaRow extends Schema.Schema.Type<typeof ReplicaRow> {}

export const ReplicaWriterRow = Schema.Struct({
  writer_id: ExchangeUUID,
  operation_id: ExchangeUUID,
  object_key: Schema.String,
  sha256: SHA256,
  byte_length: PositiveInteger,
  state: Schema.Literals(["admitted", "uncertain", "stored"]),
  created_at: UTCDateTime,
});
export interface ReplicaWriterRow extends Schema.Schema.Type<typeof ReplicaWriterRow> {}

type Parameter = string | number | null;
export const syncRows = Effect.fn("SyncCatalog.read")(function* <
  S extends Schema.ConstraintDecoder<unknown>,
>(db: UploadDatabase, schema: S, sql: string, parameters: readonly Parameter[] = []) {
  const result = yield* syncStorage(() =>
    db
      .prepare(sql)
      .bind(...parameters)
      .all(),
  );
  const rows: unknown = result.results;
  return yield* Schema.decodeUnknownEffect(Schema.Array(schema))(rows).pipe(
    Effect.mapError(() => syncError("sync_catalog_invalid", 503)),
  );
});

export const executeSyncSQL = Effect.fn("SyncCatalog.execute")(
  (db: UploadDatabase, sql: string, parameters: readonly Parameter[] = []) =>
    syncStorage(() =>
      db
        .prepare(sql)
        .bind(...parameters)
        .run(),
    ),
);

export const syncTimestamp = Effect.fn("Sync.timestamp")(function* () {
  return DateTime.formatIso(yield* DateTime.now);
});
export const newReplicaIdentity = Effect.fn("Sync.identity")(() =>
  // oxlint-disable-next-line effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Durable independent identities are allocated at the service boundary.
  Effect.sync(() => crypto.randomUUID()),
);

export const requireSyncOwner = Effect.fn("SyncCatalog.owner")(
  (db: UploadDatabase, owner: OwnerContext) =>
    requireUploadOwner(db, owner).pipe(
      Effect.mapError((error) =>
        error.status === 401
          ? syncError("sync_owner_changed", 401)
          : syncError("sync_storage_unavailable", 503, "retryable"),
      ),
    ),
);

export const syncCallFence =
  "EXISTS(SELECT 1 FROM trigo_master_uploads u WHERE u.call_id=? AND u.archive_id=? AND u.deletion_state='active') AND NOT EXISTS(SELECT 1 FROM trigo_call_deletion_markers d WHERE d.call_id=?)";
export const syncCallParameters = (owner: OwnerContext, callId: string) => [
  callId,
  owner.archiveId,
  callId,
];

export const requireSyncCall = Effect.fn("SyncCatalog.call")(function* (
  db: UploadDatabase,
  owner: OwnerContext,
  callId: string,
) {
  yield* requireSyncOwner(db, owner);
  const markers = yield* syncRows(
    db,
    Schema.Struct({ call_id: ExchangeUUID }),
    "SELECT call_id FROM trigo_call_deletion_markers WHERE call_id=?",
    [callId],
  );
  if (markers.length > 0) {
    return yield* syncError("call_deleted", 410, "never");
  }
  return yield* requireUpload(db, owner.archiveId, callId).pipe(
    Effect.mapError((error) => {
      if (error.code === "call_deleted") {
        return syncError("call_deleted", 410, "never");
      }
      if (error.status === 404) {
        return syncError("sync_not_found", 404);
      }
      return syncError("sync_storage_unavailable", 503, "retryable");
    }),
  );
});

export const currentReplica = Effect.fn("SyncCatalog.current")(function* (
  db: UploadDatabase,
  owner: OwnerContext,
  callId: string,
) {
  const [row] = yield* syncRows(
    db,
    ReplicaRow,
    "SELECT * FROM trigo_replica_operations WHERE archive_id=? AND call_id=? AND state='published' ORDER BY document_version DESC LIMIT 1",
    [owner.archiveId, callId],
  );
  return row ?? null;
});

export const replicaReference = (row: ReplicaRow): ReplicaReference => ({
  documentVersion: row.document_version,
  schemaVersion: row.schema_version,
  sha256: row.sha256,
  byteLength: row.byte_length,
});

export const replicaReceipt = (row: ReplicaRow) => {
  if (
    row.state !== "published" ||
    row.published_at === null ||
    row.object_key === null ||
    row.writer_id === null
  ) {
    return Effect.fail(syncError("sync_catalog_invalid", 503));
  }
  const receipt: ReplicaReceipt = {
    schemaVersion: 1,
    operationId: row.operation_id,
    archiveId: row.archive_id,
    callId: row.call_id,
    documentVersion: row.document_version,
    sha256: row.sha256,
    byteLength: row.byte_length,
    publishedAt: row.published_at,
  };
  return Effect.succeed(receipt);
};
