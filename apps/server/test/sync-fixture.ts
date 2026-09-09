/* oxlint-disable effecttsgo/async-function, effecttsgo/crypto-random-uuid, effecttsgo/crypto-random-uuid-in-effect -- Disposable real D1/R2 fixtures operate at the native Worker test boundary. */
import { env } from "cloudflare:workers";
import { DateTime, Effect } from "effect";

import { validateDocument, type CallDocument } from "@trigo/contracts";

import syncMigration from "../migrations/0005_canonical_sync.sql?raw";
import { storedMaster } from "../src/master-finalization.ts";
import { productFetch } from "../src/product-handler.ts";
import {
  admitTranscriptionAttempt,
  executeTranscriptionAttempt,
} from "../src/transcription-attempts.ts";
import { recoverAndPublishTranscription } from "../src/transcription-results.ts";
import { type TranscriptionExecutionEnvironment } from "../src/transcription-submissions.ts";
import {
  createUploadedCall,
  owner,
  requestProduct,
  resetTranscriptionFixture,
  transcriptionCommand,
  transcriptionToken,
} from "./transcription-fixture.ts";

export async function resetSyncFixture() {
  for (const match of syncMigration.matchAll(/CREATE TRIGGER ([a-z_]+)/g)) {
    await env.CATALOG.prepare(`DROP TRIGGER IF EXISTS ${match[1]}`).run();
  }
  for (const table of [
    "trigo_replica_groups",
    "trigo_replica_writers",
    "trigo_replica_operations",
    "trigo_call_changes",
    "trigo_call_deletion_markers",
    "trigo_sync_epoch",
  ]) {
    await env.CATALOG.prepare(`DROP TABLE IF EXISTS ${table}`).run();
  }
  await resetTranscriptionFixture();
  await env.CATALOG.batch(
    syncMigration.split("-- statement-breakpoint").map((sql) => env.CATALOG.prepare(sql)),
  );
}

export async function finalizedSyncCall(
  runtime: TranscriptionExecutionEnvironment,
  durationMs = 1000,
) {
  const uploaded = await createUploadedCall(runtime, durationMs);
  const stored = await Effect.runPromise(
    storedMaster(runtime.CATALOG, owner.archiveId, uploaded.call.callId),
  );
  const call: CallDocument = {
    ...uploaded.call,
    documentVersion: 2,
    endedAt: DateTime.formatIso(
      DateTime.add(DateTime.makeUnsafe(uploaded.call.startedAt), { milliseconds: durationMs }),
    ),
    durationMs,
    captureState: "stopped",
    audioManifest: stored.receipt.audioManifest,
    tracks: uploaded.call.tracks.map((track) => ({
      ...track,
      intervals:
        durationMs === 0
          ? []
          : [{ startMs: 0, endMs: durationMs, state: "recorded", reason: null }],
    })),
  };
  return { call, receipt: uploaded.receipt, audioManifest: stored.audioManifest };
}

export function replicaCommand(
  call: CallDocument,
  expectedDocumentVersion: number | null,
  scopes: readonly string[] = [],
) {
  return validateDocument("PublishCallReplica", {
    schemaVersion: 1,
    operationId: crypto.randomUUID(),
    expectedDocumentVersion,
    document: JSON.stringify(call),
    annotationRevisionIds: scopes,
  });
}

export function syncRequest(
  runtime: TranscriptionExecutionEnvironment,
  method: string,
  path: string,
  body?: unknown,
  token: string = transcriptionToken,
) {
  return productFetch(
    new Request(`https://fixture.test${path}`, {
      method,
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }),
    { ...runtime, DEPLOYMENT_STAGE: "dev" },
  );
}

export async function availableSyncRevision(
  runtime: TranscriptionExecutionEnvironment,
  callId: string,
) {
  const command = transcriptionCommand();
  const response = await requestProduct(runtime, `/v1/calls/${callId}/transcriptions`, command);
  if (!response.ok) {
    throw new Error(`Fixture transcription admission failed: ${response.status}`);
  }
  const attempt = await Effect.runPromise(
    admitTranscriptionAttempt(runtime, command.operationId, 0),
  );
  if (attempt === null) {
    throw new Error("Fixture attempt missing");
  }
  await Effect.runPromise(executeTranscriptionAttempt(runtime, attempt.attempt_id));
  await Effect.runPromise(recoverAndPublishTranscription(runtime, command.operationId, attempt));
  const operationResponse = await requestProduct(runtime, `/v1/operations/${command.operationId}`);
  const operation = validateDocument("TranscriptionOperation", await operationResponse.json());
  if (operation.result === null) {
    throw new Error("Fixture result missing");
  }
  const resultResponse = await requestProduct(
    runtime,
    `/v1/calls/${callId}/revisions/${command.revisionId}`,
  );
  const revision = validateDocument("TranscriptRevision", await resultResponse.json());
  return { command, result: operation.result, revision };
}
