import { Effect, Schema } from "effect";

import {
  parseCallDocument,
  parseStored,
  storedByteHash,
  type CallDocument,
  type PublishCallReplica,
  type TranscriptRevision,
} from "@trigo/contracts";

import { sourceHash, storedMaster } from "./master-finalization.ts";
import { type MasterUploadEnvironment } from "./master-uploads.ts";
import { readBoundedBody } from "./nova-3-transport.ts";
import { type OwnerContext } from "./owner-state.ts";
import { requireSyncCall, type ReplicaRow } from "./sync-catalog.ts";
import { syncError, syncJSON, syncStorage } from "./sync-errors.ts";
import { readTranscriptArtifact } from "./transcriptions.ts";
import { objectMatches } from "./upload-streams.ts";

export const maximumCallDocumentBytes = 16_000_000;

export const readReplicaBytes = Effect.fn("ReplicaDocument.read")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  row: ReplicaRow,
) {
  yield* requireSyncCall(env.CATALOG, owner, row.call_id);
  if (
    row.state !== "published" ||
    row.object_key === null ||
    row.byte_length > maximumCallDocumentBytes
  ) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  const key = row.object_key;
  const object = yield* syncStorage(() => env.ARCHIVE.get(key));
  if (!object || !("body" in object)) {
    return yield* syncError("sync_storage_unavailable", 503, "retryable");
  }
  if (
    !objectMatches(object, {
      object_key: row.object_key,
      sha256: row.sha256,
      byte_length: row.byte_length,
    })
  ) {
    yield* syncStorage(() => object.body.cancel());
    return yield* syncError("sync_catalog_invalid", 503);
  }
  const bytes = yield* readBoundedBody(object.body, maximumCallDocumentBytes).pipe(
    Effect.mapError(() => syncError("sync_catalog_invalid", 503)),
  );
  if (
    bytes.byteLength !== row.byte_length ||
    (yield* Effect.promise(() => storedByteHash(bytes))) !== row.sha256
  ) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  yield* requireSyncCall(env.CATALOG, owner, row.call_id);
  return { bytes, sha256: row.sha256 };
});

export const syncStoredMaster = Effect.fn("Sync.storedMaster")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
) {
  const stored = yield* storedMaster(env.CATALOG, owner.archiveId, callId).pipe(
    Effect.mapError((error) => {
      if (error.code === "call_deleted") {
        return syncError("call_deleted", 410, "never");
      }
      if (error.status === 409) {
        return syncError("sync_audio_pending", 409, "retryable");
      }
      return syncError("sync_storage_unavailable", 503, "retryable");
    }),
  );
  const bytes = new TextEncoder().encode(stored.audioManifest);
  const audio = yield* Effect.try({
    try: () => parseStored("AudioManifest", bytes),
    catch: () => syncError("sync_catalog_invalid", 503),
  });
  const receipt = stored.receipt;
  if (
    receipt.archiveId !== owner.archiveId ||
    receipt.callId !== callId ||
    audio.callId !== callId ||
    audio.manifestId !== receipt.audioManifest.manifestId ||
    audio.durationMs !== receipt.durationMs ||
    audio.mediaProfileId !== receipt.mediaProfileId ||
    receipt.byteLength !== 68 + receipt.durationMs * 64 ||
    (yield* Effect.promise(() => storedByteHash(bytes))) !== receipt.audioManifest.sha256
  ) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  if (
    receipt.durationMs > 0 &&
    !audio.objects.some(
      (object) =>
        object.objectId === receipt.masterId &&
        object.byteLength === receipt.byteLength &&
        object.sha256 === receipt.masterSHA256 &&
        receipt.channelMap.every((channel) =>
          object.channelMap.some(
            (item) =>
              item.channelIndex === channel.channelIndex && item.trackId === channel.trackId,
          ),
        ),
    )
  ) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  return stored;
});

const decodeCall = (bytes: Uint8Array) =>
  Effect.try({
    try: () => parseCallDocument(bytes),
    catch: () => syncError("sync_incompatible_document", 422),
  });

