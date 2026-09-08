import { Effect } from "effect";

import { PublishCallReplica, storedByteHash } from "@trigo/contracts";

import { type MasterUploadEnvironment } from "./master-uploads.ts";
import { type OwnerContext } from "./owner-state.ts";
import {
  maximumCallDocumentBytes,
  readReplicaBytes,
  validateReplicaPublication,
} from "./replica-documents.ts";
import { storeReplica } from "./replica-writers.ts";
import {
  currentReplica,
  executeSyncSQL,
  ReplicaRow,
  replicaReceipt,
  requireSyncCall,
  syncCallFence,
  syncCallParameters,
  syncRows,
  syncTimestamp,
} from "./sync-catalog.ts";
import { decodeSync, syncError, syncJSON } from "./sync-errors.ts";
import { uploadOwnerFence, uploadOwnerParameters } from "./upload-catalog.ts";

const operationFor = Effect.fn("Replica.operation")(function* (
  env: MasterUploadEnvironment,
  operationId: string,
) {
  const [row] = yield* syncRows(
    env.CATALOG,
    ReplicaRow,
    "SELECT * FROM trigo_replica_operations WHERE operation_id=?",
    [operationId],
  );
  return row ?? null;
});

const confirmedReceipt = Effect.fn("Replica.confirmedReceipt")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  row: ReplicaRow,
) {
  yield* requireSyncCall(env.CATALOG, owner, row.call_id);
  return yield* replicaReceipt(row);
});

/** R2 persistence precedes the single D1 state transition that exposes a version and its
 * immutable replay receipt. A competing version, revoked owner or deletion fence wins. */
