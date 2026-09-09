# Integrated first daily-use acceptance

Issue [#24](https://github.com/apshenichniy/trigo/issues/24) combines capture,
verified upload, automatic hosted transcription, canonical import/confirmation,
reader annotations and retained-audio playback. The
[first-use scope amendment](https://github.com/apshenichniy/trigo/issues/10#issuecomment-5587190710)
defers export/manual retranscription and Delete Call to #21/#22. The owner's
Meet/Telegram and real-speech evaluation remains #23 after this handoff.

## Candidate and evidence boundaries

The integration branch contains #73 playback, #19 canonical synchronization,
#72 native UI infrastructure, #58 Double Left Control, #45 measured recording
panel and #20 reader. Each component PR identifies its final source, required CI
and retained failures. Component passes are reusable only while their inputs and
integration context match. Final integrated source/check results belong in this
candidate's PR body and ignored timing/acceptance artifacts.

A synthetic no-speech provider is used for ordinary local/CI checks. It proves
actual URLSession, Worker, D1/R2, SQLite, canonical and player integration, but is
not hosted transcription. The explicit hosted harness below uses the same native
repositories, upload/synchronization coordinators and HTTP/player adapters.
It generates an accelerated synthetic master through the native durable writer;
it does not claim one or three hours of live ScreenCaptureKit or microphone input.
The source-clock, capture-loss and physical/installed evidence stays separate.

## Failure and recovery matrix

| Boundary                                                                                               | Executable coverage and evidence                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Microphone suppression, loss/reattachment, source permission/loss, sleep, disk/save and stop failures  | Native capture/control/coordinator suites; [capture](capture.md), [recording controls](recording-controls.md), [panel](recording-panel-acceptance.md).                                                                             |
| Termination and at most two seconds of recoverable tail loss                                           | Child-process termination and media-recovery suites; [production master](acceptance-53.md) and [capture](acceptance-15.md).                                                                                                        |
| One-hour source-relative drift at most 200 ms and complete three-hour durable media                    | Current full native resource suite, with the retained original source-specific measurements in [production master](acceptance-53.md).                                                                                              |
| Interrupted registration/parts/finalization and lost local receipt commit                              | `MasterUploadTests`, Worker upload suites and the actual local native/Worker smoke; [uploads](acceptance-17.md).                                                                                                                   |
| Cleanup only after a verified receipt                                                                  | Native upload/recovery suites and explicit full-path acceptance. The latter requires the original local master to be absent before restoration/playback.                                                                           |
| Initial ASR replay, uncertain provider/raw/artifact outcomes and original-plus-one replacement ceiling | Shared D1/R2/Workflow suites; [transcription](acceptance-18.md), [service contract](transcription-service.md). Polling cannot create a new logical operation.                                                                      |
| Immutable result/provenance import, local atomicity, confirmed snapshot, conflicts and fresh restore   | Native canonical/result recovery suites plus Worker replica suites and local HTTP smoke; [canonical synchronization](canonical-synchronization.md).                                                                                |
| Additive migration and retention of old evidence/annotations                                           | Native repository/legacy migration and canonical tests; exact old documents and transcript bytes are retained.                                                                                                                     |
| Owner rotation, rejection of stale credentials and stale publication/deletion fences                   | Server owner/upload/transcription/replica tests and native authorization transport tests. The retained [owner management](acceptance-30.md) describes performed Dev rotation; this harness does not rotate the current credential. |
| Reader selection, retained revisions, Unicode names/groups and explicit conflicts                      | `LibraryModelTests`, three reader UI scenarios and [reader evidence](library-reader.md).                                                                                                                                           |
| Playback renewal, pause/seek, stale response and exact stereo rendering after cleanup                  | `PlaybackTests`, HTTP transport tests and local native/Worker smoke; [playback](playback-service.md).                                                                                                                              |
| Menu/window/fullscreen, source-safe gesture, nonactivating measured panel, mute/Finish/recovery/Quit   | The thirteen-scenario integrated native UI selection, signed installed protocol and physical/OS observations below.                                                                                                                |
| Complete hosted one-/three-hour path and qualified five-minute Ready target                            | Explicit prepared acceptance runs below; local and historical isolated-provider proofs do not substitute.                                                                                                                          |

## Prepared full-path harness

Run from the warm integration checkout with the pinned `mise` toolchain. A
configuration selects exactly Dev. The owner's operator credential is supplied
through `TRIGO_ASR_OPERATOR_TOKEN` in the child environment, never an argument,
tracked file or printed result. The command rejects Personal and mixed local/cloud
target flags. Read-only preparation requires a clean committed hosted candidate.

```sh
mise exec -- bun scripts/daily-use-acceptance.ts prepare \
  --stage dev --profile one-hour \
  --directory .local/daily-use-acceptance-one-hour \
  --config /absolute/path/to/dev.json
```

Preparation reads authenticated status and creates only a dedicated local input:
real SQLite capture metadata, the native media/index, fixed upload/finalization
and automatic-ASR identities, and `plan.json`. It records source fingerprint,
configuration hash, both template hashes, full master/source-state hashes and
maximum provider submissions. No registration, upload, replica publication or
provider invocation occurs. Existing incompatible ownership, inputs or partial
preparation are retained and rejected, not overwritten.

The one-hour profile has 3,600,000 ms and 230,400,068 CAF bytes. The three-hour
profile has 10,800,000 ms and 691,200,068 bytes, with two-hour-plus-one-hour ASR
intervals. Their fixed maximum admissions are two and four provider submissions,
respectively, including the server's one allowed replacement attempt. A kernel
lease excludes concurrent invocations on one prepared directory.

After exact deployment/request authorization and budget reservation, run the
same prepared directory with its printed plan hash:

```sh
mise exec -- bun scripts/daily-use-acceptance.ts run \
  --stage dev --profile one-hour \
  --directory .local/daily-use-acceptance-one-hour \
  --config /absolute/path/to/dev.json \
  --plan-sha256 THE_REVIEWED_64_HEX_PLAN_HASH --allow-paid
```

Use `three-hour` and its own prepared directory/hash for the longer run. Admission
never follows from the command name alone: deployment, paid calls and budget
remain separately authorized. Reserve/settle each profile sequentially against
#13's existing EUR 20 ledger; no new allowance is implied by #24.

The run reopens and hashes the entire durable media before any upload. It sends
full transport parts while capture metadata remains active, records the Finish
request before native completion, then uses ordinary finalization/receipt cleanup
and canonical synchronization. Only the admitted synthetic call may register,
upload, finalize, request initial transcription or publish a canonical snapshot.
Other Dev catalog records can be read/restored into the isolated store but cannot
be mutated by this harness.

The completion proof checks:

1. Exact verified receipt, source-state hash and normal local master cleanup.
2. Actual available operation, attempt count, revision/provenance hash and length.
3. Every planned ASR frame interval and its independently computed WAV byte hash,
   exact stereo mapping and complete provider consumer-EOF/duration evidence.
4. Controlled source markers at the beginning, middle and end; every repeated
   marker slot is also reported, so recognition gaps stay distinguishable from
   transport truncation. This is synthetic coverage, not real-call quality.
5. Unicode individual naming and a cross-scope group, confirmed without rewriting
   immutable transcript bytes or changing the active revision.
6. Exact canonical, transcript, provenance and annotations restored into a new
   repository with no local capture session or audio cache.
7. The actual reader's Ready state, every paginated passage compared to exact evidence,
   timestamp actions taken from those projections, first/middle/final
   source audio, segment boundary and final audio frames through real HTTP and
   AVAudioEngine offline rendering. Both channels must contain nonzero matched
   samples. No physical audio device is used by this proof.

A private run directory retains stage timestamps, exact synthetic evidence and
numeric/hash summaries. A fresh one-hour run passes the latency gate only when
pre-Finish upload throughput is at least 10 Mbps, all five warm authenticated status
RTTs are at most 100 ms, the operation completes in its original attempt, and
Finish-to-Ready is at most 300,000 ms. It reports time to verified cleanup and time
to confirmed Ready separately. Resuming after prior upload/Finish never invents a
fresh latency measurement; the fixed IDs and earlier failures remain retained.
Replaying a completed plan returns its original successful receipt and performs
no new ASR request.

A one-minute local rehearsal uses the same command with `--profile local-smoke`
and `--local-config` instead of `--config`, against `bun run dev`. It rejects
`--allow-paid` and checks the explicit fake/no-speech provenance. Naming and
provider marker evidence are inapplicable to that rehearsal. All other transport,
cleanup, restoration and stereo-player checks remain real.

## Desktop and installed boundaries

The final thirteen-scenario native UI gate remains required. Ten shell/panel
scenarios passed on source `1bdee04f071a80a6c321725ed2e2630e9cf7dbdd` in run
`2026-09-08T23-44-14.428Z-24ece13a` (576.145 s). Reader integration later built
successfully, but two runs stopped before tests while enabling automation mode.
The previously passing root checkout also failed the same pre-test probe in
`2026-09-09T01-13-53.247Z-2ce4f49b` (85.703 s). These are failed executions,
not skipped tests or proof of a reader regression. See [reader](library-reader.md)
for the separate performed native UI controls and narrow light/dark observations.

The integrated source `410f7c694bca0939f89b118d8f16f7c303f9c3ee` built and installed
with the existing development signing identity at the stable worktree app path;
strict deep signature verification passed. Opening its library succeeded. Native
UI automation then crashed in `SkyComputerUseService` while selecting Settings;
the Trigo process remained alive. The service diagnostic reports a Swift array
removal assertion. No installed capture was admitted in that attempt. The
installation/configuration were retained; the exact owned idle process was stopped.
No archive or TCC reset, signing-identity replacement, or OS-security bypass was
used to turn this into a pass.

The remaining installed route uses [controlled installed capture](installed-capture-acceptance.md)
with an explicitly selected synthetic source. It must retain the exact installed
source/signature, scope, controls, effective microphone suppression, application
levels, source focus, recovery and safe Quit. Physical key delivery and OS consent
are recorded as performed or unavailable. The owner is not assigned a replacement
manual screenshot checklist. An unavailable automation capability stays an explicit
handoff limitation until an agent can execute the route.

## Handoff status

The PR records the committed candidate, performed current checks, prepared plan
identities, approved hosted outcomes and remaining external blockers. This document
alone does not close #24 or claim a working hosted transcriber. A runnable Dev
handoff includes the installed app path, launch/configuration, server target,
source identity and evidence; Personal still requires #32. #23 begins only after
this delivery and remains the owner's real-call/quality checkpoint.

## Retained harness development evidence

The first local preparation passed in 105.508 s, including a 91.081 s current-source
Release test build, on base `410f7c694bca0939f89b118d8f16f7c303f9c3ee` with dirty
fingerprint `f4b1bb1e793efdc3203c697c8977c965f9541d9f98acaa2953610dd9141f2fd3`.
The first run failed in 9.341 s before any upload: the harness incorrectly required
hosted transcription readiness from the deliberately unverified fake provider.
The corrected local branch explicitly requires `not_verified`; hosted still
requires `ready`. Product readiness was not changed.

The second local preparation passed in 68.020 s. Its complete run passed in
17.599 s, including 8.393 s inside the native acceptance test, on the same base
with dirty fingerprint `924f9aa0fc22f51e50fe54de885361a99ca53ab9865049e20504f4864a3abad7`.
The 60-second CAF retained all 960,000 frames / 3,840,068 bytes; fake ASR, exact
canonical restoration and both-channel HTTP/AVAudioEngine rendering passed at
12 positions, including the segment boundary and last 128 frames. The proof
compared 128 samples per channel per position and observed 384 nonzero microphone
samples and 768 nonzero application samples. The fake Ready time was 3,153.261 ms;
it is not a hosted latency measurement. A subsequent exact-plan replay passed in
9.663 s and returned the retained completion receipt without a new run/ASR.

The isolated input was `daily-use-acceptance-smoke-20260909-b`, call
`6ba7e6bc-2b44-41ba-b890-24a2b89ec496`, plan SHA-256
`4038cfa47cc7e92bb365f4253c5a5371829312c2391d04c6d5907504fbad2da0`.
Earlier inputs, logs and successful receipts are retained in ignored local data.

Review identified that taking long-call timestamps directly from decoded evidence
would not prove the reader's Load more path. The acceptance now traverses the
actual reader pages, requires progress, compares every projected passage and
uses those projections for playback positions. The focused 225-passage repository
probe passed in 67.520 s (1.400 s test time), exercising three pages and rejecting
changed final-passage evidence. Its input fingerprint on the same base was
`3cd102a5d9de394b0d807343a4b1e808d1818151eae835dbb1e17be12f1e98b8`.
Final source/CI results are recorded in the PR after this document is committed. The existing review found no additional spec or documented-standard
violations. No paid or installed pass is claimed by these local development runs.
