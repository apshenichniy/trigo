/* Generated from schema/v1.schema.json. Do not edit. */

export type TrigoV1 =
  CallDocument | TranscriptRevision | AudioManifest | StatusResponse | CommandIdentity | ErrorEnvelope;

export interface CallDocument {
  schemaVersion: 1;
  archiveId: string;
  callId: string;
  documentVersion: number;
  startedAt: string;
  endedAt: string | null;
  durationMs: number | null;
  captureState: "recording" | "stopped" | "interrupted";
  interruptionReason: string | null;
  source: {
    applicationName: string;
    bundleId: string;
    processId: number;
    windowId: number | null;
    windowTitle: string | null;
  };
  /**
   * @minItems 2
   * @maxItems 2
   */
  tracks: [
    {
      trackId: string;
      role: "microphone" | "application";
      inputDevice: {
        id: string;
        name: string;
      } | null;
      mediaProfileId: string;
      intervals: {
        startMs: number;
        endMs: number;
        state: "recorded" | "muted" | "unavailable";
        reason: string | null;
      }[];
    },
    {
      trackId: string;
      role: "microphone" | "application";
      inputDevice: {
        id: string;
        name: string;
      } | null;
      mediaProfileId: string;
      intervals: {
        startMs: number;
        endMs: number;
        state: "recorded" | "muted" | "unavailable";
        reason: string | null;
      }[];
    }
  ];
  audioManifest: {
    manifestId: string;
    sha256: string;
  } | null;
  revisions: {
    revisionId: string;
    createdAt: string;
    sha256: string;
  }[];
  activeRevisionId: string | null;
  speakerNames: {
    [k: string]: {
      [k: string]: string;
    };
  };
}
export interface TranscriptRevision {
  schemaVersion: 1;
  callId: string;
  revisionId: string;
  createdAt: string;
  audioManifest: {
    manifestId: string;
    sha256: string;
  };
  normalizationVersion: 1;
  asr: {
    adapter: string;
    model: string;
    profileId: string;
    requestedLanguage: string;
    detectedLanguages: string[];
    effectiveOptions: {
      [k: string]: string | number | boolean | null;
    };
    returnedModelVersion: string | null;
    providerRequestIds: string[];
  };
  speakers: {
    speakerId: string;
    trackId: string;
    diarizationScopeId: string;
    providerLabel: string | null;
  }[];
  turns: {
    turnId: string;
    trackId: string;
    speakerId: string | null;
    startMs: number;
    endMs: number;
    text: string;
    words: {
      text: string;
      startMs: number;
      endMs: number;
      confidence: number | null;
    }[];
  }[];
}
export interface AudioManifest {
  schemaVersion: 1;
  callId: string;
  manifestId: string;
  durationMs: number;
  mediaProfileId: string;
  objects: {
    objectId: string;
    index: number;
    contentType: string;
    byteLength: number;
    sha256: string;
    startMs: number;
    endMs: number;
    /**
     * @minItems 1
     */
    channelMap: [
      {
        channelIndex: number;
        trackId: string;
      },
      ...{
        channelIndex: number;
        trackId: string;
      }[]
    ];
  }[];
}
export interface StatusResponse {
  schemaVersion: 1;
  apiVersion: 1;
  archiveId: string;
  stage: "dev" | "personal";
  readiness: {
    archive: "ready";
    ownerAuthentication: "ready";
    transcription: "ready" | "not_verified" | "unavailable";
    callOperations: "ready" | "unavailable";
  };
  errors: {
    code: string;
    retry: "never" | "after_correction" | "retryable";
    message: string;
  }[];
}
export interface CommandIdentity {
  schemaVersion: 1;
  operationId: string;
}
export interface ErrorEnvelope {
  schemaVersion: 1;
  error: {
    code: string;
    retry: "never" | "after_correction" | "retryable";
    message: string;
    requestId: string;
  };
}
