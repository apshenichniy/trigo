import { Context, Effect, Layer, Schema } from "effect";

import {
  RequestTranscription,
  storedByteHash,
  type TranscriptionOperation,
} from "@trigo/contracts";

import { nova3StreamProfile } from "../../../packages/contracts/src/asr-profile.ts";
import { storedMaster } from "./master-finalization.ts";
import { type MasterUploadEnvironment } from "./master-uploads.ts";
import { readBoundedBody } from "./nova-3-transport.ts";
import { type OwnerContext } from "./owner-state.ts";
import {
  currentTranscriptionFence,
  executeTranscriptionSQL,
  explainTranscriptionFence,
  operationDocument,
  readTranscription,
  requireTranscriptionOwner,
  TranscriptionRow,
  transcriptionRows,
  transcriptionTimestamp,
} from "./transcription-catalog.ts";
import {
  decodeTranscription,
  type TranscriptionError,
  transcriptionError,
  transcriptionFailure,
  transcriptionJSON,
  transcriptionStorage,
} from "./transcription-errors.ts";
import { uploadOwnerFence, uploadOwnerParameters } from "./upload-catalog.ts";

export interface TranscriptionWorkflowInput {
  readonly operationId: string;
}
export interface TranscriptionWorkflowBinding {
  readonly create: (input: {
    id: string;
    params: TranscriptionWorkflowInput;
  }) => Promise<{ id: string }>;
  readonly get: (
    id: string,
  ) => Promise<{ status: () => Promise<unknown>; restart: () => Promise<void> }>;
}
export interface TranscriptionEnvironment extends MasterUploadEnvironment {
  readonly TRANSCRIPTION_WORKFLOW?: TranscriptionWorkflowBinding;
  readonly TRANSCRIPTION_MODE?: "hosted" | "fake";
}

const workflowStatus = (instance: { status: () => Promise<unknown> }) =>
  transcriptionStorage(() => instance.status()).pipe(
    Effect.flatMap(Schema.decodeUnknownEffect(Schema.Struct({ status: Schema.String }))),
    Effect.mapError(() => transcriptionError("asr_storage_unavailable", "retryable", 503)),
    Effect.map((status) => status.status),
  );

/** An acknowledgement lost after Workflow.create resolves through that same instance identity.
 * Restart replays storage work; the D1 admission ledger still forbids duplicate paid calls. */
const dispatchTranscription = Effect.fn("Transcription.dispatch")(function* (
  workflow: TranscriptionWorkflowBinding,
  operation: TranscriptionRow,
) {
  if (operation.state !== "queued" && operation.state !== "running") {
    return;
  }
  yield* transcriptionStorage(() =>
    workflow.create({
      id: operation.operation_id,
      params: { operationId: operation.operation_id },
    }),
  ).pipe(
    Effect.catchTag("Transcription.Error", () =>
      Effect.gen(function* () {
        const instance = yield* transcriptionStorage(() => workflow.get(operation.operation_id));
        const status = yield* workflowStatus(instance);
        if (status === "paused" || status === "terminated") {
          return yield* transcriptionError("asr_workflow_stopped", "after_correction", 409);
        }
        if (status === "errored" || status === "complete") {
          yield* transcriptionStorage(() => instance.restart());
        }
      }),
    ),
  );
});

