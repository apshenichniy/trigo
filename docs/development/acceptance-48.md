# Recording foundation refactor acceptance

Scope: [epic #48](https://github.com/apshenichniy/trigo/issues/48), implemented in
[PR #59](https://github.com/apshenichniy/trigo/pull/59) against baseline
`36d381e2a6b0eb5d32f0f619625650ef88b4febc`.

The foundation now uses one transactional SQLite repository, one recoverable
stereo CAF master per call, Effect-authored exchange schemas with generated Swift
models, and one authenticated HttpApi composition for local and cloud execution.
The source retains ScreenCaptureKit, Alchemy, app variants, namespace isolation,
scoped Keychain credentials, and the existing capture and durability bounds.

The owner directed delivery to continue on 2026-09-07 with the intermittent
installed-start overflow deferred to [#60](https://github.com/apshenichniy/trigo/issues/60).
That failure is unresolved. Successful subsequent recordings are evidence of
those runs, not proof of a fix or universal startup reliability.

## Delivery and evidence

| Issue | Delivered boundary                                                                                                                | Evidence                                                                           |
| ----- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| #49   | Optimized native checks, versioned caches, frozen resolution and measured cold/restored paths                                     | [Acceptance](acceptance-49.md)                                                     |
| #50   | Effect Schema authoring, typed Swift generation, shared validation corpus and immutable-byte preservation                         | [Acceptance](acceptance-50.md)                                                     |
| #51   | Stereo LPCM CAF, stable header/ranges, incremental integrity index, bounded seek/extraction and fault recovery                    | [Acceptance](acceptance-51.md)                                                     |
| #52   | Typed SQLite archive and semantic capture/import/operation transactions, conflicts and interruption recovery                      | [Acceptance](acceptance-52.md)                                                     |
| #53   | Production recorder using the selected master and repository, effective microphone suppression and bounded durability             | [Acceptance](acceptance-53.md), [master interface](capture-master-interface.md)    |
| #54   | Shared authenticated status/error API, isolated local D1/R2/workflow composition and fake ASR                                     | [Acceptance](acceptance-54.md)                                                     |
| #55   | Explicit readiness actions, separate authorization/device/credential states and safe installed credential continuity              | [Acceptance](acceptance-55.md), [installed observations](acceptance-57.md)         |
| #56   | Thin development commands, argument/failure consistency, obsolete-path cleanup and current architecture/setup entrypoints         | [Acceptance](acceptance-56.md), [architecture](architecture.md), [setup](setup.md) |
| #57   | Performed controlled recording, interruption recovery, source exit, ordinary relaunch/authentication and supported signed rebuild | [Installed evidence](acceptance-57.md), with the disclosed #60 deferral            |

## Final checked source and measurements

The complete local gates and [CI run 34142151962](https://github.com/apshenichniy/trigo/actions/runs/34142151962)
passed for `9b852477fd19273014febf026b34b1630cc1b041`, tree
`9f05d894d4d60fdcc34e04438fa25f13669a7ee3`. Both CI jobs checked out synthetic merge
`10f613f3db0cc37911d27da63cb33b1147fdcf15`; its complete tree matched the PR source.
The final cleanup/rebuild source `64086c8952150082172fb65ac1de507d404aab87` restores
that exact full tree. Subsequent acceptance-document changes do not alter the
checked implementation. Current PR-tip CI is reported in the PR.

| Check                                                                      | Local result                               | CI result                                 |
| -------------------------------------------------------------------------- | ------------------------------------------ | ----------------------------------------- |
| Server gate                                                                | 338 unit tests, 36 Workers tests; 30.260 s | Same counts; job 79 s                     |
| Native contracts                                                           | 9 tests                                    | 9 tests                                   |
| Native suite                                                               | 171 tests; test runner 179.821 s           | 171 tests; test runner 279.671 s          |
| Complete macOS gate                                                        | 316.630 s                                  | Job 616 s                                 |
| Both Debug app variants                                                    | Passed                                     | Passed                                    |
| Actual native/local smoke under external-network denial                    | Passed; 18.210 s                           | Passed; 24.612 s                          |
| Contracts, formatting, lint, types, bundles, frozen locks and clean output | Passed                                     | Passed, including nested-lock restoration |

These measurements are not a promised speedup. Baseline and cache comparisons
remain in #49; later source-specific timings and intermediate failures remain in
their owning acceptance documents. Both native caches in the final CI run restored
from prior compatible keys and saved under the current checkout. Cache reuse did
not skip compilation or checks.

The final isolated Release binary passed the complete one- and three-hour
production fixtures through extraction. Peak RSS was 54,460,416 B and 50,266,112 B,
below 80 MiB. They verified 57,600,000 and 172,800,000 frames in one permanent
master per fixture; test times were 34.952 and 111.767 s. Source-relative one-hour
drift was 0 ms. These are controlled synthetic proofs, separate from the installed
recordings. The exact binary, helper and log hashes are recorded in
`57-final-resource-proof.json` under `/tmp/trigo-epic-48/`.

The final CI contention cases completed 135 dense and 146 production commits,
all three imports, 12,000 turns and 24 large typed reads per case. Maximum complete
input-through-durability times were 1,174.165 and 1,183.666 ms, below two seconds.
A separate delayed-observer case verified recovery and another commit before its
caller returned; the retained evidence distinguishes durability from caller delay.

## Performed installed checks

Controlled media inspection selected exactly three owner-created Chrome calls.
Other call media was excluded. The installed Native subtree was
`916ba1f510e62c91c85f31490d1df245a15f385c`, identical to the final clean source.

- The 35.118-second core recording retained application audio across owner focus
  changes and microphone on/off/on actions. The microphone's 8.855-second muted
  interval contained exactly zero samples; unavailable intervals were also zero.
  SQLite, immutable documents, channel mapping, index, stable header and the
  single stereo master agreed.
- A controlled SIGKILL left 75.282 seconds of committed media. Relaunch recovered
  the complete independently observed post-kill prefix unchanged, preserved all
  call/track/master identities, and marked the call interrupted. The owner
  confirmed capture did not restart. This is separate from the deterministic
  two-second loss-bound and corruption/short-write proofs.
- Closing the owned Chrome process interrupted its separate 114.740-second call
  with `source_exited`; retained media and prior verified calls remained intact.
  The owner did not separately report the exact source-loss UI wording.
- An ordinary owner Quit and unchanged relaunch retained the app-owned credential
  account. The owner used Retry saved connection and Validate and save, reported
  `authenticated`, and saw no system dialogs.
- The final supported signed rebuild retained the installed path, bundle/team,
  designated requirement, namespace and committed credential account. After the
  requested unchanged Retry/Validate actions, the owner reported everything OK
  and permissions `granted`. The exact connection-status word and a separate
  dialog response were not quoted in that final reply. Source/build hashes and
  these observation limits are recorded in the #57 evidence.

The observed system dialog concerned direct screen/audio capture, not Keychain.
The earlier recurrence cause remains unconfirmed. The explicit readiness-request
regression was fixed separately; ScreenCaptureKit can still present OS-controlled
consent/reminder UI despite granted preflight. No global privacy/Keychain reset,
credential replacement by an external helper, or weakened access was used.
Physical unplug/reconnect was unavailable because the owner had only the built-in
microphone. Deterministic denial/revocation/credential-loss cases remain distinct
from physically performed observations.

Two later diagnostic calls of 36.466 and 12.343 seconds stopped normally, including
a second start in the same process. A ten-second metadata trace did not reproduce
the earlier overflow. Its four dropped rows prohibit absence/accounting claims.
All temporary diagnostics and opt-in behavior were removed; the raw investigation
is retained for #60 and is not described as a production repair.

## Corrections and retained contracts

The #53 contention correction prevents background SQL disk I/O from retaining the
shared owner at background priority while capture waits. Later failures exposed
fixture measurement and pacing errors; the final tests retain all input, ingress,
queue and persistence waits, all background work, and the original two-second
limit. The detailed causal evidence and unsuccessful runs remain in
[acceptance-53](acceptance-53.md).

Installed verification also exposed a separate startup-clock defect: application
audio can arrive before native Start acknowledges. The clock now starts before
that boundary. Finite callback regressions cover delayed application/microphone
acknowledgements, microphone suppression and cancellation without conflating a
lifecycle test with unlimited producer throughput. This fix is not an established
cause or cure of #60.

The final audit covers all 50 checkbox requirements and the additional prose
contracts. SQLite owns canonical and operational state without conflating capture,
upload, transcription, import, replica and deletion. Immutable bytes/hashes and
uncertain operation identity remain authoritative. Media stays outside SQLite;
only durable ranges are published. Effect schemas are the structural source;
provider/semantic validation and binary evidence remain separate. The local app
uses the product authenticated-status path with fake ASR and no cloud credentials
or inference; future product endpoints are not claimed here.

[The master interface](capture-master-interface.md) and
[architecture handoff](architecture.md) retain upload during capture, post-call
ASR, the 8 MiB request cap and actual multipart constraints, whole-master checksum
verification, bounded channel/interval provenance, and retaining local media until
a complete verified server receipt is durably committed locally. Receipt-driven
automatic cleanup remains product work, not an implemented foundation shortcut.

Hosted ASR compatibility remains [#13](https://github.com/apshenichniy/trigo/issues/13).
Production upload/ASR/synchronization, transcript UI, compact measured recording
feedback, double-Left-Option and private real-call acceptance remain
[#10](https://github.com/apshenichniy/trigo/issues/10) and its existing children.
Infrastructure state recovery [#32](https://github.com/apshenichniy/trigo/issues/32)
still gates the first personal deployment. The known startup issue #60 remains
open. PR merge and deployment require separate owner instructions.
