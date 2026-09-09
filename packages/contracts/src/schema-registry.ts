import { Schema } from "effect";

import { CaptureMasterProfile } from "./capture-master-profile.ts";
import {
  AudioManifest,
  CallDocument,
  LegacyCallDocument,
  CommandIdentity,
  ErrorEnvelope,
  LocalDevelopmentBridge,
  StatusResponse,
  TranscriptRevision,
} from "./document-schema.ts";
import { playbackSchemas } from "./playback-schema.ts";
import { syncSchemas } from "./sync-schema.ts";
import { transcriptionSchemas } from "./transcription-schema.ts";
import { uploadSchemas } from "./upload-schema.ts";

/** Leaf schemas do not import this registry, keeping cross-domain references acyclic. */
export const documentSchemas = {
  LocalDevelopmentBridge,
  CaptureMasterProfile,
  CallDocument,
  LegacyCallDocument,
  TranscriptRevision,
  AudioManifest,
  StatusResponse,
  CommandIdentity,
  ErrorEnvelope,
  ...uploadSchemas,
  ...transcriptionSchemas,
  ...syncSchemas,
  ...playbackSchemas,
};
export type Documents = {
  [K in keyof typeof documentSchemas]: Schema.Schema.Type<(typeof documentSchemas)[K]>;
};
export type DocumentKind = keyof Documents;
