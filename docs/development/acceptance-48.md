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

The final implementation repair is `6b91203483927df909e560f106cda3e1fc1cd33d`,
tree `dddae2c46de41c9c31f2d5af6eed9753ddeb65c5`, Native subtree
`ac08242f05e9788f3af8b43e5b7fc43fd3f8b30e`. It is integrated as
`6505c7c3ecbfa5ae13ae978184a1f704ac2ebdaa` with the exact same complete tree.
Final acceptance-document edits do not alter this checked implementation. Current PR-tip CI is reported in the PR.

| Check                                                                      | Final local result                       |
| -------------------------------------------------------------------------- | ---------------------------------------- |
| Server gate                                                                | 338 unit tests, 36 Workers tests; passed |
| Native contracts                                                           | 9 tests; passed                          |
| Native Release suite                                                       | 176 tests; Swift Testing suite 162.792 s |
| Both Debug app variants                                                    | Passed                                   |
| Actual native/local smoke under external-network denial                    | Passed                                   |
| Contracts, formatting, lint, types, bundles, frozen locks and clean output | Passed                                   |

The Server gate ran on `82c158ac98589c584641dd60355198e858102570`; the only
subsequent candidate change was exception-safe queue release in a native test.
Server, contracts, tooling and native production sources are unchanged between
those candidates. The complete macOS gate ran on the final repair commit above.
`final-review/gates-candidate-6b9120348.json` under `/tmp/trigo-epic-48/` binds each
result and log hash to its actual source. These measurements are not a promised
speedup; baseline/cache comparisons remain in #49.

The final isolated Release binary, SHA-256
`e578bcdacc6f167336611f79211ef5cc271bdb1fe22b897b015c5c60e3903f08`, passed the
complete one- and three-hour production fixtures through extraction. Peak RSS was
54,411,264 B and 54,362,112 B, below the unchanged 83,886,080 B (80 MiB)
budget. They verified 57,600,000 and 172,800,000 frames in one permanent master per
fixture; test times were 33.422 and 107.186 s. Source-relative one-hour
drift was 0 ms. These are complete controlled synthetic proofs, separate from
installed recordings. `final-review/resource-proof.json` records source/binary/
helper identities, full fixture results and original logs.

The final local production contention case completed 146 real one-second commits,
all three imports, 12,000 turns and 24 large typed reads. Its maximum complete
input-through-independent-SQL-witness time was 1,049.755 ms, below two seconds.
The separate delayed-observer case preserved recovery and a second commit before
the caller returned. A caller-delay control isolates observation delay; a real
queue-delay control still detects a production durability violation.

The earlier [CI run 34154023151](https://github.com/apshenichniy/trigo/actions/runs/34154023151)
failed the delayed-observer case at 2,379.364 ms. Controlled RED probes established
that its test continuation could delay the next production stimulus after ingress
had drained. The test-only autonomous queue driver removes that dependency while
retaining every input buffer, real queue/service/SQLite delay and the unchanged
two-second assertion. The historical CI failure's precise cause remains
unconfirmed because its old drain phase combined production work and test
continuation delay. This failure and all controlled probe results are retained in
`final-review/ci-durability-diagnosis.md`; passing gates do not erase it.

## Performed installed checks

Controlled media inspection selected exactly three owner-created Chrome calls.
Other call media was excluded. The installed Native subtree was
`916ba1f510e62c91c85f31490d1df245a15f385c`. The performed signed rebuild at
`64086c8952150082172fb65ac1de507d404aab87` retained that Native subtree. The later
review repair above has a different Native subtree. It changes repository
projection/chunk handling and an equivalent private ingress enum; it does not
change SCK, microphone policy, readiness, credential/signing behavior, capture
clock or media format. Full final-source automated proofs cover that repair;
these physical observations retain their actual historical source identities.

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

Whole-epic review covered all 50 checkbox requirements and 44 additional prose
contracts. Standards review found two maintainability judgments and no documented
standard violations; Spec review found one typed interval-reason projection bug.
One implementer repaired all three. Both original reviewers rechecked the complete
repair and reported zero remaining or new findings. The typed reason regression
covers long UTF-8 values and literal reserved prefixes through read, reopen and
unrelated speaker publication while retaining original immutable bytes/hashes.
The shared bounded document writer also rejects conflicting incomplete chunks
before operation publication, resumes matching preparation and rejects corrupt
completed evidence without repairing it by replay. Raw review and RED/GREEN
artifacts are retained under `/tmp/trigo-epic-48/final-review/`.

The final audit retains the explicit #60 deferral and the performed observation
limits; it does not turn them into verified repairs or unavailable physical tests.

SQLite owns canonical and operational state without conflating capture,
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
