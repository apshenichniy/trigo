/* oxlint-disable effecttsgo/async-function, effecttsgo/crypto-random-uuid -- Real Worker I/O and deterministic injected failures are exercised through the public HTTP boundary. */
import { env } from "cloudflare:workers";
import { Effect, Struct } from "effect";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  parseCallDocument,
  storedByteHash,
  validateDocument,
  type CallDocument,
} from "@trigo/contracts";

import { inspectReplicaWriters } from "../src/replica-writers.ts";
import { fenceMasterUploads } from "../src/upload-catalog.ts";
import {
  availableSyncRevision,
  finalizedSyncCall,
  replicaCommand,
  resetSyncFixture,
  syncRequest,
} from "./sync-fixture.ts";
import { fixtureRuntime, owner, speechRunner } from "./transcription-fixture.ts";

beforeEach(resetSyncFixture);

describe("canonical replica publication and restoration catalog", () => {
  it("keeps the full base snapshot exact, replays publication and retains older receipts", async () => {
    const runtime = fixtureRuntime();
    const { call, audioManifest } = await finalizedSyncCall(runtime);
    const path = `/v1/calls/${call.callId}/document`;
    const input = { ...replicaCommand(call, null), document: ` \n${JSON.stringify(call)}\n` };
    const responses = await Promise.all([
      syncRequest(runtime, "PUT", path, input),
      syncRequest(runtime, "PUT", path, input),
    ]);
    for (const response of responses) {
      expect(response.status, await response.clone().text()).toBe(200);
    }
    const receipt = validateDocument("ReplicaReceipt", await responses[0]!.json());
    expect(validateDocument("ReplicaReceipt", await responses[1]!.json())).toEqual(receipt);
    const bytes = new TextEncoder().encode(input.document);
    expect(receipt.sha256).toBe(await storedByteHash(bytes));
    const download = await syncRequest(runtime, "GET", path);
    expect(await download.text()).toBe(input.document);
    expect(download.headers.get("x-trigo-content-sha256")).toBe(receipt.sha256);
    expect(
      await (await syncRequest(runtime, "GET", `/v1/calls/${call.callId}/audio-manifest`)).text(),
    ).toBe(audioManifest);
    const next = Struct.assign(call, { documentVersion: call.documentVersion + 1 });
    expect(
      (await syncRequest(runtime, "PUT", path, replicaCommand(next, call.documentVersion))).status,
    ).toBe(200);
    expect(
      validateDocument(
        "ReplicaReceipt",
        await (await syncRequest(runtime, "PUT", path, input)).json(),
      ),
    ).toEqual(receipt);
    expect(
      await (
        await syncRequest(runtime, "GET", `${path}?documentVersion=${call.documentVersion}`)
      ).text(),
    ).toBe(input.document);
    const changed = { ...input, document: JSON.stringify(next) };
    expect(await (await syncRequest(runtime, "PUT", path, changed)).json()).toMatchObject({
      error: { code: "sync_operation_conflict" },
    });
    expect(
      await (
        await syncRequest(
          runtime,
          "PUT",
          path,
          replicaCommand(
            { ...next, documentVersion: next.documentVersion + 1 },
            call.documentVersion,
          ),
        )
      ).json(),
    ).toMatchObject({ error: { code: "sync_conflict" } });
  });

  it("recovers an acknowledged-lost R2 object before publishing without reissuing its PUT", async () => {
    const runtime = fixtureRuntime();
    const { call } = await finalizedSyncCall(runtime);
    const input = replicaCommand(call, null);
    const actualPut = runtime.ARCHIVE.put.bind(runtime.ARCHIVE);
    let lost = false;
    const put = vi.spyOn(runtime.ARCHIVE, "put").mockImplementation(async (key, value, options) => {
      const result = await actualPut(key, value, options);
      if (key.includes("/replicas/") && !lost) {
        lost = true;
        throw new Error("lost R2 acknowledgement");
      }
      return result;
    });
    const path = `/v1/calls/${call.callId}/document`;
    expect((await syncRequest(runtime, "PUT", path, input)).status).toBe(200);
    expect((await syncRequest(runtime, "PUT", path, input)).status).toBe(200);
    expect(put.mock.calls.filter(([key]) => key.includes("/replicas/"))).toHaveLength(1);
    expect(
      (await Effect.runPromise(inspectReplicaWriters(runtime, input.operationId))).every(
        (writer) => writer.state === "stored",
      ),
    ).toBe(true);
  });

  it("retains immutable transcript evidence, validates annotation scope and rejects a legacy downgrade", async () => {
    const provider = speechRunner();
    const runtime = fixtureRuntime(provider);
    const { call } = await finalizedSyncCall(runtime);
    const path = `/v1/calls/${call.callId}/document`;
    expect((await syncRequest(runtime, "PUT", path, replicaCommand(call, null))).status).toBe(200);
    const { result, revision } = await availableSyncRevision(runtime, call.callId);
    const grouped: CallDocument = Struct.assign(call, {
      documentVersion: 3,
      revisions: [
        { revisionId: result.revisionId, createdAt: result.createdAt, sha256: result.sha256 },
      ],
      activeRevisionId: result.revisionId,
      speakerNames: { [result.revisionId]: { [revision.speakers[0]!.speakerId]: "Александр 👋" } },
      speakerGroups: {
        [result.revisionId]: [
          {
            groupId: crypto.randomUUID(),
            displayName: "One named voice",
            speakerIds: revision.speakers.map((speaker) => speaker.speakerId),
          },
        ],
      },
    });
    const published = await syncRequest(
      runtime,
      "PUT",
      path,
      replicaCommand(grouped, 2, [result.revisionId]),
    );
    expect(published.status, await published.clone().text()).toBe(200);
    const retained = parseCallDocument(
      new Uint8Array(await (await syncRequest(runtime, "GET", path)).arrayBuffer()),
    );
    expect(retained).toEqual(grouped);
    const renamed = Struct.assign(grouped, {
      documentVersion: 4,
      speakerNames: {
        [result.revisionId]: { [revision.speakers[0]!.speakerId]: "New local name" },
      },
    });
    expect(
      await (await syncRequest(runtime, "PUT", path, replicaCommand(renamed, 3))).json(),
    ).toMatchObject({ error: { code: "sync_incompatible_document" } });
    const legacy: Record<string, unknown> = Struct.assign(grouped, {
      schemaVersion: 1,
      documentVersion: 4,
    });
    delete legacy.speakerGroups;
    expect(
      await (
        await syncRequest(runtime, "PUT", path, {
          ...replicaCommand(grouped, 3, [result.revisionId]),
          document: JSON.stringify(legacy),
        })
      ).json(),
    ).toMatchObject({ error: { code: "sync_incompatible_document" } });
    const bad = { ...renamed, revisions: [{ ...grouped.revisions[0]!, sha256: "0".repeat(64) }] };
    expect(
      (await syncRequest(runtime, "PUT", path, replicaCommand(bad, 3, [result.revisionId]))).status,
    ).toBe(422);
    expect(provider.run).toHaveBeenCalledTimes(1);
    expect(
      (await env.CATALOG.prepare("SELECT * FROM trigo_replica_operations").all()).results.every(
        (row) => !JSON.stringify(row).includes("Александр"),
      ),
    ).toBe(true);
  });

  it("surfaces results completed without a Mac separately from confirmed canonical replicas", async () => {
    const runtime = fixtureRuntime(speechRunner());
    const { call } = await finalizedSyncCall(runtime);
    const first = validateDocument(
      "CallCatalogPage",
      await (await syncRequest(runtime, "GET", "/v1/calls")).json(),
    );
    expect(first.calls).toHaveLength(1);
    expect(first.calls[0]).toMatchObject({
      callId: call.callId,
      replica: null,
      resultCount: 0,
      audio: { verification: "complete-master-sha256-v1" },
    });
    const { result } = await availableSyncRevision(runtime, call.callId);
    const changes = validateDocument(
      "CallChangesPage",
      await (await syncRequest(runtime, "GET", `/v1/changes?cursor=${first.changesCursor}`)).json(),
    );
    expect(changes.changes.length).toBeGreaterThan(0);
    expect(
      changes.changes.every(
        (entry, index, all) => index === 0 || entry.sequence > all[index - 1]!.sequence,
      ),
    ).toBe(true);
    expect(changes.changes.at(-1)?.call).toMatchObject({
      callId: call.callId,
      replica: null,
      resultCount: 1,
    });
    const results = validateDocument(
      "TranscriptResultsPage",
      await (await syncRequest(runtime, "GET", `/v1/calls/${call.callId}/results`)).json(),
    );
    expect(results.results.map((entry) => entry.result)).toEqual([result]);
    await env.CATALOG.prepare("UPDATE trigo_sync_epoch SET epoch=?").bind("f".repeat(32)).run();
    expect(
      await (await syncRequest(runtime, "GET", `/v1/changes?cursor=${changes.nextCursor}`)).json(),
    ).toMatchObject({ error: { code: "sync_cursor_reset" } });
    expect((await syncRequest(runtime, "GET", "/v1/calls")).status).toBe(200);
  });

  it("fences an in-flight replica PUT on deletion and exposes a durable opaque marker", async () => {
    const runtime = fixtureRuntime();
    const { call } = await finalizedSyncCall(runtime);
    const input = replicaCommand(call, null);
    const actualPut = runtime.ARCHIVE.put.bind(runtime.ARCHIVE);
    vi.spyOn(runtime.ARCHIVE, "put").mockImplementation(async (key, bytes, options) => {
      if (key.includes("/replicas/")) {
        await Effect.runPromise(fenceMasterUploads(runtime.CATALOG, owner.archiveId, call.callId));
      }
      return actualPut(key, bytes, options);
    });
    const response = await syncRequest(runtime, "PUT", `/v1/calls/${call.callId}/document`, input);
    expect(response.status).toBe(410);
    expect(
      (
        await env.CATALOG.prepare(
          "SELECT * FROM trigo_replica_operations WHERE state='published'",
        ).all()
      ).results,
    ).toEqual([]);
    expect(await Effect.runPromise(inspectReplicaWriters(runtime, input.operationId))).toHaveLength(
      1,
    );
    const page = validateDocument(
      "CallCatalogPage",
      await (await syncRequest(runtime, "GET", "/v1/calls")).json(),
    );
    expect(page.calls[0]).toMatchObject({
      callId: call.callId,
      deletion: { phase: "draining" },
      replica: null,
      audio: null,
      resultCount: 0,
    });
    expect(
      (await syncRequest(runtime, "PUT", `/v1/calls/${call.callId}/document`, input)).status,
    ).toBe(410);
  });
});
