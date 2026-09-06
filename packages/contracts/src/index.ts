import { Result, Schema } from "effect";
import { documentSchemas, type Documents, type DocumentKind } from "./document-schema.ts";
import { validateCall, validateRevision, validateAudio } from "./semantics.ts";
import { selectedMediaProfile } from "./media-profile.ts";
export {
  AsrProbeLanguage,
  AsrProbeTranscriptionResponse,
  AsrProbeUploadResponse,
} from "./asr-probe.ts";
export type {
  AsrProbeLanguage as AsrProbeLanguageCode,
  AsrProbeTranscriptionResponse as AsrProbeTranscriptionResponseDocument,
  AsrProbeUploadResponse as AsrProbeUploadResponseDocument,
} from "./asr-probe.ts";
export { ErrorEnvelopeSchema } from "./document-schema.ts";
export {
  frameCountForDuration,
  inspectWaveObject,
  makeWaveHeader,
  MediaProfile,
  MediaSourceRole,
  objectCountForDuration,
  selectedMediaProfile,
  waveByteLength,
} from "./media-profile.ts";
export type {
  MediaProfile as MediaProfileDocument,
  WaveObjectInspection,
} from "./media-profile.ts";
import type { CallDocument, TranscriptRevision, AudioManifest } from "./document-schema.ts";
export * from "./document-schema.ts";
function decoder<S extends Schema.ConstraintDecoder<unknown>>(schema: S) {
  const decode = Schema.decodeUnknownResult(schema, { onExcessProperty: "error" });
  return (value: unknown): S["Type"] => {
    const result = decode(value);
    if (Result.isFailure(result)) throw new Error("structure");
    return result.success;
  };
}
const decoders: { [K in DocumentKind]: (value: unknown) => Documents[K] } = {
  CallDocument: decoder(documentSchemas.CallDocument),
  TranscriptRevision: decoder(documentSchemas.TranscriptRevision),
  AudioManifest: decoder(documentSchemas.AudioManifest),
  StatusResponse: decoder(documentSchemas.StatusResponse),
  CommandIdentity: decoder(documentSchemas.CommandIdentity),
  ErrorEnvelope: decoder(documentSchemas.ErrorEnvelope),
};
/** Structural validation only; referenced documents must be supplied to validateArchive. */
export function validateStructure<K extends DocumentKind>(kind: K, value: unknown): Documents[K] {
  return decoders[kind](value);
}
export function validateDocument<K extends DocumentKind>(kind: K, value: unknown): Documents[K] {
  const document = validateStructure(kind, value);
  if (kind === "CallDocument") validateCall(document as CallDocument);
  if (kind === "TranscriptRevision") validateRevision(document as TranscriptRevision);
  if (kind === "AudioManifest") validateAudio(document as AudioManifest);
  return document;
}
export async function storedByteHash(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return Array.from(new Uint8Array(hash), (n) => n.toString(16).padStart(2, "0")).join("");
}
export function parseStored<K extends DocumentKind>(kind: K, bytes: Uint8Array): Documents[K] {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Error("structure");
  }
  return validateDocument(kind, value);
}
export interface ValidatedArchive {
  call: CallDocument;
  audio: AudioManifest | null;
  revisions: ReadonlyMap<string, TranscriptRevision>;
  stored: ReadonlyMap<string, Uint8Array>;
}
export async function validateArchive(
  callBytes: Uint8Array,
  references: ReadonlyMap<string, Uint8Array>,
): Promise<ValidatedArchive> {
  const call = parseStored("CallDocument", callBytes);
  const stored = new Map<string, Uint8Array>();
  async function resolve<K extends DocumentKind>(
    kind: K,
    id: string,
    hash: string,
  ): Promise<Documents[K]> {
    const source = references.get(id);
    if (!source) throw new Error("reference");
    const bytes = new Uint8Array(source);
    if ((await storedByteHash(bytes)) !== hash) throw new Error("checksum");
    const document = parseStored(kind, bytes);
    stored.set(id, bytes);
    return document;
  }
  const audio = call.audioManifest
    ? await resolve("AudioManifest", call.audioManifest.manifestId, call.audioManifest.sha256)
    : null;
  const check = (condition: unknown) => {
    if (!condition) throw new Error("reference");
  };
  if (audio) {
    check(
      audio.callId === call.callId &&
        audio.manifestId === call.audioManifest?.manifestId &&
        audio.durationMs === call.durationMs,
    );
    for (const track of call.tracks) check(track.mediaProfileId === audio.mediaProfileId);
    for (const object of audio.objects)
      for (const expected of selectedMediaProfile.channels) {
        const channel = object.channelMap.find(
          (candidate) => candidate.channelIndex === expected.index,
        );
        check(
          channel !== undefined &&
            call.tracks.some(
              (track) => track.trackId === channel.trackId && track.role === expected.role,
            ),
        );
      }
    for (const track of call.tracks) {
      let cursor = 0;
      for (const object of audio.objects.filter((o) =>
        o.channelMap.some((c) => c.trackId === track.trackId),
      )) {
        check(object.startMs === cursor);
        cursor = object.endMs;
      }
      check(cursor === audio.durationMs);
    }
  }
  const revisions = new Map<string, TranscriptRevision>();
  const speakerIds = new Set<string>();
  const turnIds = new Set<string>();
  for (const ref of call.revisions) {
    const revision = await resolve("TranscriptRevision", ref.revisionId, ref.sha256);
    check(
      revision.callId === call.callId &&
        revision.revisionId === ref.revisionId &&
        revision.createdAt === ref.createdAt,
    );
    check(
      audio &&
        revision.audioManifest.manifestId === audio.manifestId &&
        revision.audioManifest.sha256 === call.audioManifest?.sha256,
    );
    for (const speaker of revision.speakers)
      check(call.tracks.some((t) => t.trackId === speaker.trackId));
    for (const turn of revision.turns)
      check(
        call.tracks.some((t) => t.trackId === turn.trackId) &&
          turn.endMs <= (call.durationMs ?? -1),
      );
    for (const speaker of revision.speakers) {
      check(!speakerIds.has(speaker.speakerId));
      speakerIds.add(speaker.speakerId);
    }
    for (const turn of revision.turns) {
      check(!turnIds.has(turn.turnId));
      turnIds.add(turn.turnId);
    }
    revisions.set(ref.revisionId, revision);
  }
  for (const [revisionId, names] of Object.entries(call.speakerNames)) {
    const revision = revisions.get(revisionId);
    check(revision);
    for (const speakerId of Object.keys(names))
      check(revision?.speakers.some((s) => s.speakerId === speakerId));
  }
  return { call, audio, revisions, stored };
}
export { default as routes } from "../schema/routes.v1.json";
/** Capture the byte identity before parsing; serialization is a separate operation. */
export async function readStoredDocument<K extends DocumentKind>(kind: K, input: Uint8Array) {
  const bytes = new Uint8Array(input);
  const sha256 = await storedByteHash(bytes);
  const value = parseStored(kind, bytes);
  return {
    value,
    sha256,
    get storedBytes() {
      return new Uint8Array(bytes);
    },
  };
}
