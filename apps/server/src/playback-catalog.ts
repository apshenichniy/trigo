import { DateTime, Effect, Schema } from "effect";

import { ExchangeUUID, SHA256 } from "@trigo/contracts";

import { type OwnerContext } from "./owner-state.ts";
import { playbackError, playbackStorage, playbackUploadError } from "./playback-errors.ts";
import { type UploadDatabase, requireUpload, requireUploadOwner } from "./upload-catalog.ts";

export interface PlaybackEnvironment {
  readonly CATALOG: UploadDatabase;
  readonly ARCHIVE: Pick<R2Bucket, "get">;
}
export const PlaybackGrantRow = Schema.Struct({
  operation_id: ExchangeUUID,
  grant_id: ExchangeUUID,
  archive_id: ExchangeUUID,
  call_id: ExchangeUUID,
  owner_generation: Schema.Int,
  expires_at_ms: Schema.Int,
  created_at_ms: Schema.Int,
});
export interface PlaybackGrantRow extends Schema.Schema.Type<typeof PlaybackGrantRow> {}
export const PlaybackAuthorityRow = Schema.Struct({
  ...PlaybackGrantRow.fields,
  verifier_sha256: SHA256,
  current_generation: Schema.Int,
  revoked: Schema.Literals([0, 1]),
});
export interface PlaybackAuthorityRow extends Schema.Schema.Type<typeof PlaybackAuthorityRow> {}

export const playbackRows = Effect.fn("PlaybackCatalog.read")(function* <
  S extends Schema.ConstraintDecoder<unknown>,
>(db: UploadDatabase, schema: S, sql: string, parameters: ReadonlyArray<string | number> = []) {
  const result = yield* playbackStorage(() =>
    db
      .prepare(sql)
      .bind(...parameters)
      .all(),
  );
  const rows: unknown = result.results;
  return yield* Schema.decodeUnknownEffect(Schema.Array(schema))(rows).pipe(
    Effect.mapError(() => playbackError("playback_catalog_invalid")),
  );
});
export const playbackNow = Effect.fn("Playback.now")(function* () {
  return DateTime.toEpochMillis(yield* DateTime.now);
});
export const playbackOwnerFence = Effect.fn("Playback.requireOwnerAndCall")(function* (
  env: PlaybackEnvironment,
  owner: OwnerContext,
  callId: string,
) {
  yield* requireUploadOwner(env.CATALOG, owner);
  return yield* requireUpload(env.CATALOG, owner.archiveId, callId);
}, Effect.mapError(playbackUploadError));