export const publishCanonicalReplica = Effect.fn("Replica.publish")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
  value: unknown,
) {
  yield* requireSyncCall(env.CATALOG, owner, callId);
  const input = yield* decodeSync(PublishCallReplica, value);
  if (new TextEncoder().encode(input.document).byteLength > maximumCallDocumentBytes) {
    return yield* syncError("sync_document_too_large", 413);
  }
  const command = yield* syncJSON([
    input.schemaVersion,
    input.operationId,
    input.expectedDocumentVersion,
    input.document,
    [...input.annotationRevisionIds].sort(),
  ]);
  const commandHash = yield* Effect.promise(() =>
    storedByteHash(new TextEncoder().encode(command)),
  );
  const existing = yield* operationFor(env, input.operationId);
  if (existing) {
    if (
      existing.archive_id !== owner.archiveId ||
      existing.call_id !== callId ||
      existing.command_hash !== commandHash
    ) {
      return yield* syncError("sync_operation_conflict", 409);
    }
    if (existing.state === "published") {
      return yield* confirmedReceipt(env, owner, existing);
    }
  }
  const prior = yield* currentReplica(env.CATALOG, owner, callId);
  if ((prior?.document_version ?? null) !== input.expectedDocumentVersion) {
    return yield* syncError("sync_conflict", 409);
  }
  const prepared = yield* validateReplicaPublication(env, owner, callId, input, prior);
  const createdAt = yield* syncTimestamp();
  yield* executeSyncSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_replica_operations
     (operation_id,archive_id,call_id,owner_generation,command_hash,document_version,schema_version,sha256,byte_length,expected_version,state,created_at)
     SELECT ?,?,?,?,?,?,?,?,?,?,'admitted',? WHERE ${uploadOwnerFence} AND ${syncCallFence}`,
    [
      input.operationId,
      owner.archiveId,
      callId,
      owner.credentialGeneration,
      commandHash,
      prepared.call.documentVersion,
      prepared.schemaVersion,
      prepared.sha256,
      prepared.bytes.byteLength,
      input.expectedDocumentVersion,
      createdAt,
      ...uploadOwnerParameters(owner),
      ...syncCallParameters(owner, callId),
    ],
  );
  // Current authenticated credentials may recover the same immutable command after rotation.
  // The previous generation remains fenced from publication even if its admitted PUT finishes.
  yield* executeSyncSQL(
    env.CATALOG,
    `UPDATE trigo_replica_operations SET owner_generation=? WHERE operation_id=? AND command_hash=? AND state='admitted'
     AND ${uploadOwnerFence} AND ${syncCallFence}`,
    [
      owner.credentialGeneration,
      input.operationId,
      commandHash,
      ...uploadOwnerParameters(owner),
      ...syncCallParameters(owner, callId),
    ],
  );
  const operation = yield* operationFor(env, input.operationId);
  yield* requireSyncCall(env.CATALOG, owner, callId);
  if (
    !operation ||
    operation.command_hash !== commandHash ||
    operation.call_id !== callId ||
    operation.archive_id !== owner.archiveId
  ) {
    return yield* syncError("sync_operation_conflict", 409);
  }
  if (operation.state === "published") {
    return yield* confirmedReceipt(env, owner, operation);
  }
  for (const [revisionId, groups] of Object.entries(prepared.call.speakerGroups)) {
    for (const group of groups) {
      yield* executeSyncSQL(
        env.CATALOG,
        `INSERT OR IGNORE INTO trigo_replica_groups SELECT ?,?,? WHERE ${uploadOwnerFence} AND ${syncCallFence}`,
        [
          operation.operation_id,
          group.groupId,
          revisionId,
          ...uploadOwnerParameters(owner),
          ...syncCallParameters(owner, callId),
        ],
      );
    }
  }
  const storage = yield* storeReplica(env, owner, operation, prepared.bytes).pipe(Effect.result);
  if (storage._tag === "Failure") {
    yield* requireSyncCall(env.CATALOG, owner, callId);
    // A simultaneous duplicate may have published after this request loaded its state.
    const replay = yield* operationFor(env, input.operationId);
    if (replay?.state === "published") {
      return yield* confirmedReceipt(env, owner, replay);
    }
    return yield* storage.failure;
  }
  const writer = storage.success;
  const publishedAt = yield* syncTimestamp();
  yield* executeSyncSQL(
    env.CATALOG,
    `UPDATE trigo_replica_operations SET state='published',object_key=?,writer_id=?,published_at=?
     WHERE operation_id=? AND state='admitted' AND owner_generation=? AND command_hash=?
       AND ${uploadOwnerFence} AND ${syncCallFence}
       AND (SELECT MAX(r.document_version) FROM trigo_replica_operations r WHERE r.call_id=? AND r.state='published') IS expected_version
       AND document_version>COALESCE((SELECT MAX(r.document_version) FROM trigo_replica_operations r WHERE r.call_id=? AND r.state='published'),0)
       AND EXISTS(SELECT 1 FROM trigo_replica_writers w WHERE w.writer_id=? AND w.operation_id=trigo_replica_operations.operation_id AND w.state='stored' AND w.sha256=trigo_replica_operations.sha256 AND w.byte_length=trigo_replica_operations.byte_length)
       AND NOT EXISTS(SELECT 1 FROM trigo_replica_groups incoming
         JOIN trigo_replica_groups retained ON retained.group_id=incoming.group_id
         JOIN trigo_replica_operations old ON old.operation_id=retained.operation_id
         WHERE incoming.operation_id=trigo_replica_operations.operation_id AND old.call_id=trigo_replica_operations.call_id AND old.state='published' AND retained.revision_id<>incoming.revision_id)`,
    [
      writer.object_key,
      writer.writer_id,
      publishedAt,
      input.operationId,
      owner.credentialGeneration,
      commandHash,
      ...uploadOwnerParameters(owner),
      ...syncCallParameters(owner, callId),
      callId,
      callId,
      writer.writer_id,
    ],
  );
  yield* requireSyncCall(env.CATALOG, owner, callId);
  const published = yield* operationFor(env, input.operationId);
  if (!published || published.state !== "published") {
    return yield* syncError("sync_conflict", 409);
  }
  return yield* replicaReceipt(published);
});

export const getCanonicalReplica = Effect.fn("Replica.get")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
  documentVersion?: number,
) {
  yield* requireSyncCall(env.CATALOG, owner, callId);
  const row =
    documentVersion === undefined
      ? yield* currentReplica(env.CATALOG, owner, callId)
      : (yield* syncRows(
          env.CATALOG,
          ReplicaRow,
          "SELECT * FROM trigo_replica_operations WHERE archive_id=? AND call_id=? AND document_version=? AND state='published'",
          [owner.archiveId, callId, documentVersion],
        ))[0];
  if (!row) {
    return yield* syncError("sync_not_found", 404);
  }
  return yield* readReplicaBytes(env, owner, row);
});
