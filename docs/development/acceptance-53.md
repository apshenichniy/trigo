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

Temporary environment switches and SQL observers were removed. At that repair,
the original regression printed its worst cycle's component durations, and its
assertion still included preparation, queue/drain, final durability, caller delivery
and the SQL witness read.

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

## SQL durability witness and delayed observer

[Integrated CI run 34098630005](https://github.com/apshenichniy/trigo/actions/runs/34098630005)
at `6deea70cf1e39ee8e8372a9db621e79d87f9374b` retained one failure after
the SQL QoS correction. The production caller envelope was 2,168.677 ms,
including 1,114.989 ms between the synchronous advance returning on the engine
queue and its awaiting caller resuming. Construction/enqueue took 3.172 ms,
drain 34.192 ms, final queue admission 0.022 ms, advance 14.598 ms and the
post-delivery SQL witness/observer work 1.704 ms. The dense envelope was
1,532.428 ms. Both cases completed all three imports / 12,000 turns / 24 large
reads; the 152-test suite finished with this one issue in 282.169 s.
This is a different measured boundary from the earlier background SQL owner
stall; it does not establish which executor delayed the caller.

The approved [#48 contract](https://github.com/apshenichniy/trigo/issues/48)
and [#51 proof](https://github.com/apshenichniy/trigo/issues/51) limit lost
uncommitted audio to two seconds. [#52](https://github.com/apshenichniy/trigo/issues/52)
requires background work to preserve that commit window. The synchronous
production path completes timeline flush, media/index synchronization and
SQLite COMMIT before returning from `advance`. The contention fixture now also
queries and validates an independent confirmed SQL cursor on that engine queue
before taking its completion timestamp. The start precedes every PCM/sample
buffer construction and enqueue. All ingress/drain work, pre-witness
continuation waits, final queue admission, media/index synchronization, SQL
publication and the validating SQL read remain in the two-second bound.

The original post-delivery SQL read and observer work are retained. Separate
maximum durability and caller cycles print their complete phases, and the
maximum input-plus-caller and post-witness observer delays remain visible.
Only time after the validated durable witness is excluded from the loss bound;
these measurements do not claim a two-second UI acknowledgement guarantee.
The production application and repository code are unchanged by this correction.

A deterministic probe uses the same production input/sink/witness helper. Before
releasing its first result to the observer, it reopens a copy of the real master
and integrity index using the SQL witness, verifies 16,000 recovered frames with
no lost tail, drives the live queue through a second commit to 32,000 frames,
and verifies that the original stable byte prefix has not changed. It then
holds result delivery for another 1,100 ms. The old caller-based metric fails
with an input-plus-caller envelope of 2,215.715 ms even though the same execution
reached the validated SQL witness in 33.658 ms. All recovery/progress checks pass
(`53-delivery-observer-red-phases.log`). This proves the measurement distinction
without dropping capture work or requiring an application timing change.

The first probe run is separately retained in `53-delivery-observer-red.log`:
it also had an unlocalized 1,507.992 ms pre-witness delay, as well as 1,184.737 ms
after the witness. That run is not evidence of a caller-only failure. No warmup
or first-cycle exemption was added; the permanent first-cycle bound still fails
if such a pre-witness delay recurs. The subsequent phase-instrumented red run
above preserved the same first input and start boundary.

The focused green passes in 1.470 s with 40.011 ms through the validated SQL
witness and 1,219.692 ms through caller observation. Recovery, second-commit
progress and stable-prefix checks pass; input-plus-caller time still exceeds two
seconds and remains visible (`53-delivery-observer-green.log`).

The additional three-process amplified diagnostic remains **failed coverage**.
It runs the original five test functions per process, with the reference at t=0
and both siblings at t=97 s. All 18 imports / 72,000 turns / 144 large reads and
all long-call proofs eventually complete. However, all three production cases
reach the three-hour format limit before their last import phase; the reference
dense case reaches its unchanged 10,800-cycle guard. The runs finish in
518.804 / 484.686 / 481.328 s (`53-delivery-final-original-stress-*.log`).
No two-second durability assertion failure was recorded in those candidate runs,
but stopped capture during later import phases is not accepted as concurrency
coverage.

One controlled comparison restored the exact baseline test source from
`6deea70`, leaving all application, contract and script source unchanged. The
same amplified workload also fails there in 576.598 / 556.083 / 555.686 s:
all production cases reach the duration limit, and two dense cases reach the
cycle guard (`53-delivery-baseline-control-stress-*.log`). In the reference,
production phase three has no capture progress; both sibling production cases
have no progress in phases two and three. All imports and long-call proofs are
allowed to finish. That baseline additionally records a 6,128.661 ms old
input-plus-caller miss whose phase breakdown is unavailable after the later
capture abort; its cause is not inferred.

This diagnostic drives one second of input per 20 ms idle gap, plus processing
time, while imports run at wall-clock speed. Its unchanged three-hour media cap
can therefore be exhausted in minutes before the imports finish. Matching
baseline exhaustion does not prove an application regression from the added SQL
witness, a particular host cause, or successful amplified concurrency coverage.
No guard, input, pacing, threshold or import count was changed in that comparison.
The exact green candidate was restored; speculative query/priority changes were
not applied.

The required complete server gate passes on that restored source. The macOS
gate fails: 153 native tests finish in 484.227 s with three issues. Both
contention cases exhaust the same capture duration/cycle guard; production has
no capture progress during the final import phase. All background work finishes,
and no two-second deadline assertion fails in this run
(`53-delivery-check-macos-final.log`). This is failed required coverage.

A focused coarse phase probe preserves the entire workload and completes both
cases in 190.001 s. Each revision spends approximately 30–35 s in validated
encoding and 30–31 s in import; lifecycle operations and large reads finish in
milliseconds. These phases do not identify a particular codec or scheduling
cause. The dense case stays within its loss bound and both cases make capture
progress during every import phase. Production nevertheless records a real
2,481.216 ms input-plus-durability miss: 1,472.147 ms of its 1,481.216 ms
pre-witness time is buffer construction/submission
(`53-delivery-focused-background-phases.log`).

A two-cycle fresh-input probe localizes another real pre-witness miss to the
first synthetic buffer's format-description creation/assertion boundary:
1,507.298 ms there, versus 1,511.666 ms for submission and 1,522.342 ms through
the SQL witness. The second submission takes 1.277 ms. Recovery, live second
commit, stable-prefix and finalization checks still complete
(`53-delivery-focused-buffer-phases.log`). This C format-description creation
call occurs in the test producer; production `SCStreamOutput` receives a ready
`CMSampleBuffer`. The evidence does not yet distinguish the C call itself from
its surrounding test assertion.

After adding separate clocks for those two operations, one fresh process and
one sampled execution do not reproduce the stall: durability is 21.270 and
36.600 ms. These passes are diagnostic observations, not a demonstrated repair
(`53-delivery-focused-description-call.log`, `53-delivery-buffer-call-sampled.log`).
No pre-warming, first-cycle exemption, clock relocation, limit change or
application change was made during these localization probes.

## Fixture transport setup and wall-clock cadence

The final fixture builds its immutable 16 kHz mono format and Core Media format
description once as transport setup. ScreenCaptureKit supplies this metadata
with a ready callback buffer; creating it is synthetic producer setup. Each
measured cycle still allocates and fills all 50 PCM/sample buffers and performs
all 100 source enqueues after its start timestamp. The production sink and both
decoders receive their first input inside that boundary. Setup does not call
the sink or decoder and does not exempt any first-cycle service work.

The short recovery/progression probe repeats the startup delay in the new
explicit setup measurement: 1,565.892 ms. The first measured input reaches the
validated SQL witness in 14.263 ms: allocation/submission 2.903 ms, drain 4.942 ms,
advance/witness 6.407 ms. The probe passes in 2.928 s with 16,000 recovered frames,
32,000 live frames, an unchanged stable prefix and completed finalization
(`53-delivery-input-setup-green.log`). Its 1,178.208 ms caller observation still
exceeds the old two-second envelope when one second of input is added. This is
a fixture boundary correction; it does not identify an internal C API or
assertion cause, or claim an application startup improvement.

Each contention cycle now supplies one source second per wall-clock second.
After measured work and observer accounting, it waits until one second after
that cycle's own start. An overrun remains measured and delays subsequent input;
there is no catch-up burst. Thus background imports and the finite three-hour
capture progress against the same clock. Both cases still require at least
120 commits, all three imports / 12,000 turns / 24 large reads, capture progress
during every import phase, the unchanged three-hour cap and the complete
two-second loss bound. The separate one-hour/three-hour, resource, recovery and
fault proofs are unchanged. The former 50x diagnostic failures remain failed
coverage under that artificial source clock.

The final focused contention run passes in 142.684 s. Both cases complete
136 commits and all three imports / 12,000 turns / 24 large reads; each phase
has capture progress (`0 -> 50 -> 95 -> 136`). Maximum input-plus-durability is
1,053.603 ms dense and 1,029.179 ms production. Production retains complete
source coverage with at most 100 pending buffers / one source second and
9.590 ms maximum ingress service. Its separately measured input-plus-caller
maximum is 1,029.252 ms (`53-delivery-wall-clock-contention-green.log`).

Both required complete gates pass on the final source:

- `53-delivery-wall-clock-check-server.log`: formatting, lint, types,
  deterministic generation, 269 unit tests, 17 Worker tests and both Worker bundles.
- `53-delivery-wall-clock-check-macos.log`: nine contract tests, 153 native tests
  in 197.133 s, both Debug app builds and the local Worker/R2/fake-ASR smoke with
  external network denied.

Inside the complete concurrent native suite, production completes 180 commits
and dense completes 181. Each finishes all three imports and has capture progress
in every phase. Their maximum input-plus-durability envelopes are 1,115.559 ms
and 1,116.358 ms respectively. Production retains complete source coverage and
its one-second ingress capacity; maximum ingress service is 12.045 ms. The
delayed-observer probe also passes in that suite, with 208.913 ms to durability
and 2,948.771 ms to its deliberately delayed observer. The full one-hour and
three-hour production proofs finish in 53.633 s and 125.290 s; these concurrent
timings are not replacements for the historical isolated resource measurements.

The tested `RepositoryContentionTests.swift` SHA-256 is
`08e2af3a631eb866edf8fb3aa782eb78519799adf3eb78221c3b6d0522b3d2dc`.
Application, contract, dependency and script source are identical to the
`6deea70` integration base. This local test-only correction does not complete
the separate hosted CI or installed signed-app gates.
