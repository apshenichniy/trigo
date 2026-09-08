import { Context, DateTime, Effect, Layer, Schema } from "effect";

import {
  ExchangeUUID,
  PlaybackGrant,
  PlaybackManifest,
  RequestPlayback,
  playbackGrantLifetimeMs,
  playbackSegmentFrames,
  storedByteHash,
} from "@trigo/contracts";

import { storedMaster } from "./master-finalization.ts";
import { ArchiveId, type OwnerContext } from "./owner-state.ts";
import {
  PlaybackAuthorityRow,
  PlaybackGrantRow,
  type PlaybackEnvironment,
  playbackNow,
  playbackOwnerFence,
  playbackRows,
} from "./playback-catalog.ts";
import {
  PlaybackError,
  playbackError,
  playbackStorage,
  playbackUploadError,
} from "./playback-errors.ts";
import { uploadOwnerFence, uploadOwnerParameters } from "./upload-catalog.ts";

export const loadPlaybackMaster = Effect.fn("Playback.loadMaster")(function* (
  env: PlaybackEnvironment,
  owner: OwnerContext,
  callId: string,
) {
  const upload = yield* playbackOwnerFence(env, owner, callId);
  const stored = yield* storedMaster(env.CATALOG, owner.archiveId, callId).pipe(
    Effect.mapError(playbackUploadError),
  );
  const receipt = stored.receipt;
  const manifestHash = yield* Effect.promise(() =>
    storedByteHash(new TextEncoder().encode(stored.audioManifest)),
  );
  if (
    receipt.archiveId !== owner.archiveId ||
    receipt.callId !== callId ||
    receipt.masterId !== upload.master_id ||
    receipt.audioManifest.sha256 !== manifestHash ||
    receipt.byteLength !== 68 + receipt.durationMs * 64 ||
    !receipt.channelMap.some(
      (channel) => channel.channelIndex === 0 && channel.trackId === upload.microphone_track_id,
    ) ||
    !receipt.channelMap.some(
      (channel) => channel.channelIndex === 1 && channel.trackId === upload.application_track_id,
    )
  ) {
    return yield* playbackError("playback_catalog_invalid");
  }
  if (receipt.durationMs === 0) {
    return yield* playbackError("playback_no_audio");
  }
  const frameCount = receipt.durationMs * 16;
  const media = yield* Schema.decodeEffect(PlaybackManifest)({
    masterId: receipt.masterId,
    masterSHA256: receipt.masterSHA256,
    profileId: "wav-pcm-s16le-16000-stereo-segment-v1",
    sampleRateHz: 16_000,
    frameCount,
    segmentFrames: playbackSegmentFrames,
    segmentCount: Math.ceil(frameCount / playbackSegmentFrames),
    channels: [
      { channelIndex: 0, trackId: upload.microphone_track_id, role: "microphone" },
      { channelIndex: 1, trackId: upload.application_track_id, role: "application" },
    ],
  }).pipe(Effect.mapError(() => playbackError("playback_catalog_invalid")));
  return { ...stored, media };
});

const authoritySQL = `SELECT g.*, s.verifier_sha256, s.generation AS current_generation, s.revoked
  FROM trigo_playback_grants g JOIN trigo_archive_identity i ON i.archive_id=g.archive_id
  JOIN trigo_owner_credential_state s USING (singleton)`;

const readAuthority = Effect.fn("Playback.readAuthority")(function* (
  env: PlaybackEnvironment,
  grantId: string,
  callId: string,
) {
  const [row] = yield* playbackRows(
    env.CATALOG,
    PlaybackAuthorityRow,
    `${authoritySQL} WHERE g.grant_id=? AND g.call_id=?`,
    [grantId, callId],
  );
  if (!row) {
    return yield* playbackError("playback_grant_invalid");
  }
  return row;
});

const signatureInput = (row: PlaybackGrantRow) =>
  new TextEncoder().encode(
    `TrigoPlaybackGrant/v1\n${row.grant_id}\n${row.archive_id}\n${row.call_id}\n${row.owner_generation}\n${row.expires_at_ms}`,
  );
const hexBytes = (hex: string) =>
  Uint8Array.from(hex.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));

/** The random owner verifier is private server key material. Domain separation and
 * live owner-generation checks bind this HMAC to a short-lived playback capability. */
