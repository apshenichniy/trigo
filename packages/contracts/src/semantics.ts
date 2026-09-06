import type { CallDocument } from "./generated/documents.d.ts";
import { frameCountForDuration, selectedMediaProfile, waveByteLength } from "./media-profile.ts";
export function requireValid(condition: unknown): asserts condition {
  if (!condition) throw new Error("semantics");
}
export function unique(values: readonly unknown[]): void {
  requireValid(new Set(values).size === values.length);
}
export function validateCall(call: CallDocument): void {
  unique(call.tracks.map((t) => t.trackId));
  unique(call.tracks.map((t) => t.role));
  const finalized = call.captureState !== "recording";
  requireValid(
    finalized
      ? call.durationMs !== null && call.endedAt !== null
      : call.durationMs === null && call.endedAt === null,
  );
  if (call.endedAt !== null) requireValid(Date.parse(call.endedAt) >= Date.parse(call.startedAt));
  requireValid(
    call.captureState === "interrupted"
      ? call.interruptionReason !== null
      : call.interruptionReason === null,
  );
  for (const track of call.tracks) {
    let cursor = 0;
    for (const interval of track.intervals) {
      requireValid(interval.endMs > interval.startMs && interval.startMs === cursor);
      requireValid(interval.state !== "muted" || track.role === "microphone");
      cursor = interval.endMs;
    }
    if (finalized) requireValid(cursor === call.durationMs);
  }
  unique(call.revisions.map((r) => r.revisionId));
  requireValid(
    call.activeRevisionId === null ||
      call.revisions.some((r) => r.revisionId === call.activeRevisionId),
  );
}
export function validateRevision(
  revision: import("./generated/documents.d.ts").TranscriptRevision,
): void {
  unique(revision.speakers.map((s) => s.speakerId));
  unique(revision.turns.map((t) => t.turnId));
  let previousStart = 0;
  for (const turn of revision.turns) {
    requireValid(turn.startMs >= previousStart && turn.endMs >= turn.startMs);
    previousStart = turn.startMs;
    if (turn.speakerId !== null)
      requireValid(
        revision.speakers.some((s) => s.speakerId === turn.speakerId && s.trackId === turn.trackId),
      );
    let cursor = turn.startMs;
    for (const word of turn.words) {
      requireValid(
        word.startMs >= cursor && word.endMs >= word.startMs && word.endMs <= turn.endMs,
      );
      cursor = word.endMs;
    }
  }
}
export function validateAudio(audio: import("./generated/documents.d.ts").AudioManifest): void {
  requireValid(audio.mediaProfileId === selectedMediaProfile.id);
  unique(audio.objects.map((o) => o.objectId));
  unique(audio.objects.map((o) => o.index));
  let index = -1;
  let start = 0;
  for (const object of audio.objects) {
    requireValid(
      object.index > index &&
        object.startMs >= start &&
        object.endMs > object.startMs &&
        object.endMs <= audio.durationMs,
    );
    index = object.index;
    start = object.startMs;
    unique(object.channelMap.map((c) => c.channelIndex));
    unique(object.channelMap.map((c) => c.trackId));
    const durationMs = object.endMs - object.startMs;
    requireValid(
      object.contentType === selectedMediaProfile.contentType &&
        object.byteLength === waveByteLength(frameCountForDuration(durationMs)) &&
        object.channelMap.length === selectedMediaProfile.channels.length &&
        selectedMediaProfile.channels.every((expected) =>
          object.channelMap.some((channel) => channel.channelIndex === expected.index),
        ),
    );
  }
}
