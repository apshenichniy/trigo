import { Effect, Schema } from "effect";

import { ExchangeUUID, NonNegativeInteger } from "@trigo/contracts";

import { syncRows } from "./sync-catalog.ts";
import { syncError, syncJSON } from "./sync-errors.ts";
import { type UploadDatabase } from "./upload-catalog.ts";

const Epoch = Schema.String.check(Schema.isPattern(/^[0-9a-f]{32}$/));
export const CatalogCursor = Schema.Struct({
  kind: Schema.Literal("catalog"),
  epoch: Epoch,
  archiveId: ExchangeUUID,
  watermark: NonNegativeInteger,
  afterCall: ExchangeUUID,
});
export const ChangesCursor = Schema.Struct({
  kind: Schema.Literal("changes"),
  epoch: Epoch,
  archiveId: ExchangeUUID,
  sequence: NonNegativeInteger,
});
export const ResultsCursor = Schema.Struct({
  kind: Schema.Literal("results"),
  epoch: Epoch,
  archiveId: ExchangeUUID,
  callId: ExchangeUUID,
  afterGeneration: NonNegativeInteger,
});

export const cursorState = Effect.fn("SyncCursor.state")(function* (
  db: UploadDatabase,
  archiveId: string,
) {
  const [state] = yield* syncRows(
    db,
    Schema.Struct({
      epoch: Epoch,
      first_sequence: NonNegativeInteger,
      last_sequence: NonNegativeInteger,
    }),
    `SELECT e.epoch,COALESCE(MIN(c.sequence),0) AS first_sequence,COALESCE(MAX(c.sequence),0) AS last_sequence
     FROM trigo_sync_epoch e LEFT JOIN trigo_call_changes c ON c.archive_id=? WHERE e.singleton=1 GROUP BY e.epoch`,
    [archiveId],
  );
  if (!state) {
    return yield* syncError("sync_catalog_invalid", 503);
  }
  return state;
});

export const encodeSyncCursor = (value: unknown) =>
  syncJSON(value).pipe(
    Effect.map((text) => btoa(text).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")),
  );
export const decodeSyncCursor = Effect.fn("SyncCursor.decode")(function* <
  S extends Schema.ConstraintDecoder<unknown>,
>(schema: S, cursor: string) {
  if (cursor.length > 1024 || !/^[A-Za-z0-9_-]+$/.test(cursor)) {
    return yield* syncError("sync_cursor_reset", 409);
  }
  const text = yield* Effect.try({
    try: () => atob(cursor.replaceAll("-", "+").replaceAll("_", "/")),
    catch: () => syncError("sync_cursor_reset", 409),
  });
  return yield* Schema.decodeEffect(Schema.fromJsonString(schema), { onExcessProperty: "error" })(
    text,
  ).pipe(Effect.mapError(() => syncError("sync_cursor_reset", 409)));
});

export function retainedCursor(
  sequence: number,
  state: { first_sequence: number; last_sequence: number },
) {
  return (
    sequence <= state.last_sequence &&
    (state.first_sequence === 0 || sequence >= state.first_sequence - 1)
  );
}
