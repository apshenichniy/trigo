# Acceptance evidence: durable production call master (#53)

Implemented from the accepted #52 integration base
`5c7789f419d69eae015ff6ba38795c8c98fada51` on
`codex/epic-48-issue-53`. This is local synthetic evidence on macOS 26.6.2
(25G83), Xcode 26.6 (17F113), Apple M1 Pro, 16 GiB RAM. Long-call measurements
use Release builds and advance the complete simulated duration.

## Delivered boundary

Production ScreenCaptureKit callbacks now enter a bounded ingress, the existing
source-routing/decoder/common-timeline boundary, `CaptureMediaWriter`, the selected
CAF master, and the SQLite progress owner. Each call has one stable master ID and
only `media/master.caf` plus `media/master.index`. The minute PCM/WAVE rollover,
whole-checkpoint JSON rewrite, accumulated timeline interval arrays,
`CaptureMediaFile`, `CapturePCMFormat` and `legacy_capture_seals` are removed.

The authored Effect `CaptureMasterProfile`, checked profile JSON, emitted JSON
Schema and generated Swift values agree on permanent master, integrity-commit,
transport-range and extraction contracts. The three-hour master may be
691,200,068 bytes; the independent request cap remains 8,388,608 bytes. Shared
Swift/TypeScript structural and semantic fixtures admit the complete CAF master
and reject using the range cap as its complete object length. The existing WAVE
provider-probe profile is retained independently.

`CaptureArchiveSession.complete` and production recovery return a compact
`CaptureCompletion`. Merged intervals stream from bounded repository cursors into
exact exchange bytes and 256 KiB SQLite chunks. Final publication atomically
commits the call/audio reference, final witness, lifecycle and associated work.
Generated scalar encoding agrees byte-for-byte with `Contract.encode`, including
required nulls, nested fields, Unicode and escaping; the resulting capture fixture
also passes public archive/reference validation. Explicit aggregate APIs remain
available when callers choose to materialize the complete document.

The session schema declares SQLite version 2. The prior schema is rejected
without mutation, consistent with the approved explicit clean namespace cutover.
No migration, private-store reset, deployment or installed acceptance was performed.
The [concrete downstream interface](capture-master-interface.md) describes admission,
stable range reads, finalization intent, extraction provenance and retention.

## Full duration and bounded resources

`ProductionMasterProofTests` uses the frequent-state fixture from #51 through the
actual production timeline, writer and SQLite repository. Both sources change
state every 10 ms, including leading unavailable audio and effective microphone
mute. Every frame is independently decoded and compared; additional seeks cross
commit boundaries. An early 8 MiB range remains byte-identical after all later
appends/finalization. Oversized range reads fail. Reopen, whole-master hashing,
chunked exact snapshot hashing, replay and full-call extraction all preserve
identity and bytes. Media/index files remain retained after extraction.

| Measurement                                           |     One hour |  Three hours |
| ----------------------------------------------------- | -----------: | -----------: |
| Independent decoded frames                            |   57,600,000 |  172,800,000 |
| Permanent master bytes                                |  230,400,068 |  691,200,068 |
| Final merged source intervals                         |      450,890 |    1,352,690 |
| Exact retained snapshot bytes                         |   32,994,119 |   99,738,722 |
| Append, media/index sync and SQL progress             |     16.476 s |     48.496 s |
| Streaming final publication, snapshot hash and replay |     18.078 s |     50.895 s |
| Complete test elapsed                                 |     35.830 s |    103.320 s |
| Proof helper peak RSS through full extraction         | 56,295,424 B | 56,393,728 B |

These final isolated measurements are in `53-production-one-hour-complete.log` and
`53-production-three-hour-complete.log`. They reuse the exact Release test binary
from the passing full native gate. Full native gates also execute these
complete fixtures concurrently with the rest of the suite; their shared-process
RSS is not an isolated per-capture memory measurement.

The production one-hour 44.1 kHz microphone / 48 kHz application common-clock
fixture independently decodes simultaneous timing markers and measures **0.0 ms**
worst source-relative drift, within the unchanged 200 ms requirement. The
constant-state production writer also persists/finalizes the full three hours
and rejects a subsequent append beyond the explicit limit.

The initial one-hour Release final projection used full public JSON validation
and aggregate materialization: 320.853 s final projection and 611,581,952 B helper
peak RSS. Sampling identified full schema validation/materialization as the
hotspot. The bounded serializer/projection and compact production completion
remove that growth; the one-hour snapshot still has the same 32,994,119 bytes
and complete interval count. `53-production-one-hour-initial.log` retains that
failed resource diagnostic. An intermediate Debug long run was intentionally
stopped after sampling unoptimized timeline scans; it is not acceptance evidence
(`53-production-one-hour-streaming.log`, `53-streaming-live-sample.txt`).

## Queue, common timeline and completed background work

Ingress retains at most one second per source and 256 buffers including in-flight
work. It schedules one drain at a time and consumes at most eight buffers per
drain before yielding to controls. A replenishing producer test admits 1,000
callbacks while proving a queued control runs after the first bounded batch.
Actual sink tests reject foreign, stale and replaced streams before capacity
accounting; obsolete pending microphone data is pruned when selection changes.
Overload fails explicitly instead of accumulating callbacks or tasks.

