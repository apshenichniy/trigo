import { Effect, Schema, Struct } from "effect";

import { type UploadError } from "./upload-errors.ts";

const failures = {
  playback_invalid: [400, "after_correction", "The playback request is invalid."],
  playback_conflict: [409, "after_correction", "This playback operation belongs to another call."],
  playback_not_stored: [409, "retryable", "The complete call audio is not stored yet."],
  playback_no_audio: [409, "never", "This call has no retained audio frames."],
  playback_not_found: [404, "never", "This call audio is unavailable."],
  playback_grant_invalid: [401, "retryable", "Playback access is invalid. Request a new grant."],
  playback_grant_expired: [
    401,
    "retryable",
    "Playback access expired. Renew it at the same position.",
  ],
  playback_owner_changed: [
    401,
    "after_correction",
    "Owner access changed. Reconnect to this archive.",
  ],
  playback_deleted: [410, "never", "This call is no longer available for playback."],
  playback_range_invalid: [416, "never", "This media range is outside the requested segment."],
  playback_catalog_invalid: [
    503,
    "after_correction",
    "Retained playback metadata could not be verified.",
  ],
  playback_storage_unavailable: [503, "retryable", "The audio server is temporarily unavailable."],
} as const;

export const PlaybackErrorCode = Schema.Literals(Struct.keys(failures));
export class PlaybackError extends Schema.TaggedError<PlaybackError>()("Playback.Error", {
  code: PlaybackErrorCode,
  status: Schema.Int,
  retry: Schema.Literals(["never", "retryable", "after_correction"]),
  message: Schema.String,
  totalByteLength: Schema.optional(Schema.Int),
}) {}

export const playbackError = (code: keyof typeof failures, totalByteLength?: number) => {
  const [status, retry, message] = failures[code];
  return new PlaybackError({
    code,
    status,
    retry,
    message,
    ...(totalByteLength === undefined ? {} : { totalByteLength }),
  });
};
export const playbackStorage = <A>(action: () => Promise<A>) =>
  Effect.tryPromise({ try: action, catch: () => playbackError("playback_storage_unavailable") });

export function playbackUploadError(error: UploadError): PlaybackError {
  if (error.code === "call_deleted") {
    return playbackError("playback_deleted");
  }
  if (error.code === "upload_not_found") {
    return playbackError("playback_not_found");
  }
  if (error.code === "upload_incomplete") {
    return playbackError("playback_not_stored");
  }
  if (error.code === "upload_owner_changed") {
    return playbackError("playback_owner_changed");
  }
  return playbackError(
    error.retry === "retryable" ? "playback_storage_unavailable" : "playback_catalog_invalid",
  );
}
