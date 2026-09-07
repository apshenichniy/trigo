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

## Integrated verification

Integrated commit `985b05d815e946632d5b1867468d5bcb28e6c767` has tree
`87747c5788a75e7a98dc10e30c0c4c492a0d0ff5`, exactly matching the tested
worker commit `8c17210a00bda7120c8c2901049ce30e0f0a2e1b`. No merge conflict
or source adjustment was required. All 66 scoped files were preserved; prior
acceptance ledgers, dependencies, toolchain pins and vendored reference were unchanged.

Both jobs passed in [integrated CI run 34073823026](https://github.com/apshenichniy/trigo/actions/runs/34073823026):
[server checks](https://github.com/apshenichniy/trigo/actions/runs/34073823026/job/101596024047)
and [macOS checks](https://github.com/apshenichniy/trigo/actions/runs/34073823026/job/101596024010).
The jobs also confirmed checks left tracked files unchanged. Raw runner logs and
job metadata are retained in `53-ci-server.log`, `53-ci-macos.log` and the
corresponding `53-ci-*-job.json` files under `/tmp/trigo-epic-48/`.

The server job took 91 s; macOS took 602 s with both native caches missing.
The runner passed all 152 native tests in 237.812 s, both Debug app builds,
the nine contract tests and the network-denied local smoke. Its completed
production background workload performed all three imports and 24 large reads,
with 635 capture commits and a maximum 1,345.831 ms input-through-durability
envelope. The delayed-queue fixture reached durability in 1,343.379 ms. Its
post-commit delivery to MainActor was delayed another 26,692.168 ms under the
concurrent full suite; that separate caller-scheduling measurement is retained
and is not a claim that UI response latency meets the durability bound.

## Warm-run SQLite contention correction

A second [integrated CI run 34074455910](https://github.com/apshenichniy/trigo/actions/runs/34074455910)
failed the unchanged two-second envelope: 2,005.565 ms for the dense fixture and
2,215.234 ms for the production sink. Its source/configuration matched the passing
run; only acceptance documentation differed. All three imports and large-read
phases completed. That failure reopened this slice's concurrency acceptance.

Unchanged local source reproduced the deadline failure with three concurrent
test processes. Narrowing the workload retained the complete contention fixture
and the complete three-hour production proof; two processes still failed. A
one-import diagnostic helped locate the delay but was not used for acceptance.
The full three-import diagnostic measured a 1,805.178 ms dense cycle: 1,804.174 ms
was in the repository path, including 1,782.598 ms waiting for a background SQL
owner whose body took 1,810.294 ms. Preparation, external media synchronization
and caller delivery did not account for that miss. Sampling caught background
revision staging in SQLite rollback-journal writes while capture waited.

The shared owner previously performed SQL at its caller's priority after
releasing the condition mutex. Capture admission preference did not promote the
background owner during disk I/O. Each synchronous SQL scope now directly
performs a work item with a user-initiated QoS floor, including admission and
owner release. It retains higher caller priority and restores the caller context
afterward. Preparation, validation and serialization stay outside the SQL scope;
transaction sizes, full synchronization, capture preference and public repository
behavior remain unchanged.

A controlled intervention changed only the bounded SQL body's QoS. All three
processes completed 18 imports / 72,000 turns / 144 large reads and all three
complete three-hour proofs. Dense maxima fell from 624-1,805 ms to 191-222 ms;
production maxima fell from 697-856 ms to 154-181 ms. No measured SQL admission
wait or body exceeded 200 ms. The baseline and intervention are retained in
`53-contention-phases-three-imports-*.log` and
`53-contention-qos-three-imports-*.log`; the diagnostic record is
`53-contention-causal-measurements.md`. Sampling is supporting evidence; the
unchanged-source failures also occurred without sampling.

Temporary environment switches and SQL observers are removed. The original
regression now prints its worst cycle's component durations, while the assertion
still includes preparation, queue/drain, final durability, caller delivery and the
SQL witness read.

The cleaned final source passed the original larger stress scenario in three
processes, each running the same five test functions. The reference starts at
t=0; both siblings start at t=97 s, matching the original staggered failure.
All processes complete their full imports and one/three-hour proofs, passing in
224.787 / 273.963 / 272.238 s. Maximum input-plus-complete-cycle envelopes are
1,295.218 ms dense and 1,269.543 ms production. This final run uses no diagnostic
switches or sampling (`53-contention-final-original-stress-*.log`).

Both required final gates pass: `53-contention-check-server-final.log` contains
269 unit tests, 17 Worker tests, formatting/lint/types/generation and both Worker
bundles; `53-contention-check-macos-final.log` contains nine shared-contract tests,
all 152 native tests, both Debug app builds and the network-denied local smoke.
The native suite takes 191.241 s. Its complete contention envelopes are
1,319.982 ms dense and 1,279.934 ms production; delayed-queue durability is
1,345.888 ms, with another 244.343 ms separately measured for caller delivery.
The complete one-hour common-clock proof retains 0.0 ms worst source-relative drift.

The exact Release helper is reused for isolated resource checks on this source.
The one-hour proof passes in 36.018 s with a 54,198,272 B peak RSS through full
extraction (`53-contention-final-isolated-one-hour-1.log`). The three-hour proof
passes in 108.213 s with a 43,433,984 B peak RSS through full extraction
(`53-contention-final-isolated-three-hour-1.log`). Both remain below 80 MiB and
retain the exact frame counts, source intervals, master hashes and snapshot bytes
listed above. `53-contention-final-tested-source.log` records the matching source
and Release-helper hashes; `53-contention-source-identity.log` records the final
commit/tree and its relationship to the tested source.

The cold runner spent 23.583 s building contract tests, 110.163 s building native
Release tests, 45.541/8.164 s building the dev/personal Debug apps and 6.133 s on
local smoke. These totals include the additional #50–#53 acceptance workload
and must not be presented as the unchanged #49 timing benchmark.

These integrated checks do not satisfy the separate installed signed-app gate #57.
