/* oxlint-disable effecttsgo/async-function, effecttsgo/crypto-random-uuid -- The Worker SDK test boundary exercises durable interruption and owner rotation without external traffic. */
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { beforeEach, expect, it, vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import {
  applyOwnerOperation,
  hashOwnerToken,
  OwnerOperationId,
  OwnerToken,
} from "../src/owner-state.ts";
import { inspectReplicaWriters } from "../src/replica-writers.ts";
import { fenceMasterUploads } from "../src/upload-catalog.ts";
import {
  finalizedSyncCall,
  replicaCommand,
  resetSyncFixture,
  syncRequest,
} from "./sync-fixture.ts";
import { fixtureRuntime, owner } from "./transcription-fixture.ts";

beforeEach(resetSyncFixture);

it("recovers an interruption between durable R2 storage and the atomic catalog pointer", async () => {
  const runtime = fixtureRuntime();
  const { call } = await finalizedSyncCall(runtime);
  const command = replicaCommand(call, null);
  const path = `/v1/calls/${call.callId}/document`;
  const prepare = runtime.CATALOG.prepare.bind(runtime.CATALOG);
  let crash = true;
  vi.spyOn(runtime.CATALOG, "prepare").mockImplementation((sql) => {
    if (crash && sql.includes("SET state='published'")) {
      crash = false;
      throw new Error("crash before canonical pointer publication");
    }
    return prepare(sql);
  });
  expect((await syncRequest(runtime, "PUT", path, command)).status).toBe(503);
  expect((await syncRequest(runtime, "GET", path)).status).toBe(404);
  const writers = await Effect.runPromise(inspectReplicaWriters(runtime, command.operationId));
  expect(writers).toHaveLength(1);
  expect(writers[0]?.state).toBe("stored");
  const response = await syncRequest(runtime, "PUT", path, command);
  expect(response.status, await response.clone().text()).toBe(200);
  expect(await Effect.runPromise(inspectReplicaWriters(runtime, command.operationId))).toEqual(
    writers,
  );
  expect(await (await syncRequest(runtime, "GET", path)).text()).toBe(command.document);
});

it("keeps an uncertain writer enumerable while a fresh key completes the same operation", async () => {
  const runtime = fixtureRuntime();
  const { call } = await finalizedSyncCall(runtime);
  const command = replicaCommand(call, null);
  const path = `/v1/calls/${call.callId}/document`;
  const put = runtime.ARCHIVE.put.bind(runtime.ARCHIVE);
  let lost = true;
  vi.spyOn(runtime.ARCHIVE, "put").mockImplementation(async (key, body, options) => {
    if (key.includes("/replicas/") && lost) {
      lost = false;
      throw new Error("process lost before PUT acknowledgement");
    }
    return put(key, body, options);
  });
  expect((await syncRequest(runtime, "PUT", path, command)).status).toBe(503);
  const [uncertain] = await Effect.runPromise(inspectReplicaWriters(runtime, command.operationId));
  expect(uncertain?.state).toBe("uncertain");
  expect((await syncRequest(runtime, "PUT", path, command)).status).toBe(200);
  const writers = await Effect.runPromise(inspectReplicaWriters(runtime, command.operationId));
  expect(writers).toHaveLength(2);
  expect(writers.find((writer) => writer.writer_id === uncertain?.writer_id)?.state).toBe(
    "uncertain",
  );
  expect(new Set(writers.map((writer) => writer.object_key)).size).toBe(2);
});

it("rejects a rotated owner after its admitted write and lets the current owner recover it", async () => {
  const runtime = fixtureRuntime();
  const { call } = await finalizedSyncCall(runtime);
  const command = replicaCommand(call, null);
  const path = `/v1/calls/${call.callId}/document`;
  const nextToken = OwnerToken.make(`trigo_v1_${"8".repeat(64)}`);
  const nextVerifier = await Effect.runPromise(hashOwnerToken(nextToken));
  const put = runtime.ARCHIVE.put.bind(runtime.ARCHIVE);
  let rotate = true;
  const spy = vi.spyOn(runtime.ARCHIVE, "put").mockImplementation(async (key, bytes, options) => {
    if (key.includes("/replicas/") && rotate) {
      rotate = false;
      await Effect.runPromise(
        applyOwnerOperation(env.CATALOG, {
          kind: "rotate",
          operationId: OwnerOperationId.make(crypto.randomUUID()),
          expectedGeneration: 1,
          verifierSha256: nextVerifier,
          now: "2026-09-08T15:00:00Z",
        }),
      );
    }
    return put(key, bytes, options);
  });
  expect((await syncRequest(runtime, "PUT", path, command)).status).toBe(401);
  expect((await syncRequest(runtime, "GET", path)).status).toBe(401);
  expect((await syncRequest(runtime, "PUT", path, command, nextToken)).status).toBe(200);
  expect(spy.mock.calls.filter(([key]) => key.includes("/replicas/"))).toHaveLength(1);
  expect(
    (
      await env.CATALOG.prepare(
        "SELECT owner_generation FROM trigo_replica_operations WHERE state='published'",
      ).first<{ owner_generation: number }>()
    )?.owner_generation,
  ).toBe(2);
});

it("covers inserts behind a catalog page, ordered change pages and a deleted catalog row", async () => {
  const runtime = fixtureRuntime();
  const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  async function register(n: number) {
    await env.CATALOG.prepare(
      "INSERT INTO trigo_master_uploads VALUES (?,?,?,?,?,?,?,?,?,'active')",
    )
      .bind(
        id(n),
        owner.archiveId,
        id(n + 1000),
        id(n + 2000),
        "0".repeat(64),
        id(n + 3000),
        id(n + 4000),
        "2026-09-08T00:00:00Z",
        "1".repeat(64),
      )
      .run();
  }
  for (let n = 100; n < 133; n++) {
    await register(n);
  }
  const firstResponse = await syncRequest(runtime, "GET", "/v1/calls");
  expect(firstResponse.status, await firstResponse.clone().text()).toBe(200);
  const first = validateDocument("CallCatalogPage", await firstResponse.json());
  expect(first.calls).toHaveLength(32);
  expect(first.nextCursor).not.toBeNull();
  await register(50);
  const second = validateDocument(
    "CallCatalogPage",
    await (await syncRequest(runtime, "GET", `/v1/calls?cursor=${first.nextCursor}`)).json(),
  );
  expect(second.calls.map((call) => call.callId)).toEqual([id(132)]);
  expect(second.changesCursor).toBe(first.changesCursor);
  for (let n = 100; n < 133; n++) {
    await Effect.runPromise(fenceMasterUploads(env.CATALOG, owner.archiveId, id(n)));
  }
  const changes = validateDocument(
    "CallChangesPage",
    await (await syncRequest(runtime, "GET", `/v1/changes?cursor=${first.changesCursor}`)).json(),
  );
  expect(changes.changes[0]?.call.callId).toBe(id(50));
  expect(changes.hasMore).toBe(true);
  const remaining = validateDocument(
    "CallChangesPage",
    await (await syncRequest(runtime, "GET", `/v1/changes?cursor=${changes.nextCursor}`)).json(),
  );
  expect(remaining.hasMore).toBe(false);
  expect(
    [...changes.changes, ...remaining.changes].filter((change) => change.call.deletion !== null),
  ).toHaveLength(33);
  await env.CATALOG.prepare("DELETE FROM trigo_master_uploads WHERE call_id=?").bind(id(132)).run();
  const final = validateDocument(
    "CallCatalogPage",
    await (await syncRequest(runtime, "GET", `/v1/calls?cursor=${first.nextCursor}`)).json(),
  );
  expect(final.calls[0]).toMatchObject({
    callId: id(132),
    deletion: { phase: "draining" },
    replica: null,
  });
  await expect(register(132)).rejects.toThrow("call_deleted");
});
