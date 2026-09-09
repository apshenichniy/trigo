import { Effect } from "effect";

import { type MasterUploadEnvironment } from "./master-uploads.ts";
import { type OwnerContext } from "./owner-state.ts";
import {
  executeSyncSQL,
  newReplicaIdentity,
  ReplicaWriterRow,
  requireSyncCall,
  syncCallFence,
  syncCallParameters,
  syncRows,
  syncTimestamp,
  type ReplicaRow,
} from "./sync-catalog.ts";
import { syncError, syncStorage } from "./sync-errors.ts";
import { uploadOwnerFence, uploadOwnerParameters } from "./upload-catalog.ts";
import { objectMatches } from "./upload-streams.ts";

const reconcileWriter = Effect.fn("ReplicaWriter.reconcile")(function* (
  env: MasterUploadEnvironment,
  writer: ReplicaWriterRow,
) {
  const object = yield* syncStorage(() => env.ARCHIVE.head(writer.object_key));
  if (!object || !objectMatches(object, writer)) {
    return false;
  }
  yield* executeSyncSQL(
    env.CATALOG,
    "UPDATE trigo_replica_writers SET state='stored' WHERE writer_id=?",
    [writer.writer_id],
  );
  return true;
});

/** Each durable admission permits one PUT to one fresh key. Unknown prior PUTs are
 * reconciled but never reissued; deferred deletion can still enumerate every writer. */
export const storeReplica = Effect.fn("ReplicaWriter.store")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  operation: ReplicaRow,
  bytes: Uint8Array,
) {
  let after = "";
  while (true) {
    const prior = yield* inspectReplicaWriters(env, operation.operation_id, after);
    for (const writer of prior) {
      if (writer.sha256 !== operation.sha256 || writer.byte_length !== bytes.byteLength) {
        return yield* syncError("sync_catalog_invalid", 503);
      }
      if (yield* reconcileWriter(env, writer)) {
        return writer;
      }
    }
    if (prior.length < 128) {
      break;
    }
    const last = prior.at(-1);
    if (!last) {
      return yield* syncError("sync_catalog_invalid", 503);
    }
    after = last.writer_id;
  }
  const writerId = yield* newReplicaIdentity();
  const key = `archives/${owner.archiveId}/calls/${operation.call_id}/replicas/${operation.document_version}/${writerId}.json`;
  const createdAt = yield* syncTimestamp();
  const admission = yield* executeSyncSQL(
    env.CATALOG,
    `INSERT INTO trigo_replica_writers SELECT ?,?,?,?,?,'admitted',?
     WHERE ${uploadOwnerFence} AND ${syncCallFence}
       AND EXISTS(SELECT 1 FROM trigo_replica_operations WHERE operation_id=? AND state='admitted' AND owner_generation=?)`,
    [
      writerId,
      operation.operation_id,
      key,
      operation.sha256,
      bytes.byteLength,
      createdAt,
      ...uploadOwnerParameters(owner),
      ...syncCallParameters(owner, operation.call_id),
      operation.operation_id,
      owner.credentialGeneration,
    ],
  );
  if (admission.meta.changes !== 1) {
    yield* requireSyncCall(env.CATALOG, owner, operation.call_id);
    return yield* syncError("sync_conflict", 409);
  }
  const [writer] = yield* syncRows(
    env.CATALOG,
    ReplicaWriterRow,
    "SELECT * FROM trigo_replica_writers WHERE writer_id=?",
    [writerId],
  );
  if (!writer) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  const stored = yield* syncStorage(() =>
    env.ARCHIVE.put(key, bytes, {
      sha256: operation.sha256,
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/json", cacheControl: "private, no-store" },
    }),
  ).pipe(Effect.result);
  if (
    stored._tag === "Failure" ||
    stored.success === null ||
    !objectMatches(stored.success, writer)
  ) {
    yield* executeSyncSQL(
      env.CATALOG,
      "UPDATE trigo_replica_writers SET state='uncertain' WHERE writer_id=?",
      [writerId],
    );
    if (!(yield* reconcileWriter(env, writer))) {
      return yield* syncError("sync_storage_unavailable", 503, "retryable");
    }
  }
  yield* executeSyncSQL(
    env.CATALOG,
    "UPDATE trigo_replica_writers SET state='stored' WHERE writer_id=?",
    [writerId],
  );
  return writer;
});

export const inspectReplicaWriters = (
  env: MasterUploadEnvironment,
  operationId: string,
  after = "",
) =>
  syncRows(
    env.CATALOG,
    ReplicaWriterRow,
    "SELECT * FROM trigo_replica_writers WHERE operation_id=? AND writer_id>? ORDER BY writer_id LIMIT 128",
    [operationId, after],
  );