const requestTranscription = Effect.fn("Transcription.request")(function* (
  env: TranscriptionEnvironment,
  owner: OwnerContext,
  callId: string,
  value: unknown,
) {
  yield* requireTranscriptionOwner(env.CATALOG, owner);
  if (!env.TRANSCRIPTION_WORKFLOW || !env.TRANSCRIPTION_MODE) {
    return yield* transcriptionError("asr_unavailable", "after_correction", 501);
  }
  const input = yield* decodeTranscription(RequestTranscription, value);
  if (input.requestedLanguage === "uk") {
    return yield* transcriptionError("asr_language_unsupported", "after_correction", 422);
  }
  if (
    input.operationId === input.revisionId ||
    input.operationId === callId ||
    input.revisionId === callId
  ) {
    return yield* transcriptionError("asr_invalid");
  }
  const commandHash = yield* transcriptionJSON(input).pipe(
    Effect.flatMap((text) => Effect.promise(() => storedByteHash(new TextEncoder().encode(text)))),
  );
  const [existing] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionRow,
    "SELECT * FROM trigo_transcription_operations WHERE operation_id=?",
    [input.operationId],
  );
  if (existing) {
    if (
      existing.archive_id !== owner.archiveId ||
      existing.call_id !== callId ||
      existing.command_hash !== commandHash
    ) {
      return yield* transcriptionError("asr_conflict", "after_correction", 409);
    }
    yield* requireStoredMaster(env, owner.archiveId, callId);
    yield* dispatchTranscription(env.TRANSCRIPTION_WORKFLOW, existing);
    return yield* operationDocument(
      env.CATALOG,
      yield* readTranscription(env.CATALOG, input.operationId),
    );
  }
  yield* requireStoredMaster(env, owner.archiveId, callId);
  const now = yield* transcriptionTimestamp();
  yield* executeTranscriptionSQL(
    env.CATALOG,
    `INSERT OR IGNORE INTO trigo_transcription_operations
     (operation_id,archive_id,call_id,generation,owner_generation,command_hash,revision_id,requested_language,profile_id,state,created_at,updated_at)
     SELECT ?,?,?,COALESCE((SELECT MAX(generation) FROM trigo_transcription_operations WHERE call_id=?),0)+1,?,?,?,?,?,'queued',?,?
     WHERE ${uploadOwnerFence} AND EXISTS (
       SELECT 1 FROM trigo_master_uploads WHERE call_id=? AND archive_id=? AND deletion_state='active'
     ) AND NOT EXISTS (
       SELECT 1 FROM trigo_transcription_operations WHERE call_id=? AND state IN ('queued','running')
     )`,
    [
      input.operationId,
      owner.archiveId,
      callId,
      callId,
      owner.credentialGeneration,
      commandHash,
      input.revisionId,
      input.requestedLanguage,
      nova3StreamProfile.id,
      now,
      now,
      ...uploadOwnerParameters(owner),
      callId,
      owner.archiveId,
      callId,
    ],
  );
  yield* requireTranscriptionOwner(env.CATALOG, owner);
  const [admitted] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionRow,
    "SELECT * FROM trigo_transcription_operations WHERE operation_id=?",
    [input.operationId],
  );
  if (!admitted) {
    const active = yield* transcriptionRows(
      env.CATALOG,
      TranscriptionRow,
      "SELECT * FROM trigo_transcription_operations WHERE call_id=? AND state IN ('queued','running')",
      [callId],
    );
    return yield* transcriptionError(
      active.length > 0 ? "asr_already_processing" : "asr_conflict",
      "after_correction",
      409,
    );
  }
  if (
    admitted.archive_id !== owner.archiveId ||
    admitted.call_id !== callId ||
    admitted.command_hash !== commandHash
  ) {
    return yield* transcriptionError("asr_conflict", "after_correction", 409);
  }
  yield* dispatchTranscription(env.TRANSCRIPTION_WORKFLOW, admitted);
  return yield* operationDocument(
    env.CATALOG,
    yield* readTranscription(env.CATALOG, input.operationId),
  );
});

export const requireStoredMaster = Effect.fn("Transcription.storedMaster")(
  (env: MasterUploadEnvironment, archiveId: string, callId: string) =>
    storedMaster(env.CATALOG, archiveId, callId).pipe(
      Effect.mapError((error) => {
        if (error.code === "call_deleted") {
          return transcriptionError("call_deleted", "never", 410);
        }
        if (error.status === 409) {
          return transcriptionError("asr_audio_pending", "retryable", 409);
        }
        if (error.status === 404) {
          return transcriptionError("asr_not_found", "after_correction", 404);
        }
        return transcriptionError("asr_storage_unavailable", "retryable", 503);
      }),
    ),
);

const getOperation = Effect.fn("Transcription.getOperation")(function* (
  env: TranscriptionEnvironment,
  owner: OwnerContext,
  operationId: string,
) {
  yield* requireTranscriptionOwner(env.CATALOG, owner);
  const operation = yield* readTranscription(env.CATALOG, operationId);
  if (operation.archive_id !== owner.archiveId) {
    return yield* transcriptionError("asr_not_found", "after_correction", 404);
  }
  yield* requireStoredMaster(env, owner.archiveId, operation.call_id);
  // This path never dispatches a Workflow or invokes a provider.
  const document = yield* operationDocument(env.CATALOG, operation);
  if (
    (operation.state !== "queued" && operation.state !== "running") ||
    !env.TRANSCRIPTION_WORKFLOW
  ) {
    return document;
  }
  const workflow = env.TRANSCRIPTION_WORKFLOW;
  const observed = yield* transcriptionStorage(() => workflow.get(operationId)).pipe(
    Effect.flatMap(workflowStatus),
    Effect.result,
  );
  let failure = document.failure;
  if (observed._tag === "Failure") {
    failure = transcriptionFailure("asr_storage_unavailable", "retryable");
  } else if (observed.success === "errored" || observed.success === "complete") {
    failure = transcriptionFailure("asr_workflow_interrupted", "retryable");
  } else if (observed.success === "paused" || observed.success === "terminated") {
    failure = transcriptionFailure("asr_workflow_stopped", "after_correction");
  }
  // oxlint-disable-next-line typescript/no-misused-spread -- The service returns a plain exchange record, not a runtime class.
  return { ...document, failure };
});

