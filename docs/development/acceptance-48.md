# Recording foundation refactor acceptance

Canonical scope: [epic #48](https://github.com/apshenichniy/trigo/issues/48).
The approved specification and child issues own the requirements. This document
records implementation and verification evidence for the integrated source.

Baseline: `36d381e2a6b0eb5d32f0f619625650ef88b4febc`.

## Delivery evidence

| Issue | Boundary                                | Evidence                                                                                                                   |
| ----- | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| #49   | macOS check performance                 | Implemented; local and cold/restored CI passed ([evidence](acceptance-49.md))                                              |
| #50   | Effect Schema and typed Swift contracts | Implemented; local and integrated CI passed ([evidence](acceptance-50.md))                                                 |
| #51   | Recoverable master format proof         | Implemented; bounded media proofs, local gates and integrated CI passed ([evidence](acceptance-51.md))                     |
| #52   | SQLite archive and durable operations   | Implemented; local transaction, recovery and contention gates passed; integrated CI pending ([evidence](acceptance-52.md)) |
| #53   | Production stereo master recording      | Pending                                                                                                                    |
| #54   | Shared local/cloud product HttpApi      | Pending                                                                                                                    |
| #55   | Permissions and Keychain readiness      | Pending                                                                                                                    |
| #56   | Commands and architecture documentation | Pending                                                                                                                    |
| #57   | Installed signed app acceptance         | Pending owner-assisted execution                                                                                           |

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
