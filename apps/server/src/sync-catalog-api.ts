import { Effect, Schema } from "effect";

import {
  CallDeletionMarker,
  ExchangeUUID,
  VerifiedMasterReceipt,
  type CallCatalogEntry,
  type CallCatalogPage,
  type CallChangesPage,
  type TranscriptResultsPage,
} from "@trigo/contracts";

import { type MasterUploadEnvironment } from "./master-uploads.ts";
import { type OwnerContext } from "./owner-state.ts";
import { syncStoredMaster } from "./replica-documents.ts";
import {
  currentReplica,
  replicaReference,
  requireSyncCall,
  requireSyncOwner,
  syncRows,
} from "./sync-catalog.ts";
import {
  CatalogCursor,
  ChangesCursor,
  ResultsCursor,
  cursorState,
  decodeSyncCursor,
  encodeSyncCursor,
  retainedCursor,
} from "./sync-cursors.ts";
import { syncError } from "./sync-errors.ts";
import { operationDocument, TranscriptionRow, transcriptionRows } from "./transcription-catalog.ts";

export const syncPageSize = 32;

const catalogEntry = Effect.fn("SyncCatalog.entry")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
) {
  const [marker] = yield* syncRows(
    env.CATALOG,
    Schema.Struct({
      call_id: ExchangeUUID,
      marked_at: Schema.String,
      phase: CallDeletionMarker.fields.phase,
    }),
    "SELECT call_id,marked_at,phase FROM trigo_call_deletion_markers WHERE archive_id=? AND call_id=?",
    [owner.archiveId, callId],
  );
  if (marker) {
    const entry: CallCatalogEntry = {
      callId,
      replica: null,
      audio: null,
      latestTranscriptionOperationId: null,
      resultCount: 0,
      deletion: { callId, markedAt: marker.marked_at, phase: marker.phase },
    };
    return entry;
  }
  const [row] = yield* syncRows(
    env.CATALOG,
    Schema.Struct({
      receipt: Schema.NullOr(Schema.String),
      latest_operation: Schema.NullOr(ExchangeUUID),
      result_count: Schema.Int,
    }),
    `SELECT f.receipt,
      (SELECT operation_id FROM trigo_transcription_operations t WHERE t.call_id=u.call_id ORDER BY generation DESC LIMIT 1) AS latest_operation,
      (SELECT COUNT(*) FROM trigo_transcription_operations t WHERE t.call_id=u.call_id AND state='result_available') AS result_count
     FROM trigo_master_uploads u LEFT JOIN trigo_master_finalizations f ON f.upload_id=u.upload_id
     WHERE u.archive_id=? AND u.call_id=? AND u.deletion_state='active'`,
    [owner.archiveId, callId],
  );
  if (!row) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  const audio =
    row.receipt === null
      ? null
      : yield* Schema.decodeEffect(Schema.fromJsonString(VerifiedMasterReceipt))(row.receipt).pipe(
          Effect.mapError(() => syncError("sync_catalog_invalid", 503)),
        );
  if (audio && (audio.callId !== callId || audio.archiveId !== owner.archiveId)) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  const replica = yield* currentReplica(env.CATALOG, owner, callId);
  const entry: CallCatalogEntry = {
    callId,
    replica: replica === null ? null : replicaReference(replica),
    audio,
    latestTranscriptionOperationId: row.latest_operation,
    resultCount: row.result_count,
    deletion: null,
  };
  return entry;
});

export const getCallCatalog = Effect.fn("SyncCatalog.page")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  cursor?: string,
) {
  yield* requireSyncOwner(env.CATALOG, owner);
  const state = yield* cursorState(env.CATALOG, owner.archiveId);
  let after = "";
  let watermark = state.last_sequence;
  if (cursor !== undefined) {
    const value = yield* decodeSyncCursor(CatalogCursor, cursor);
    if (
      value.epoch !== state.epoch ||
      value.archiveId !== owner.archiveId ||
      !retainedCursor(value.watermark, state)
    ) {
      return yield* syncError("sync_cursor_reset", 409);
    }
    after = value.afterCall;
    watermark = value.watermark;
  }
  const rows = yield* syncRows(
    env.CATALOG,
    Schema.Struct({ call_id: ExchangeUUID }),
    `SELECT call_id FROM (SELECT call_id FROM trigo_master_uploads WHERE archive_id=? UNION SELECT call_id FROM trigo_call_deletion_markers WHERE archive_id=?)
     WHERE call_id>? ORDER BY call_id LIMIT ?`,
    [owner.archiveId, owner.archiveId, after, syncPageSize + 1],
  );
  const calls: CallCatalogEntry[] = [];
  for (const row of rows.slice(0, syncPageSize)) {
    calls.push(yield* catalogEntry(env, owner, row.call_id));
  }
  const last = calls.at(-1);
  const nextCursor =
    rows.length > syncPageSize && last
      ? yield* encodeSyncCursor({
          kind: "catalog",
          epoch: state.epoch,
          archiveId: owner.archiveId,
          watermark,
          afterCall: last.callId,
        })
      : null;
  const changesCursor = yield* encodeSyncCursor({
    kind: "changes",
    epoch: state.epoch,
    archiveId: owner.archiveId,
    sequence: watermark,
  });
  yield* requireSyncOwner(env.CATALOG, owner);
  const page: CallCatalogPage = {
    schemaVersion: 1,
    archiveId: owner.archiveId,
    calls,
    nextCursor,
    changesCursor,
  };
  return page;
});

