# Recording foundation refactor acceptance

Canonical scope: [epic #48](https://github.com/apshenichniy/trigo/issues/48).
The approved specification and child issues own the requirements. This document
records implementation and verification evidence for the integrated source.

Baseline: `36d381e2a6b0eb5d32f0f619625650ef88b4febc`.

## Delivery evidence

| Issue | Boundary                                | Evidence                                                                                                                                                                              |
| ----- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| #49   | macOS check performance                 | Implemented; local and cold/restored CI passed ([evidence](acceptance-49.md))                                                                                                         |
| #50   | Effect Schema and typed Swift contracts | Implemented; local and integrated CI passed ([evidence](acceptance-50.md))                                                                                                            |
| #51   | Recoverable master format proof         | Implemented; bounded media proofs, local gates and integrated CI passed ([evidence](acceptance-51.md))                                                                                |
| #52   | SQLite archive and durable operations   | Implemented; transaction/recovery checks passed; the shared contention correction is verified with #53 ([evidence](acceptance-52.md))                                                 |
| #53   | Production stereo master recording      | Implemented; contention correction passed full local gates, original stress and isolated resource proofs ([evidence](acceptance-53.md)); current integration CI is reported in the PR |
| #54   | Shared local/cloud product HttpApi      | Pending                                                                                                                                                                               |
| #55   | Permissions and Keychain readiness      | Pending                                                                                                                                                                               |
| #56   | Commands and architecture documentation | Pending                                                                                                                                                                               |
| #57   | Installed signed app acceptance         | Pending owner-assisted execution                                                                                                                                                      |

## Contention correction

After the first passing #53 integration run, a source-identical
[CI run 34074455910](https://github.com/apshenichniy/trigo/actions/runs/34074455910)
exceeded the preserved two-second capture window during background archive work.
The coordinator paused #54 and reopened this concurrency acceptance. The failure,
measured cause and controlled intervention remain in [the #53 evidence](acceptance-53.md).

The correction prevents background SQL disk I/O from retaining the shared owner
at background priority while capture waits. The final source passes the original
three-process stress, complete server/macOS gates, and isolated one/three-hour
resource proofs. Its maximum complete input-through-durability envelope was
1,319.982 ms in the full native suite. Peak isolated RSS through full extraction
was 54,198,272 B for one hour and 43,433,984 B for three hours, below 80 MiB.
Durability settings, input durations, batch sizes and acceptance limits are unchanged.

Green integration CI is required before resuming #54. The current integrated
commit and CI result are recorded in [PR #59](https://github.com/apshenichniy/trigo/pull/59);
historical successful runs do not replace verification of the correction.

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
