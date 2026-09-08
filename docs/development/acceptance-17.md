# Resumable master upload acceptance

This candidate implements [#17](https://github.com/apshenichniy/trigo/issues/17)
against the independent upload lane in
[#70's accepted handoff](https://github.com/apshenichniy/trigo/issues/70#issuecomment-5583897958).
The originating base is `8e65ee1b6f11421d3102b6ec75911720d5b8bf96`.
The shared request/receipt contract began in `203cee945`.

## Storage and ownership

The native coordinator uploads complete 8-MiB ranges from the repository's
confirmed media cursor while capture continues. It reads the final short range
only after capture finalization. The CAF header is immutable: 68 bytes, with
indefinite data length, followed by 16-kHz signed 16-bit little-endian interleaved
microphone/application channels. The supported master is at most 691,200,068
bytes, representing three hours. No transport-part files are created locally.

The server pre-registers each external write in D1 and gives that invocation a
fresh immutable R2 key. Staged ranges are individual R2 objects; finalization
streams their ordered concatenation into one final object. This is a single
R2 PUT, within the documented 5-GiB single-upload limit, so R2 multipart minimum
part sizes do not apply to the staged-object strategy. The implementation uses
R2's SHA-256 option and returned checksum as well as incremental part/master
hashing and a checked CAF header. An ETag is never the master checksum.
See the [R2 upload limits](https://developers.cloudflare.com/r2/objects/upload-objects/)
and [Workers R2 API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/).

Finalization binds the original call, source, two track identities, exact closed
recording metadata, audio-manifest hash, final duration, complete byte length,
ordered parts and whole-master SHA-256. The complete verified receipt, upload
`stored` state and both operation acknowledgements commit in one local SQLite
transaction. Only that validated durable receipt authorizes deletion of
`master.caf` and `master.index`; cleanup is idempotent after process exit and
preserves other files. Capture, transcription, import and replica state remain
independent.

The local repository adds two upload tables through an atomic migration from
the exact prior version-2 schema. Identity/integrity/schema checks precede
migration; unsupported, foreign and corrupt stores remain rejected.

## Evidence and executable checks

The focused server suite contains 15 upload cases. The native upload and
authority selection contains 10 tests, including parameterized failure cases.
Their focused runs passed before full acceptance; final source identity, full
gate results, timings and CI URLs belong in the PR and CI artifacts.

| Requirement                                                                    | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Upload before capture ends; preserve the common timeline and source identities | `upload.worker.test.ts` uploads a 135-second synthetic stereo master before final metadata, checks the complete stored SHA and decoded channel samples, and exercises out-of-order delivery. `MasterUploadTests` uploads a full part at 132 seconds, continues capture, finalizes at 133 seconds, and verifies both track intervals and exact retained snapshot after cleanup.                                                                                                                                                  |
| Retry original identities after restart/outage                                 | Registration, part and final lost-acknowledgement tests retain durable client identities and server receipts. Native receipt tests close every client/writer and assert the prior SQLite connection is released before reopening and replay.                                                                                                                                                                                                                                                                                    |
| No premature local removal                                                     | Five injected boundaries cover before/after receipt commit and before/during/after media cleanup. Forged receipts, lifecycle state alone, part receipts, cancellation and local deletion fencing cannot authorize cleanup. A post-commit cleanup fault cannot downgrade stored audio.                                                                                                                                                                                                                                           |
| Bounded streaming                                                              | `upload-streaming.worker.test.ts` sends all 691,200,068 bytes through production assembly, validation and fixed-length write stages. Its controlled storage sink forbids whole-object materialization, yields to exercise backpressure, and asserts 83 ranges, one open source, chunks at most 65,536 bytes and less than 1 MiB queued. Real local R2 tests separately verify the storage/checksum API on actual uploaded parts and complete masters. This is a stream-allocation bound, not a claim about hosted-provider RSS. |
| Missing/conflicting/oversized media                                            | Server tests reject oversized admissions, truncated bodies, conflicting identity content, bad headers, whole-master mismatches, missing stored ranges, altered sources, duration and channel mapping. Incomplete audio cannot be returned by `storedMaster`.                                                                                                                                                                                                                                                                    |
| Deletion can account for late writers                                          | Part and final writer tests fence the call while R2 PUT is in flight, lose its acknowledgement, inspect the retained uncertain row, recover the checksum-matching completed object, and still reject final publication. Missing HEAD results do not prove a writer stopped.                                                                                                                                                                                                                                                     |
| Same archive after credential repair                                           | `masterUploadAuthorityStaysBoundAndUsesRepairedCredentials` covers wrong-archive rejection, blocked work with retained recording eligibility, repaired endpoint/token, stale failure reports and credential-access errors.                                                                                                                                                                                                                                                                                                      |
| Actual native/server boundary                                                  | `LocalDevelopmentTests` uses real URLSession against the selected local Worker, uploads/finalizes synthetic media, interrupts the local receipt commit, restores the connection, replays finalization, and verifies cleanup. This belongs to the mandatory native/local Worker smoke.                                                                                                                                                                                                                                           |

Required full commands for the completed candidate are `bun run check:server`
and `bun run check:macos`. The latter includes both Debug app builds, every
native fast/contention/resource suite, Swift contracts and local Worker smoke.
All fixtures are synthetic, local and isolated to this checkout. No hosted
deployment, ASR invocation, personal archive or private audio is part of this
evidence.

The initial server registration reproducer returned 501 on the originating
base before implementation. An early expanded Worker test exhausted the test
process while recursively comparing two multi-megabyte typed arrays; the
assertion was replaced with full SHA-256, byte count and decoded sample checks,
without raising a memory limit. Deliberately truncated/wrong-hash stream tests
can emit workerd connection-lost diagnostics; their assertions and the test
runner's unhandled-error gate remain enabled.

## Integration handoff

- **#71:** Production lifetime is the retained `MasterUploadApplicationOwner`,
  constructed only by the live `RecordingCoordinator` initializer. Start is
  idempotent after restored binding/local recovery; repair and capture stop wake
  the service. Tests may inject an owner explicitly. Idle process exit remains
  safe through the durable journal; Quit does not wait for remote completion.
  Combining the two lanes requires preserving #71's throwing fixture/bundle
  guards and the small connection/termination additions in this candidate.
- **#18 / #73:** `storedMaster(db, archiveId, callId)` returns the verified
  receipt, server-resolved private object key and exact audio-manifest bytes.
  It refuses incomplete or deletion-fenced calls. Consumers may pin the
  observed R2 ETag for later range reads; that does not replace receipt SHA-256.
  Call operations become ready; ASR readiness remains `not_verified` in this lane.
- **#22:** `fenceMasterUploads`, `inspectUploadWriters` and `reconcileWriter`
  expose admission, uncertain completion and stored-object evidence. Fencing
  prevents new writers and receipt publication; previously admitted writers
  remain visible. Absence, request expiry and local cancellation are not terminal
  evidence. Deletion orchestration/cleanup and opaque tombstones belong to #22.
- **#19:** This upload receipt does not publish a canonical replica, import a
  transcript or claim synchronization completion. Exact finalized capture
  metadata is an immutable upload input; later annotations do not rewrite it.

The PR remains scoped to #17, and the issue remains open until its normal merge
lifecycle. Merge and deployment require the owner's instruction.