export const maximumRevisionBytes = 16_000_000;
export const maximumProvenanceBytes = 65_536;

export const readTranscriptArtifact = Effect.fn("Transcription.getRevision")(function* (
  env: TranscriptionEnvironment,
  owner: OwnerContext,
  callId: string,
  revisionId: string,
  provenance: boolean,
) {
  yield* requireTranscriptionOwner(env.CATALOG, owner);
  yield* requireStoredMaster(env, owner.archiveId, callId);
  const [operation] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionRow,
    "SELECT * FROM trigo_transcription_operations WHERE archive_id=? AND call_id=? AND revision_id=? AND state='result_available'",
    [owner.archiveId, callId, revisionId],
  );
  if (!operation) {
    return yield* transcriptionError("asr_not_found", "after_correction", 404);
  }
  const key = provenance ? operation.provenance_key : operation.result_key;
  const expectedHash = provenance ? operation.provenance_sha256 : operation.result_sha256;
  const expectedBytes = provenance
    ? operation.provenance_byte_length
    : operation.result_byte_length;
  if (key === null || expectedHash === null || expectedBytes === null) {
    return yield* transcriptionError("asr_catalog_invalid", "after_correction", 503);
  }
  const object = yield* transcriptionStorage(() => env.ARCHIVE.get(key));
  if (!object || !("body" in object) || object.size !== expectedBytes) {
    return yield* transcriptionError("asr_storage_unavailable", "retryable", 503);
  }
  const bytes = yield* readBoundedBody(
    object.body,
    provenance ? maximumProvenanceBytes : maximumRevisionBytes,
  ).pipe(Effect.mapError(() => transcriptionError("asr_result_invalid", "after_correction", 503)));
  if ((yield* Effect.promise(() => storedByteHash(bytes))) !== expectedHash) {
    return yield* transcriptionError("asr_result_invalid", "after_correction", 503);
  }
  yield* requireTranscriptionOwner(env.CATALOG, owner);
  yield* requireStoredMaster(env, owner.archiveId, callId);
  return { bytes, sha256: expectedHash };
});

export class Transcriptions extends Context.Service<
  Transcriptions,
  {
    readonly request: (
      callId: string,
      input: unknown,
    ) => Effect.Effect<TranscriptionOperation, TranscriptionError>;
    readonly operation: (
      operationId: string,
    ) => Effect.Effect<TranscriptionOperation, TranscriptionError>;
    readonly revision: (
      callId: string,
      revisionId: string,
      provenance: boolean,
    ) => Effect.Effect<{ bytes: Uint8Array; sha256: string }, TranscriptionError>;
  }
>()("trigo/Transcriptions") {}

export const transcriptionsLayer = (env: TranscriptionEnvironment, owner: OwnerContext) =>
  Layer.succeed(Transcriptions, {
    request: (callId, value) => requestTranscription(env, owner, callId, value),
    operation: (operationId) => getOperation(env, owner, operationId),
    revision: (callId, revisionId, provenance) =>
      readTranscriptArtifact(env, owner, callId, revisionId, provenance),
  });

/** Publication and attempt admission share this predicate rather than trusting Workflow history. */
export const isCurrentTranscription = Effect.fn("Transcription.current")(function* (
  env: TranscriptionEnvironment,
  operationId: string,
) {
  const [row] = yield* transcriptionRows(
    env.CATALOG,
    TranscriptionRow,
    `SELECT o.* FROM trigo_transcription_operations o WHERE o.operation_id=? AND ${currentTranscriptionFence}`,
    [operationId],
  );
  if (!row) {
    return yield* explainTranscriptionFence(
      env.CATALOG,
      yield* readTranscription(env.CATALOG, operationId),
    );
  }
  return row;
});
