import { Effect, Schema } from "effect";

export class UploadError extends Schema.TaggedError<UploadError>()("MasterUpload.Error", {
  status: Schema.Int,
  code: Schema.String,
  retry: Schema.Literals(["never", "after_correction", "retryable"]),
  message: Schema.String,
}) {}

export const invalidUpload = (message: string) =>
  new UploadError({ status: 400, code: "upload_invalid", retry: "after_correction", message });
export const uploadConflict = (message: string) =>
  new UploadError({ status: 409, code: "upload_conflict", retry: "after_correction", message });
export const incompleteUpload = () =>
  new UploadError({
    status: 409,
    code: "upload_incomplete",
    retry: "retryable",
    message: "The complete recording master is not stored yet. Resume missing ranges.",
  });
export const fencedUpload = () =>
  new UploadError({
    status: 410,
    code: "call_deleted",
    retry: "never",
    message: "This call is fenced for deletion.",
  });

export const uploadStorage = <A>(operation: string, run: () => Promise<A>) =>
  Effect.tryPromise({
    try: run,
    catch: (cause) =>
      Schema.is(UploadError)(cause)
        ? cause
        : new UploadError({
            status: 503,
            code: "upload_storage_unavailable",
            retry: "retryable",
            message: `Storage could not confirm ${operation}. Replay the same request.`,
          }),
  });

export const decodeUpload = <S extends Schema.ConstraintDecoder<unknown>>(
  schema: S,
  value: unknown,
) =>
  Schema.decodeUnknownEffect(schema, { onExcessProperty: "error" })(value).pipe(
    Effect.mapError(() => invalidUpload("The request does not match the master upload contract.")),
  );

export const encodeUploadJSON = (value: unknown) =>
  Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown))(value).pipe(
    Effect.mapError(() => invalidUpload("Upload metadata could not be encoded.")),
  );
