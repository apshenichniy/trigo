import { Effect, Schema, Struct } from "effect";

const messages = {
  sync_invalid: "The canonical synchronization request is invalid.",
  sync_incompatible_document:
    "This call document cannot be published without losing supported annotations or retained evidence. Keep the local changes and update the receiver.",
  sync_conflict:
    "The confirmed server document changed. Compare names and groups before choosing which annotations to keep.",
  sync_operation_conflict: "This operation identity already describes a different publication.",
  sync_owner_changed:
    "Owner access changed. Reconnect with the current credential before retrying.",
  sync_not_found: "A confirmed canonical document is not available for this call yet.",
  sync_audio_pending: "Verified complete audio is required before publishing this call.",
  sync_cursor_reset:
    "The synchronization cursor is no longer available. Reconcile the full catalog without clearing local data.",
  sync_document_too_large:
    "The canonical document exceeds this receiver's supported size. Keep the complete local snapshot pending.",
  sync_catalog_invalid:
    "Retained synchronization metadata could not be validated. Preserve the archive and inspect server diagnostics.",
  sync_storage_unavailable:
    "Archive storage is temporarily unavailable. The pending publication remains recoverable.",
  call_deleted: "This call is fenced for deletion.",
} as const;

export const SyncErrorCode = Schema.Literals(Struct.keys(messages));
export type SyncErrorCode = Schema.Schema.Type<typeof SyncErrorCode>;
export class SyncError extends Schema.TaggedError<SyncError>()("Sync.Error", {
  status: Schema.Int,
  code: SyncErrorCode,
  retry: Schema.Literals(["never", "after_correction", "retryable"]),
  message: Schema.String,
}) {}

export const syncError = (
  code: SyncErrorCode,
  status = 400,
  retry: SyncError["retry"] = "after_correction",
) => new SyncError({ code, status, retry, message: messages[code] });

export const syncStorage = <A>(run: () => Promise<A>) =>
  Effect.tryPromise({
    try: run,
    catch: (cause) =>
      Schema.is(SyncError)(cause) ? cause : syncError("sync_storage_unavailable", 503, "retryable"),
  });

export const decodeSync = <S extends Schema.ConstraintDecoder<unknown>>(
  schema: S,
  value: unknown,
) =>
  Schema.decodeUnknownEffect(schema, { onExcessProperty: "error" })(value).pipe(
    Effect.mapError(() => syncError("sync_invalid")),
  );

export const syncJSON = (value: unknown) =>
  Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown))(value).pipe(
    Effect.mapError(() => syncError("sync_invalid")),
  );