export const getCallChanges = Effect.fn("SyncCatalog.changes")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  cursor: string,
) {
  yield* requireSyncOwner(env.CATALOG, owner);
  const state = yield* cursorState(env.CATALOG, owner.archiveId);
  const value = yield* decodeSyncCursor(ChangesCursor, cursor);
  if (
    value.epoch !== state.epoch ||
    value.archiveId !== owner.archiveId ||
    !retainedCursor(value.sequence, state)
  ) {
    return yield* syncError("sync_cursor_reset", 409);
  }
  const rows = yield* syncRows(
    env.CATALOG,
    Schema.Struct({ sequence: Schema.Int, call_id: ExchangeUUID }),
    "SELECT sequence,call_id FROM trigo_call_changes WHERE archive_id=? AND sequence>? ORDER BY sequence LIMIT ?",
    [owner.archiveId, value.sequence, syncPageSize + 1],
  );
  const changes: CallChangesPage["changes"][number][] = [];
  for (const row of rows.slice(0, syncPageSize)) {
    changes.push({ sequence: row.sequence, call: yield* catalogEntry(env, owner, row.call_id) });
  }
  const nextCursor = yield* encodeSyncCursor({
    kind: "changes",
    epoch: state.epoch,
    archiveId: owner.archiveId,
    sequence: changes.at(-1)?.sequence ?? value.sequence,
  });
  yield* requireSyncOwner(env.CATALOG, owner);
  const page: CallChangesPage = {
    schemaVersion: 1,
    archiveId: owner.archiveId,
    changes,
    nextCursor,
    hasMore: rows.length > syncPageSize,
  };
  return page;
});

export const getTranscriptResults = Effect.fn("SyncCatalog.results")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
  cursor?: string,
) {
  yield* requireSyncCall(env.CATALOG, owner, callId);
  const state = yield* cursorState(env.CATALOG, owner.archiveId);
  let after = 0;
  if (cursor !== undefined) {
    const value = yield* decodeSyncCursor(ResultsCursor, cursor);
    if (
      value.epoch !== state.epoch ||
      value.archiveId !== owner.archiveId ||
      value.callId !== callId
    ) {
      return yield* syncError("sync_cursor_reset", 409);
    }
    after = value.afterGeneration;
  }
  const rows = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionRow,
    "SELECT * FROM trigo_transcription_operations WHERE archive_id=? AND call_id=? AND state='result_available' AND generation>? ORDER BY generation LIMIT ?",
    [owner.archiveId, callId, after, syncPageSize + 1],
  ).pipe(Effect.mapError(() => syncError("sync_catalog_invalid", 503)));
  const results: TranscriptResultsPage["results"][number][] = [];
  for (const row of rows.slice(0, syncPageSize)) {
    const operation = yield* operationDocument(env.CATALOG, row).pipe(
      Effect.mapError(() => syncError("sync_catalog_invalid", 503)),
    );
    if (operation.result === null) {
      return yield* syncError("sync_catalog_invalid", 503);
    }
    results.push({
      operationId: row.operation_id,
      generation: row.generation,
      result: operation.result,
    });
  }
  const last = results.at(-1);
  const nextCursor =
    rows.length > syncPageSize && last
      ? yield* encodeSyncCursor({
          kind: "results",
          epoch: state.epoch,
          archiveId: owner.archiveId,
          callId,
          afterGeneration: last.generation,
        })
      : null;
  yield* requireSyncCall(env.CATALOG, owner, callId);
  const page: TranscriptResultsPage = {
    schemaVersion: 1,
    archiveId: owner.archiveId,
    callId,
    results,
    nextCursor,
  };
  return page;
});

export const getStoredAudioManifest = Effect.fn("SyncCatalog.audioManifest")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
) {
  yield* requireSyncCall(env.CATALOG, owner, callId);
  const stored = yield* syncStoredMaster(env, owner, callId);
  yield* requireSyncCall(env.CATALOG, owner, callId);
  return {
    bytes: new TextEncoder().encode(stored.audioManifest),
    sha256: stored.receipt.audioManifest.sha256,
  };
});