const metadata = (call: CallDocument) => [
  call.archiveId,
  call.callId,
  call.startedAt,
  call.endedAt,
  call.durationMs,
  call.captureState,
  call.interruptionReason,
  [
    call.source.applicationName,
    call.source.bundleId,
    call.source.processId,
    call.source.windowId,
    call.source.windowTitle,
  ],
  call.tracks.map((track) => [
    track.trackId,
    track.role,
    track.inputDevice?.id ?? null,
    track.inputDevice?.name ?? null,
    track.mediaProfileId,
    track.intervals.map((span) => [span.startMs, span.endMs, span.state, span.reason]),
  ]),
  call.audioManifest?.manifestId ?? null,
  call.audioManifest?.sha256 ?? null,
];

const annotations = (call: CallDocument, revisionId: string) => [
  Object.entries(call.speakerNames[revisionId] ?? {}).sort(([a], [b]) => a.localeCompare(b)),
  (call.speakerGroups[revisionId] ?? [])
    .map((group) => [group.groupId, group.displayName, [...group.speakerIds].sort()])
    .sort((a, b) => String(a[0]).localeCompare(String(b[0]))),
];

/** Fixed bounded state bitmap matches the complete storage witness even for a fragmented
 * canonical interval list. Reasons remain canonical metadata and are never inferred. */
const callSourceStateHash = Effect.fn("ReplicaDocument.sourceStates")(function* (
  call: CallDocument,
) {
  const duration = call.durationMs;
  if (duration === null || duration < 0 || duration > 10_800_000) {
    return yield* syncError("sync_invalid");
  }
  const bytes = new Uint8Array(Math.ceil(duration / 2));
  for (const [channel, role] of ["microphone", "application"].entries()) {
    const track = call.tracks.find((track) => track.role === role);
    if (!track) {
      return yield* syncError("sync_invalid");
    }
    for (const span of track.intervals) {
      const code = { recorded: 0, muted: 1, unavailable: 2 }[span.state];
      for (let ms = span.startMs; ms < span.endMs; ms++) {
        const index = Math.floor(ms / 2);
        bytes[index] = (bytes[index] ?? 0) | (code << ((ms % 2) * 4 + channel * 2));
      }
    }
  }
  return yield* Effect.promise(() => storedByteHash(bytes));
});

const referenceMatches = (
  call: CallDocument,
  revision: TranscriptRevision,
  revisionId: string,
  createdAt: string,
) =>
  revision.callId === call.callId &&
  revision.revisionId === revisionId &&
  revision.createdAt === createdAt &&
  revision.audioManifest.manifestId === call.audioManifest?.manifestId &&
  revision.audioManifest.sha256 === call.audioManifest?.sha256 &&
  revision.speakers.every((speaker) =>
    call.tracks.some((track) => track.trackId === speaker.trackId),
  ) &&
  revision.turns.every(
    (turn) =>
      turn.endMs <= (call.durationMs ?? -1) &&
      call.tracks.some((track) => track.trackId === turn.trackId),
  );

/** Reference validation consumes one bounded revision at a time. Retained transcript text
 * is released between revisions; only identities needed for aggregate uniqueness remain. */