const signingKey = Effect.fn("Playback.signingKey")((row: PlaybackAuthorityRow) =>
  playbackStorage(() =>
    crypto.subtle.importKey(
      "raw",
      hexBytes(row.verifier_sha256),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    ),
  ),
);
const signGrant = Effect.fn("Playback.signGrant")(function* (row: PlaybackAuthorityRow) {
  const key = yield* signingKey(row);
  const signature = yield* playbackStorage(() =>
    crypto.subtle.sign("HMAC", key, signatureInput(row)),
  );
  return `trigo_playback_v1_${Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
});

export const authorizePlaybackGrant = Effect.fn("Playback.authorizeGrant")(function* (
  env: PlaybackEnvironment,
  grantId: string,
  callId: string,
  authorization: string | null,
) {
  const token = /^Bearer trigo_playback_v1_([0-9a-f]{64})$/.exec(authorization ?? "")?.[1];
  if (!token) {
    return yield* playbackError("playback_grant_invalid");
  }
  const row = yield* readAuthority(env, grantId, callId);
  const key = yield* signingKey(row);
  const valid = yield* playbackStorage(() =>
    crypto.subtle.verify("HMAC", key, hexBytes(token), signatureInput(row)),
  );
  if (!valid || row.revoked !== 0 || row.current_generation !== row.owner_generation) {
    return yield* playbackError("playback_grant_invalid");
  }
  if ((yield* playbackNow()) >= row.expires_at_ms) {
    return yield* playbackError("playback_grant_expired");
  }
  const archiveId = yield* Schema.decodeEffect(ArchiveId)(row.archive_id).pipe(
    Effect.mapError(() => playbackError("playback_catalog_invalid")),
  );
  const owner: OwnerContext = { archiveId, credentialGeneration: row.owner_generation };
  yield* playbackOwnerFence(env, owner, callId);
  return { row, owner };
});

export const requestPlayback = Effect.fn("Playback.request")(function* (
  env: PlaybackEnvironment,
  owner: OwnerContext,
  callId: string,
  value: unknown,
) {
  yield* Schema.decodeEffect(ExchangeUUID)(callId).pipe(
    Effect.mapError(() => playbackError("playback_invalid")),
  );
  const command = yield* Schema.decodeUnknownEffect(RequestPlayback, { onExcessProperty: "error" })(
    value,
  ).pipe(Effect.mapError(() => playbackError("playback_invalid")));
  const { media } = yield* loadPlaybackMaster(env, owner, callId);
  const now = yield* playbackNow();
  // oxlint-disable-next-line effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Public capability identity is independent from command and media identities.
  const grantId = yield* Effect.sync(() => crypto.randomUUID());
  yield* playbackStorage(() =>
    env.CATALOG.prepare(`INSERT OR IGNORE INTO trigo_playback_grants
    (operation_id,grant_id,archive_id,call_id,owner_generation,expires_at_ms,created_at_ms)
    SELECT ?,?,archive_id,call_id,?,?,? FROM trigo_master_uploads
    WHERE archive_id=? AND call_id=? AND deletion_state='active' AND ${uploadOwnerFence}`)
      .bind(
        command.operationId,
        grantId,
        owner.credentialGeneration,
        now + playbackGrantLifetimeMs,
        now,
        owner.archiveId,
        callId,
        ...uploadOwnerParameters(owner),
      )
      .run(),
  );
  const [row] = yield* playbackRows(
    env.CATALOG,
    PlaybackGrantRow,
    "SELECT * FROM trigo_playback_grants WHERE operation_id=?",
    [command.operationId],
  );
  if (!row) {
    yield* playbackOwnerFence(env, owner, callId);
    return yield* playbackError("playback_storage_unavailable");
  }
  if (row.archive_id !== owner.archiveId || row.call_id !== callId) {
    return yield* playbackError("playback_conflict");
  }
  if (row.owner_generation !== owner.credentialGeneration) {
    return yield* playbackError("playback_owner_changed");
  }
  const authority = yield* readAuthority(env, row.grant_id, callId);
  const token = yield* signGrant(authority);
  yield* playbackOwnerFence(env, owner, callId);
  const expiresAt = yield* Effect.try({
    try: () => DateTime.formatIso(DateTime.makeUnsafe(row.expires_at_ms)),
    catch: () => playbackError("playback_catalog_invalid"),
  });
  return yield* Schema.decodeEffect(PlaybackGrant)({
    schemaVersion: 1,
    operationId: command.operationId,
    grantId: row.grant_id,
    archiveId: owner.archiveId,
    callId,
    expiresAt,
    token,
    media,
  }).pipe(Effect.mapError(() => playbackError("playback_catalog_invalid")));
});

export class PlaybackGrants extends Context.Service<
  PlaybackGrants,
  {
    readonly request: (
      callId: string,
      value: unknown,
    ) => Effect.Effect<PlaybackGrant, PlaybackError>;
  }
>()("PlaybackGrants") {}

export const playbackGrantsLayer = (env: PlaybackEnvironment, owner: OwnerContext) =>
  Layer.succeed(
    PlaybackGrants,
    PlaybackGrants.of({ request: (callId, value) => requestPlayback(env, owner, callId, value) }),
  );
