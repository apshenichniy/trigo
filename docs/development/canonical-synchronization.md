# Canonical synchronization and restoration

Issue [#19](https://github.com/apshenichniy/trigo/issues/19) owns call-document v2,
the annotation operations from [#46](https://github.com/apshenichniy/trigo/issues/46#issuecomment-5580368018),
canonical replicas, result import and restoration. Reader presentation remains
with #20; playback is #73, explicit replacement/export is #21 and managed deletion
is #22.

## Completion boundary

The application-owned coordinator runs after local capture recovery. It keeps
working when the library or recording panel closes. Its sequence is:

1. Retain catalog/change descriptions and deletion markers before advancing a cursor.
2. Restore exact confirmed canonical metadata and referenced evidence where needed.
3. Publish the finalized base after a verified master-storage receipt.
4. Persist one initial ASR command, then submit that same identity on transport retry.
5. Download and verify both transcript and provenance hashes and lengths.
6. Commit the revision, current canonical pointer, retained provenance and replica
   work in one SQLite transaction, then publish the exact snapshot.

Publishing the base before automatic ASR makes a result completed while the old
Mac is unavailable restorable. A server call with audio/results but no canonical
document remains an explicit metadata-unavailable entry; the client does not
invent the missing capture metadata. Catalog failures and pending restoration
counts remain available through `synchronizationStatus()`.

`isCallSavedOnMacAndServer` requires an active call, verified audio receipt, a
locally imported active revision and a confirmed replica of the exact current
snapshot hash. Server result availability, an old acknowledgement or a UI state
alone cannot establish this condition. A failed later operation preserves earlier
revisions and their annotations.

Result association retains the server's generation in the same local transaction.
Only a proven newer generation changes the active transcript. Restoration imports
that ordering metadata with its referenced evidence, so an older unreferenced result
can be retained afterward without demoting the active revision. Associating an
already-retained result preserves the exact confirmed snapshot and creates no
publication. Each new replica command has its own durable identity; a fresh Mac
cannot reuse another installation's command for a different local snapshot.

The initial language is persisted in each operation. The application reads the
namespace's `initialTranscriptionLanguage` preference (`ru` by default; `en` is
also supported). Changing it affects future commands. No automatic language
detection or unsupported provider language is assumed. Workflow interruption can
reserve one automatic recovery of the same initial operation; an explicit retry
after correction can resume that operation again. Lost recovery responses replay
the same identity. The server's original-plus-one-replacement attempt cap remains
authoritative. Exhaustion never creates another automatic logical command.

## Documents and storage

Call-document v2 requires `speakerGroups` and retains `speakerNames`. Legacy v1
snapshots have an explicit read/import path, including exact old bytes and hashes.
An upgrade authors a new version; immutable transcript evidence is never rewritten.
SQLite schema 4 is an additive migration from the exact supported v2/v3 layouts.
The scoped speaker-detail projection is rebuilt from retained evidence when an
older archive first reads it. No archive reset or silent annotation stripping is
part of migration or restoration.

Rename, group, remove-members and ungroup are semantic operations with stable
command IDs and expected local document versions. They commit the snapshot,
pending state and durable publication intent atomically. A committed replay wins
before stale-version checks. Groups retain dormant individual names, use explicit
membership and cannot recycle an identity for a new local group. Stable neutral
labels derive from immutable speaker order within a revision. Inspection exposes
the original source, provider label, diarization scope and an unmodified passage.

Replica requests bind their expected server version once before the first send.
The immutable body and command identity survive restarts and unknown responses.
An exact confirmed old publication can recover its lost acknowledgement without
confirming or replacing a newer local edit. Conflicts retain both annotation
alternatives. An explicit choice changes only the selected revision's names/groups
against the latest local metadata and remains subject to the next server version
check. Imports retain other revisions and their annotations.

A conflict between finalized bases with no transcript revisions has no annotations
to compare. After checking that all immutable capture metadata matches, the client
adopts a newer current-format base or authors a new version above both sides and
retries publication. Conflicts involving transcript revisions retain the explicit
annotation-resolution path.

Server migration `0005_canonical_sync.sql` retains admitted publication operations,
all object writers, ordered changes and permanent deletion markers. R2 bytes and
their hashes exist before a single fenced D1 update exposes a replica and its
replay receipt. Every writer is admitted before PUT; an uncertain PUT is recovered
by inspecting that key or using a fresh admitted key, never by reissuing the same
uncertain write. Publication checks current owner generation, call deletion,
expected version, immutable metadata, retained references and annotation scope.

Catalog, change and result pages contain at most 32 entries. Catalog pagination
carries a fixed change watermark, so later inserts behind its call cursor are
recovered through changes. Invalid/pruned change cursors cause full reconciliation
into the existing archive. Failed downloads retry from retained catalog work even
without another server change. Audio stays remote on a restored Mac. Deletion
markers survive missing catalog rows and fence imports, edits and publications;
their presence does not claim that #22 cleanup has completed.

## HTTP surface

| Method and path                         | Contract                                                 |
| --------------------------------------- | -------------------------------------------------------- |
| `GET /v1/calls`                         | `CallCatalogPage`                                        |
| `GET /v1/changes?cursor=…`              | `CallChangesPage`                                        |
| `GET /v1/calls/{callId}/document`       | Exact retained call snapshot; optional `documentVersion` |
| `PUT /v1/calls/{callId}/document`       | `PublishCallReplica` → `ReplicaReceipt`                  |
| `GET /v1/calls/{callId}/audio-manifest` | Exact retained `AudioManifest`                           |
| `GET /v1/calls/{callId}/results`        | `TranscriptResultsPage`                                  |

The shared local/cloud API composes these with #18 operation/revision/provenance
routes. Native requests construct same-origin paths from validated IDs, reject
redirects and bound response bodies. Canonical and revision documents are bounded
at 16,000,000 bytes; provenance at 65,536 bytes. Unsupported complete snapshots
remain local with a compatibility failure. No document or text is truncated.

## Verification

The structural corpus covers both call versions and every synchronization type
through Effect, JSON Schema and generated Swift round trips. Focused native suites
exercise migration, exact evidence retention, atomic annotations, crash/replay,
concurrent import, explicit conflict choices, old acknowledgements, offline edits,
result corruption, fresh restoration and deletion fences. Actual URLSession tests
cover response bounds, redirects, wrong bindings and revoked credentials.

Worker tests use real D1/R2 to exercise publication, duplicate requests, stale CAS,
retained evidence, incompatible legacy writes, interrupted storage, owner rotation,
uncertain writers, pagination and permanent deletion markers. Ordinary local
acceptance uses the actual native HTTP transport and shared Worker composition
with fake ASR, from capture/master cleanup through canonical import, confirmation
and restoration. It makes no hosted-provider call.

Review of candidate `58ecd22ad` identified late-generation pointer regression and
an unresolvable base-only conflict. The actual local HTTP acceptance additionally
found a reused publication identity during fresh restoration. Three focused
repository tests reproduced these boundaries before the fixes (eight failed
expectations). The regression suite also covers restored generation metadata,
independent installation commands and older/equal base-version recovery.

Run `bun run check:server`, `bun run check:quick --scope native` and
`bun run check:macos:smoke` for component integration. The final candidate's CI
runs the complete native/resource/app acceptance gate. Run URLs and timings are
recorded in the PR after the tracked candidate is committed. Hosted deployment,
paid calls and the final runnable Dev handoff remain explicit #24 acceptance.

## Playback and current-main integration

The updated #19 candidate includes current main `9a3a4716b` and reviewed playback
candidate `bb3d4e380`. Shared API and generated-contract conflicts use the exact
combined source already present in integrated candidate `5083efa7b`; their bytes
are unchanged in the subsequently verified library candidate `410f7c694`. The
actual local HTTP smoke is retained from that pre-reader integration, so it
requires no #20 presentation classes.

Canonical HTTP requests use the shared `ServerOperationAuthorization` and report
authorization failures through the same connection owner as playback/upload.
This is the already integrated bridge correction, preserving the transport's
request/response bounds and existing generation checks. The native playback
guard for pausing before the first render is also included through its owning
#73 branch.

The PR records the new exact source and its full required CI. Older successful
#19 checks alone do not establish acceptance of this merged candidate.