export const validateReplicaPublication = Effect.fn("ReplicaDocument.validate")(function* (
  env: MasterUploadEnvironment,
  owner: OwnerContext,
  callId: string,
  input: PublishCallReplica,
  prior: ReplicaRow | null,
) {
  const bytes = new TextEncoder().encode(input.document);
  if (bytes.byteLength > maximumCallDocumentBytes) {
    return yield* syncError("sync_document_too_large", 413);
  }
  const call = yield* decodeCall(bytes);
  const wire = yield* Schema.decodeEffect(
    Schema.fromJsonString(Schema.Struct({ schemaVersion: Schema.Literals([1, 2]) })),
  )(input.document).pipe(Effect.mapError(() => syncError("sync_incompatible_document", 422)));
  const upload = yield* requireSyncCall(env.CATALOG, owner, callId);
  const stored = yield* syncStoredMaster(env, owner, callId);
  if (
    call.callId !== callId ||
    call.archiveId !== owner.archiveId ||
    call.captureState === "recording" ||
    call.startedAt !== upload.started_at ||
    call.durationMs !== stored.receipt.durationMs ||
    call.audioManifest?.manifestId !== stored.receipt.audioManifest.manifestId ||
    call.audioManifest.sha256 !== stored.receipt.audioManifest.sha256 ||
    (yield* sourceHash(call.source).pipe(Effect.mapError(() => syncError("sync_invalid")))) !==
      upload.source_hash ||
    (yield* callSourceStateHash(call)) !== stored.receipt.sourceStatesSHA256 ||
    !call.tracks.some(
      (track) => track.role === "microphone" && track.trackId === upload.microphone_track_id,
    ) ||
    !call.tracks.some(
      (track) => track.role === "application" && track.trackId === upload.application_track_id,
    ) ||
    call.tracks.some((track) => track.mediaProfileId !== stored.receipt.mediaProfileId)
  ) {
    return yield* syncError("sync_invalid");
  }
  const scopes = new Set(input.annotationRevisionIds);
  if (
    scopes.size !== input.annotationRevisionIds.length ||
    [...scopes].some((id) => !call.revisions.some((ref) => ref.revisionId === id)) ||
    Object.keys(call.speakerNames).some(
      (id) => !call.revisions.some((ref) => ref.revisionId === id),
    )
  ) {
    return yield* syncError("sync_invalid");
  }
  if (prior) {
    if (
      wire.schemaVersion < prior.schema_version ||
      call.documentVersion <= prior.document_version
    ) {
      return yield* syncError("sync_incompatible_document", 422);
    }
    const current = yield* decodeCall((yield* readReplicaBytes(env, owner, prior)).bytes);
    if (
      (yield* syncJSON(metadata(current))) !== (yield* syncJSON(metadata(call))) ||
      current.revisions.some(
        (reference) =>
          !call.revisions.some(
            (proposed) =>
              proposed.revisionId === reference.revisionId &&
              proposed.sha256 === reference.sha256 &&
              proposed.createdAt === reference.createdAt,
          ),
      )
    ) {
      return yield* syncError("sync_incompatible_document", 422);
    }
    for (const reference of current.revisions) {
      if (
        !scopes.has(reference.revisionId) &&
        (yield* syncJSON(annotations(current, reference.revisionId))) !==
          (yield* syncJSON(annotations(call, reference.revisionId)))
      ) {
        return yield* syncError("sync_incompatible_document", 422);
      }
    }
  }
  const speakerIDs = new Set<string>();
  const turnIDs = new Set<string>();
  for (const reference of call.revisions) {
    const artifact = yield* readTranscriptArtifact(
      env,
      owner,
      callId,
      reference.revisionId,
      false,
    ).pipe(
      Effect.mapError((error) => {
        if (error.code === "call_deleted") {
          return syncError("call_deleted", 410, "never");
        }
        if (error.status === 503) {
          return syncError("sync_storage_unavailable", 503, "retryable");
        }
        return syncError("sync_invalid");
      }),
    );
    if (artifact.sha256 !== reference.sha256) {
      return yield* syncError("sync_invalid");
    }
    const revision = yield* Effect.try({
      try: () => parseStored("TranscriptRevision", artifact.bytes),
      catch: () => syncError("sync_catalog_invalid", 503),
    });
    if (!referenceMatches(call, revision, reference.revisionId, reference.createdAt)) {
      return yield* syncError("sync_invalid");
    }
    const members = new Set(revision.speakers.map((speaker) => speaker.speakerId));
    if (
      Object.keys(call.speakerNames[reference.revisionId] ?? {}).some((id) => !members.has(id)) ||
      (call.speakerGroups[reference.revisionId] ?? []).some((group) =>
        group.speakerIds.some((id) => !members.has(id)),
      )
    ) {
      return yield* syncError("sync_invalid");
    }
    for (const speaker of revision.speakers) {
      if (speakerIDs.has(speaker.speakerId)) {
        return yield* syncError("sync_invalid");
      }
      speakerIDs.add(speaker.speakerId);
    }
    for (const turn of revision.turns) {
      if (turnIDs.has(turn.turnId)) {
        return yield* syncError("sync_invalid");
      }
      turnIDs.add(turn.turnId);
    }
  }
  return {
    call,
    bytes,
    schemaVersion: wire.schemaVersion,
    sha256: yield* Effect.promise(() => storedByteHash(bytes)),
  };
});
