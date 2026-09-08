import { Effect, Schema, Struct } from "effect";

import { type TranscriptionFailure } from "@trigo/contracts";

const messages = {
  asr_invalid: "The transcription request does not match the supported contract.",
  asr_language_unsupported:
    "This hosted profile supports English and Russian. Select a supported language.",
  asr_conflict: "This operation identity already describes different content.",
  asr_already_processing: "This call already has an active transcription request.",
  asr_not_found: "The requested transcription operation or result is unavailable.",
  asr_audio_pending: "The complete recording master must be verified before transcription.",
  asr_owner_changed: "Owner access changed. Reconnect with the current credential before retrying.",
  asr_superseded: "A newer transcription operation or attempt has replaced this work.",
  call_deleted: "This call is fenced for deletion.",
  asr_storage_unavailable:
    "Transcription storage is temporarily unavailable. The admitted operation remains recoverable.",
  asr_workflow_interrupted:
    "Transcription processing was interrupted. Resume the same operation to recover retained results.",
  asr_workflow_stopped:
    "The transcription Workflow was paused or terminated. Restore it in server administration before retrying.",
  asr_catalog_invalid:
    "Retained transcription metadata could not be validated. Preserve the archive and review server diagnostics.",
  asr_submission_uncertain:
    "The provider outcome is uncertain. Retained results are checked before the bounded replacement attempt.",
  asr_attempt_limit:
    "The original and one replacement attempt are exhausted. Retained audio and successful evidence remain available.",
  asr_configuration: "The hosted transcription binding or model configuration requires correction.",
  asr_funds: "Hosted transcription requires an available provider balance or quota.",
  asr_input_rejected:
    "The provider rejected this audio or language profile. Retained audio has not been changed.",
  asr_result_invalid:
    "The provider result could not be validated against the complete audio and source scopes.",
  asr_result_too_large:
    "The provider result exceeds the supported retention bound. Its retained prefix is diagnostic evidence only.",
  asr_unavailable: "Transcription is not configured for this server.",
} as const;
export const TranscriptionErrorCode = Schema.Literals(Struct.keys(messages));
export type TranscriptionErrorCode = Schema.Schema.Type<typeof TranscriptionErrorCode>;

export class TranscriptionError extends Schema.TaggedError<TranscriptionError>()(
  "Transcription.Error",
  {
    status: Schema.Int,
    code: TranscriptionErrorCode,
    retry: Schema.Literals(["never", "after_correction", "retryable"]),
    message: Schema.String,
  },
) {}

export function transcriptionFailure(
  code: TranscriptionErrorCode,
  retry: TranscriptionFailure["retry"],
): TranscriptionFailure {
  return { code, retry, message: messages[code] };
}
export function transcriptionError(
  code: TranscriptionErrorCode,
  retry: TranscriptionFailure["retry"] = "after_correction",
  status = 400,
) {
  return new TranscriptionError({ status, code, retry, message: messages[code] });
}
export const transcriptionStorage = <A>(run: () => Promise<A>) =>
  Effect.tryPromise({
    try: run,
    catch: (cause) =>
      Schema.is(TranscriptionError)(cause)
        ? cause
        : transcriptionError("asr_storage_unavailable", "retryable", 503),
  });

export const decodeTranscription = <S extends Schema.ConstraintDecoder<unknown>>(
  schema: S,
  input: unknown,
) =>
  Schema.decodeUnknownEffect(schema, { onExcessProperty: "error" })(input).pipe(
    Effect.mapError(() => transcriptionError("asr_invalid")),
  );

export const transcriptionJSON = (value: unknown) =>
  Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown))(value).pipe(
    Effect.mapError(() => transcriptionError("asr_result_invalid")),
  );
