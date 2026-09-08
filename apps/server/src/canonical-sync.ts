import { Context, Effect, Layer } from "effect";

import {
  type CallCatalogPage,
  type CallChangesPage,
  type ReplicaReceipt,
  type TranscriptResultsPage,
} from "@trigo/contracts";

import { getCanonicalReplica, publishCanonicalReplica } from "./canonical-replicas.ts";
import { type MasterUploadEnvironment } from "./master-uploads.ts";
import { type OwnerContext } from "./owner-state.ts";
import {
  getCallCatalog,
  getCallChanges,
  getStoredAudioManifest,
  getTranscriptResults,
} from "./sync-catalog-api.ts";
import { type SyncError } from "./sync-errors.ts";

export class CanonicalSync extends Context.Service<
  CanonicalSync,
  {
    readonly publish: (callId: string, input: unknown) => Effect.Effect<ReplicaReceipt, SyncError>;
    readonly document: (
      callId: string,
      documentVersion?: number,
    ) => Effect.Effect<{ bytes: Uint8Array; sha256: string }, SyncError>;
    readonly audioManifest: (
      callId: string,
    ) => Effect.Effect<{ bytes: Uint8Array; sha256: string }, SyncError>;
    readonly catalog: (cursor?: string) => Effect.Effect<CallCatalogPage, SyncError>;
    readonly changes: (cursor: string) => Effect.Effect<CallChangesPage, SyncError>;
    readonly results: (
      callId: string,
      cursor?: string,
    ) => Effect.Effect<TranscriptResultsPage, SyncError>;
  }
>()("trigo/CanonicalSync") {}

export const canonicalSyncLayer = (env: MasterUploadEnvironment, owner: OwnerContext) =>
  Layer.succeed(CanonicalSync, {
    publish: (callId, input) => publishCanonicalReplica(env, owner, callId, input),
    document: (callId, version) => getCanonicalReplica(env, owner, callId, version),
    audioManifest: (callId) => getStoredAudioManifest(env, owner, callId),
    catalog: (cursor) => getCallCatalog(env, owner, cursor),
    changes: (cursor) => getCallChanges(env, owner, cursor),
    results: (callId, cursor) => getTranscriptResults(env, owner, callId, cursor),
  });
