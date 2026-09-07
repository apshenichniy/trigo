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
| #54   | Shared local/cloud product HttpApi      | Pending                                                                                                                                                                     |
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

Green integration CI is required before resuming #54. The current integrated
commit and CI result are recorded in [PR #59](https://github.com/apshenichniy/trigo/pull/59);
historical successful runs do not replace verification of the current source.

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
