# Recording foundation refactor acceptance

Canonical scope: [epic #48](https://github.com/apshenichniy/trigo/issues/48).
The approved specification and child issues own the requirements. This document
records implementation and verification evidence for the integrated source.

Baseline: `36d381e2a6b0eb5d32f0f619625650ef88b4febc`.

## Delivery evidence

| Issue | Boundary                                | Evidence                                                                                                                                                                    |
| ----- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| #49   | macOS check performance                 | Implemented; local and cold/restored CI passed ([evidence](acceptance-49.md))                                                                                               |
| #50   | Effect Schema and typed Swift contracts | Implemented; local and integrated CI passed ([evidence](acceptance-50.md))                                                                                                  |
| #51   | Recoverable master format proof         | Implemented; bounded media proofs, local gates and integrated CI passed ([evidence](acceptance-51.md))                                                                      |
| #52   | SQLite archive and durable operations   | Implemented; transaction/recovery checks passed; shared contention acceptance follows the current #53 evidence ([evidence](acceptance-52.md))                               |
| #53   | Production stereo master recording      | Implemented; current durability and contention verification is recorded in the linked evidence ([evidence](acceptance-53.md)); current integration CI is reported in the PR |
| #54   | Shared local/cloud product HttpApi      | Implemented; local server/native/offline checks passed; current integration CI is reported in the PR ([evidence](acceptance-54.md))                                         |
| #55   | Permissions and Keychain readiness      | Pending                                                                                                                                                                     |
| #56   | Commands and architecture documentation | Pending                                                                                                                                                                     |
| #57   | Installed signed app acceptance         | Pending owner-assisted execution                                                                                                                                            |

## Contention correction

After the first passing #53 integration run, a source-identical
[CI run 34074455910](https://github.com/apshenichniy/trigo/actions/runs/34074455910)
exceeded the preserved two-second capture window during background archive work.
The coordinator paused #54 and reopened this concurrency acceptance. The failure,
measured cause and controlled intervention remain in [the #53 evidence](acceptance-53.md).

The production correction prevents background SQL disk I/O from retaining the
shared owner at background priority while capture waits. It passed the original
three-process stress and isolated one/three-hour resource proofs. The measured
isolated peak RSS through full extraction was 54,198,272 B for one hour and
43,433,984 B for three hours, below 80 MiB. These are historical measurements of
the unchanged production source, not substitutes for subsequent required gates.

[CI run 34098630005](https://github.com/apshenichniy/trigo/actions/runs/34098630005)
then exposed a measurement boundary problem: its slowest production observation
included 1,114.989 ms after the synchronous durable operation had already ended.
The contention fixture now records a validated, independently read SQLite cursor
on the capture queue before timestamping durability. It retains every preceding
input, ingress, queue and persistence wait. A separate delayed-observer test
reopens the committed master and verifies another capture commit and unchanged
stable bytes before releasing the first result. Caller delay remains reported.

Further local checks exposed two distinct fixture problems. Immutable synthetic
format metadata was repeatedly built inside capture timing, although
ScreenCaptureKit supplies that metadata before the application receives a sample.
Only this producer setup moves outside the timer; PCM/sample construction and the
first production decoder use remain measured. The old fixture also used
a 20 ms idle gap per generated source second, exhausting the real three-hour
cap before its background work completed. Capture now produces one second of audio
per wall-clock second without catch-up bursts. It retains at least 120 commits,
all three imports, 12,000 turns, 24 large typed reads and capture progress during
every background revision. The two-second durability limit and all separate
long-call, recovery and bounded-resource fixtures remain unchanged. Failed runs
and the limits of the causal evidence remain in the #53 acceptance document.

The current fixture source passes the full server gate (269 unit tests, 17
Worker tests, deterministic contracts, formatting/lint/types and both Worker
bundles) and macOS gate (nine contract tests, 153 native tests in 197.133 s,
both Debug app builds and the network-denied local Worker/R2/fake-ASR smoke).
In the full native suite, dense capture completed 181 commits and production
capture 180, with all background work and per-revision progress confirmed.
Their maximum complete input-through-durability envelopes were 1,116.358 ms
and 1,115.559 ms. Raw logs: `53-delivery-wall-clock-check-server.log` and
`53-delivery-wall-clock-check-macos.log` under `/tmp/trigo-epic-48/`.

Both jobs of [CI run 34108231975](https://github.com/apshenichniy/trigo/actions/runs/34108231975)
passed on `7db0f90ff4ed86d90218fe8c249693d55c4c2f88`, completing #53 verification.
The runner passed all 153 native tests in 196.382 s; both contention cases
completed 120 commits, all background work and capture progress during every
revision. Their maximum input-plus-durability envelopes were 1,085.466 ms dense
and 1,266.190 ms production. The separate observer probe reached durability in
774.660 ms while its caller received the result in 10,300.414 ms, after verified
recovery and further capture progress. Both jobs checked out synthetic merge
`50e590a44d9709b154873aeeef495b3d254cc77b`, whose tree exactly matched the PR tip.

Current integration source and CI results remain in
[PR #59](https://github.com/apshenichniy/trigo/pull/59). Historical successful runs
do not replace verification of later source changes.

## Shared product API and local execution

The #54 composition uses the same authenticated Effect HttpApi handler for local
and cloud status/error behavior. Its local D1/R2/workflow path exercises the
shared deterministic fake-ASR seam and preserves state across a local restart.
The private CLI-to-native configuration joins the Effect-authored generated
contracts; a shared 16-case corpus checks structural acceptance/rejection in
Effect, JSON Schema, generated Swift and both file readers. File ownership,
worktree identity and exact loopback origin remain contextual checks.

The final local server gate passed 304 unit tests, 36 Workers-runtime tests,
formatting/lint/types, deterministic generation and both Worker bundles. The
macOS gate passed nine contract tests, 161 native tests in 352.156 s, both Debug
app builds and the actual native/local composition smoke under the external
network-denial profile. The native suite completed 319 dense and 321 production
capture commits, all three imports, 12,000 turns and 24 reads per case; maximum
input-through-durability envelopes were 1,194.406 ms and 1,217.283 ms. This is
the measured final run; earlier #54 timings describe earlier source snapshots.

The local smoke uses current-source test compilation followed by execution under
the outer offline profile. The final incremental build took 3.40 s; the complete
smoke took 16.941 s. It verifies native URLSession pairing, failed credentials,
retained binding and unavailable operations against the actual Alchemy runtime.
It uses disposable credentials and does not establish installed-app Keychain,
physical permission or bundle ATS behavior. Those observations remain in #57.
Raw final logs are `54-check-server-final.log` and `54-check-macos-final.log`
under `/tmp/trigo-epic-48/`; [the #54 evidence](acceptance-54.md) records scope,
source identity and earlier failed checks.

## Completion boundary

Deterministic tests, CI, media proofs and installed-app observations are separate
evidence. Record the exact source/build identity and observed results for each.
Do not mark physical permission or Keychain behavior verified through mocks.

The final gate requires controlled non-private capture, interruption/relaunch,
normal app-owned credential use across relaunch and a supported signed rebuild,
and the local authenticated status flow. A prepared procedure alone does not
complete #57 or the epic.

Hosted ASR and the final product workflow remain in #10 and #13. Infrastructure
state recovery #32 remains a gate before first personal deployment. PR merge and
deployment follow the repository's separate owner-instruction policy.
