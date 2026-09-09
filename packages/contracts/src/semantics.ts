import { selectedCaptureMasterProfile } from "./capture-master-profile.ts";
import type { CallDocument } from "./document-schema.ts";
import { frameCountForDuration, selectedMediaProfile, waveByteLength } from "./media-profile.ts";
export function requireValid(condition: unknown): asserts condition {
  if (!condition) {
    throw new Error("semantics");
  }
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
  if (call.endedAt !== null) {
    requireValid(Date.parse(call.endedAt) >= Date.parse(call.startedAt));
  }
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
    if (finalized) {
      requireValid(cursor === call.durationMs);
    }
  }
  unique(call.revisions.map((r) => r.revisionId));
  requireValid(
    call.activeRevisionId === null ||
      call.revisions.some((r) => r.revisionId === call.activeRevisionId),
  );
  const groupIds: string[] = [];
  for (const [revisionId, groups] of Object.entries(call.speakerGroups)) {
    requireValid(call.revisions.some((revision) => revision.revisionId === revisionId));
    const members: string[] = [];
    for (const group of groups) {
      groupIds.push(group.groupId);
      members.push(...group.speakerIds);
      unique(group.speakerIds);
    }
    unique(members);
  }
  unique(groupIds);
}
export function validateRevision(
  revision: import("./document-schema.ts").TranscriptRevision,
): void {
  unique(revision.speakers.map((s) => s.speakerId));
  unique(revision.turns.map((t) => t.turnId));
  let previousStart = 0;
  const previousTrackStarts = new Map<string, number>();
  for (const turn of revision.turns) {
    requireValid(turn.endMs >= turn.startMs);
    if (revision.normalizationVersion === 1) {
      requireValid(turn.startMs >= previousStart);
      previousStart = turn.startMs;
    } else if (!turn.words.some((word) => word.timingUncertain === true)) {
      requireValid(turn.startMs >= (previousTrackStarts.get(turn.trackId) ?? 0));
      previousTrackStarts.set(turn.trackId, turn.startMs);
    }
    if (turn.speakerId !== null) {
      requireValid(
        revision.speakers.some((s) => s.speakerId === turn.speakerId && s.trackId === turn.trackId),
      );
    }
    let cursor = turn.startMs;
    for (const word of turn.words) {
      requireValid(revision.normalizationVersion === 2 || word.timingUncertain === undefined);
      if (word.timingUncertain === true) {
        continue;
      }
      requireValid(
        word.startMs >= cursor && word.endMs >= word.startMs && word.endMs <= turn.endMs,
      );
      cursor = word.endMs;
    }
  }
}
export function validateAudio(audio: import("./document-schema.ts").AudioManifest): void {
  const master = audio.mediaProfileId === selectedCaptureMasterProfile.id;
  requireValid(master || audio.mediaProfileId === selectedMediaProfile.id);
  if (master) {
    requireValid(
      audio.durationMs <= selectedCaptureMasterProfile.maxCallDurationMs &&
        audio.objects.length === (audio.durationMs === 0 ? 0 : 1),
    );
  }
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
      (master
        ? object.contentType === selectedCaptureMasterProfile.contentType &&
          object.index === 0 &&
          object.startMs === 0 &&
          object.endMs === audio.durationMs &&
          object.byteLength === selectedCaptureMasterProfile.headerBytes + durationMs * 64
        : object.contentType === selectedMediaProfile.contentType &&
          durationMs <= selectedMediaProfile.objectDurationMs &&
          object.byteLength === waveByteLength(frameCountForDuration(durationMs)) &&
          object.byteLength <= selectedMediaProfile.maxObjectBytes &&
          object.byteLength <= selectedMediaProfile.limits.uploadRequestBytes) &&
        object.channelMap.length === selectedMediaProfile.channels.length &&
        selectedMediaProfile.channels.every((expected) =>
          object.channelMap.some((channel) => channel.channelIndex === expected.index),
        ),
    );
  }
}