Stop freezes ingress and drains its bounded remainder before finalizing. A sink
fixture queues 100 buffers spanning one second before stop and verifies complete
recorded source coverage across multiple drain batches. A separate deterministic
fixture holds the engine queue for 300 ms, admits the same one second of audio,
then runs the actual timer method while 92 buffers remain pending. Its pending
audio guard prevents the timer from inventing unavailable intervals; all input
survives finalization. No timing assertion was relaxed or test suite serialized.

`53-production-contention.log` contains the completed background load proof. Both
the original 2,000-interval-per-commit master proof and the actual production sink
share the unchanged three-phase workload: 12,000 imported turns / 11,111,043 bytes,
24 typed reads of a 2,880,000-byte turn, call pagination, operation running/failure/
retry/acknowledgement and retained revision/lifecycle checks. Capture advances
through every background phase; every import/read phase completes.

| Focused production sink measurement                               |       Result |
| ----------------------------------------------------------------- | -----------: |
| Completed capture commits                                         |        2,985 |
| Maximum admitted buffers                                          |          100 |
| Maximum pending duration per source                               |      1.000 s |
| Maximum ingress service time                                      |     4.658 ms |
| Maximum input + enqueue/drain + media/index sync + SQL progress   | 1,088.957 ms |
| p95 enqueue/drain + media/index sync + SQL progress               |     6.403 ms |
| Blocked-queue fixture input + queue + final media/progress commit | 1,412.903 ms |

The original delay diagnostic measured until its result was rescheduled on
MainActor and included fixture buffer construction. Under full-suite load it
reported 2,866.938 ms. The corrected probe prepares synthetic buffers before
admission, releases its hold independently of MainActor and timestamps completion
on the engine queue immediately after durability. It separately reports caller
delivery after that commit. In the final complete native gate, actual input + queue +
commit was 1,351.547 ms; caller delivery added 381.473 ms after durability. The
same full-suite production contention workload completed 3,866 commits with a maximum
1,175.765 ms input + enqueue/drain + media/index sync + SQL progress, still below
two seconds (`53-check-macos-complete.log`).

## Crash, corruption, privacy and replay

- The retained 25-run production writer SIGKILL fixture kills after the third
  one-second media sync. SQL witnesses 32,000 frames, the file contains 192,068
  bytes, and recovery publishes two seconds: one second of uncommitted tail is
  lost, within the unchanged two-second target.
- Four new real production engine SIGKILL cases stop before/after final-index
  synchronization for clean stop and `system_sleep`. Three seconds of actual
  source input, stable master identity/hash and caller work prepared before the
  external final boundary survive. That work becomes runnable only with final
  publication. Repeated recovery is equal and never opens a stream.
- Streaming publication faults after staging and before/after the joint SQL
  commit retain exact historical bytes, all-or-nothing final call/lifecycle/work,
  stable final witness and idempotent matching replay. Conflicting work is rejected.
- Public exchange-byte finalization and compact publication share retained work,
  durable stop cause and exact source-state evidence. Raw snapshots preserve
  valid split intervals and whitespace. Replay rejects changed bytes, source
  metadata and unpublished versions; exact historical replay after a later
  manifest version preserves history and returns the current projection.
- Production recovery rejects corruption of confirmed PCM, an index record
  at/below the SQL witness and loss of the witness, without truncating retained
  evidence. A terminal complete-sized torn record above an independently matched
  witness is discarded only within one append of unindexed PCM. A nonterminal
  damaged record rejects recovery. The selected #51 fault matrix remains intact.
- Unopened admission has no fabricated witness. An opened zero-frame master must
  match the actual immutable 68-byte header hash and has no audio object. Trusted
  streaming and public exchange-byte finalization share the same witness checks.
- Recovery closes append admission. Both already-failed and recovered writers
  reject new recording input; external-only synchronized progress is reconciled
  before finalization instead of appending duplicate samples.
- Existing mute, source-loss, sleep, decoder epoch, first-delivery, late/stale
  callback, pending-start retirement and application-instance ownership fixtures
  remain active. The partial-millisecond case explicitly confirms that missing
  one source sample makes the whole source millisecond unavailable/zero in the
  master, stable ranges and extracted output.

## Checks and scope

Raw logs are retained under `/tmp/trigo-epic-48/`. Focused acceptance includes
`53-production-finalization-focused.log`, `53-public-finalization-exact-replay.log`,
`53-production-contention.log`, the isolated long-run logs above and
`53-generation.log`. `check:server` passes
formatting, lint, TypeScript, deterministic generation, 269 unit tests,
17 Worker tests and both Worker builds (`53-check-server-complete.log`).

The first native gate found the delay measurement problem above and an old
application-instance fixture that called the writer's final sync before storing
stop intent. The fixture now uses the actual ordered stop helper and checks
SQLite state rather than removed JSON paths. The final complete native gate
passes nine shared-contract tests and 152 native tests, including all full
duration and background work. Both dev/personal Debug app builds
and the local Worker/R2/fake-ASR smoke also pass (`53-check-macos-complete.log`).
The local smoke denies external network access. Nested dependency/toolchain locks
remain unchanged. `53-source-identity.log` records tested source subtrees and the
final commit/tree; only acceptance documentation is updated after the full gates.

This slice implements the local foundation interface only. No production upload,
ASR submission, synchronization, receipt cleanup, new product UI/shortcut,
installed-device acceptance, private recording, access to the owner's personal
credentials or cloud deployment is claimed. The ordinary native gate retains its
existing generic-password adapter test using a disposable synthetic item; this
does not constitute installed-app Keychain acceptance. Local media remains until
the future complete verified server receipt is durably committed; range success
is never cleanup authority.
