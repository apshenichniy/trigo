# Issue #56: current development commands and architecture

This slice starts from the accepted #55 integration
`e0ab70a6f70b94f9a89b91ae8cae01335caed833` on `codex/epic-48-issue-56`.
It owns command syntax, current documentation and confirmed obsolete scaffolding.
Native capture/repository sources, fixtures, budgets, cadence, dependency locks,
CI coverage and the pinned Effect subtree are unchanged.

## Delivered scope

- Shared wrapper argument handling rejects unknown/duplicate options and missing
  values before tool, generation, local runtime or ASR operations. Native flags
  are scoped to their supported actions. Cloud bootstrap/deploy reject extra
  arguments before profile validation; account/stage/profile and personal gates
  remain in their existing owners. Native cache identity includes the shared parser.
- README leads to the architecture map and current setup. Capture/readiness and
  contract docs describe the implemented CAF/SQLite/shared API, explicit permission
  actions and scoped credentials. The glossary separates complete durable server
  receipt from partial progress and from other lifecycle dimensions.
- The unreferenced `scripts/unavailable.ts` placeholder is removed after live cloud
  entrypoints and their failure guards passed. Earlier tickets already removed the
  JSON file-store/lifecycle/journal writers, legacy WAVE capture/checkpoint/receipt,
  old fixture-only transcription API and json-schema-to-typescript generator.
  Their historical acceptance documents retain the original evidence; the current
  architecture map identifies superseded portions. AJV remains required for parity.
- Ordinary ripgrep searches exclude the tracked read-only Effect reference through
  `.ignore`; explicit `rg --no-ignore <pattern> repos/effect/<path>` still reads it.

## Final verification

Both required gates passed on staged tree
`eb091a9a68bef1bcfbf105c2b8e688d5ed207a3c`. The final commit has the same application,
script, package and infrastructure subtrees; only this acceptance document was
updated after the gates. The `apps` subtree, including native app/tests, equals accepted #55
(`ab3541a35a90afc185681ceff99ab3c24f825e47`).

| Check                                             | Result                                                                                                                                                                                                |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Frozen dependency install and locked native setup | Passed; setup took 57.12 s in this new worktree. No dependency/toolchain lock changed.                                                                                                                |
| Focused command/signing/cloud/cache cases         | 61 passed, including malformed/duplicate options, no-argument checks, cloud rejection before profile access and native cache invalidation.                                                            |
| `check:server`                                    | Passed in 33.88 s: formatting, lint, types, deterministic generation, 338 unit tests, 36 Workers tests and local/cloud bundles.                                                                       |
| `check:macos`                                     | Passed in 464.02 s: 9 Debug contract tests, 169 Release native tests, both unsigned Debug apps and the actual sandboxed local/native smoke.                                                           |
| Actual native/local smoke                         | 26.418 s overall; the URLSession pairing/restore/unauthorized/unavailable case took 0.204 s, with isolated metadata/in-memory credentials and external networking denied.                             |
| Real generated-project cache-hit lock repair      | Passed after deleting only the disposable nested lock and running `bun scripts/macos.ts prepare`; restored bytes equal the tracked canonical lock.                                                    |
| Tracked-source/lock integrity and navigation      | All tracked hashes stayed equal before/after both gates and both resource proofs. New local Markdown links resolve; normal ripgrep lists zero `repos/` paths and explicit reference reads still work. |

The unchanged contention fixtures completed 260 dense and 261 production capture
commits, every background phase, all three revision imports/12,000 turns and all
24 oversized typed reads. Maximum input-plus-durability envelopes were
1,652.748 ms / 1,604.164 ms under the preserved 2,000 ms bound. The independent
SQL witness in the delayed-observer case reached durability in 341.580 ms, while
caller delivery took 3,836.088 ms; the test verified recovery and further progress
before that observer completed. These are distinct durability/observer measurements,
not UI latency promises. The full common-clock fixture retained 0.0 ms worst
source-relative drift. No input duration, cadence, failure coverage, bound or
suite scheduling was changed.

The required native suite includes its existing UUID-service synthetic Keychain
adapter case with awaited cleanup; no installed app-owned credential item was
read or modified. Builds do not install or open apps. Actual system consent,
installed ATS and unchanged app/item behavior are not proven by these tests.

## Isolated final-source production resources

After the full gate, the existing #53 one-hour and three-hour frequent-state
production fixtures each ran once, sequentially in separate helper processes.
They used the same gated Release test binary and the unchanged full-duration
fixture, including independent decoding, stable-range readback, reopen, exact
snapshot hashing/replay and complete extraction with retained media/index files.

| Measurement                                    |              One hour |           Three hours |
| ---------------------------------------------- | --------------------: | --------------------: |
| Independently decoded frames                   |            57,600,000 |           172,800,000 |
| Permanent master bytes                         |           230,400,068 |           691,200,068 |
| Final source intervals                         |               450,890 |             1,352,690 |
| Exact retained snapshot bytes                  |            32,994,119 |            99,738,722 |
| Append + media/index sync + SQL progress       |              17.002 s |              53.536 s |
| Final publication + snapshot hash/replay       |              15.864 s |              55.159 s |
| Complete test duration                         |              34.432 s |             115.226 s |
| Proof-process peak RSS through full extraction |          50,806,784 B |          54,771,712 B |
| Preserved resource budget                      | 83,886,080 B (80 MiB) | 83,886,080 B (80 MiB) |

The final master SHA-256 values remain
`f1d291060037cc4a875ede38cc396eb832de31f3eb298441074d053ad4e65ff8`
(one hour) and
`e910146a638503d4f526b12d5b4a91b868fe5b5c5f12297f914529227e023c52`
(three hours). The isolated peaks compare with the prior #53 measurements of
54,198,272 B / 43,433,984 B. All are below the unchanged bound; this is not a
claim that every individual peak improves. The concurrent full-suite helper
reached 191,004,672 B across many tests and is not the isolated per-capture measure.

The gated Release `TrigoNativePackageTests` binary has SHA-256
`dede7678b8fcd4382fe0d4948e1dfd069d7693dec2f71461ea3349413109101e`.
The selected Xcode `swiftpm-testing-helper` has SHA-256
`da2601bc562f2e0dd0cd7e00e923aee763ce94bdbf3eddccdebf1a4b8d5d313d`.
Both hashes stayed unchanged through the full gate, the current-source build
inside local smoke and the isolated resource invocations. These identify local
synthetic test execution; a later signed installed build remains separate evidence.

## Timing comparison and reproduction

Measured on Apple M1 Pro / 16 GiB, macOS 26.6.2 (25G83), Xcode 26.6 (17F113),
Swift 6.3.3. The first check in this new worktree had no native build products;
locked setup ran first, and global download/SDK caches were not erased. No second
warm full-suite run was needed. These are local measurements, not GitHub cache
hit/miss or runner timings.

| Command phase               | #49 cold local | #49 warm local | #56 first local |
| --------------------------- | -------------: | -------------: | --------------: |
| Contracts Debug build tests |       17.259 s |        3.819 s |        19.858 s |
| Contracts Debug test        |        4.161 s |        4.111 s |         3.460 s |
| Native Release build tests  |       53.352 s |        2.436 s |        80.010 s |
| Native Release test         |       21.118 s |       17.851 s |       288.354 s |
| Trigo Dev Debug build       |       25.065 s |        6.542 s |        33.082 s |
| Trigo Debug build           |        5.083 s |        3.000 s |         8.247 s |
| Local smoke                 |        4.961 s |        3.487 s |        26.418 s |
| Complete `check:macos`      |       133.17 s |        43.21 s |        464.02 s |

The [#49 baseline](acceptance-49.md) had 95 native tests; this source has 169,
including full production resource/fault/concurrency acceptance and actual native
local transport. Current native internal test time was 286.012 s. Comparing the
totals as an identical workload or removing these later tests to reproduce #49's
duration would be incorrect. #49's measured CI cold/restored totals were 368/198 s;
new integration CI/cache/phase evidence belongs to the coordinator's published
source record. This worker did not run or claim a new CI result.

```sh
mise exec -- bun install --frozen-lockfile
TRIGO_TIMINGS_FILE=.local/setup.jsonl mise exec -- bun run macos:setup
mise exec -- bun run check:server
TRIGO_TIMINGS_FILE=.local/check.jsonl mise exec -- bun run check:macos
```

The isolated invocations reuse the #53 helper command after that successful
current-source build. Run each filter alone, once; keep the complete fixture:

```sh
taskDeveloper=$(xcode-select -p)
taskBundle="$PWD/apps/macos/.build/arm64-apple-macosx/release/TrigoNativePackageTests.xctest/Contents/MacOS/TrigoNativePackageTests"
# Then repeat this invocation with productionMasterThreeHourFrequentStateProof.
DYLD_FRAMEWORK_PATH="$taskDeveloper/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  "$taskDeveloper/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path "$taskBundle" --package-path "$PWD/apps/macos" \
  --filter productionMasterOneHourFrequentStateProof "$taskBundle" --testing-library swift-testing
```

Raw evidence is under `/tmp/trigo-epic-48/`: `56-install.log`, `56-setup.log`/
`56-setup.jsonl`, `56-focused.log`, `56-check-server-final.log`,
`56-check-macos-final.log`/`.jsonl`, `56-lock-repair.log`,
`56-isolated-{one,three}-hour.log`, and `56-isolated-resources.zsh`.
`56-pre-gate-source.json`, `56-post-gate-source.json`, `56-native-binary-source.json`,
`56-resource-proof.json` and `56-navigation-proof.json` record source, measured
binary, integrity and navigation checks. `56-final-source.json` and `56-handoff.md`
record the final commit and the acceptance-only post-gate difference.

## Remaining acceptance

#57 owns the final signed installed build and performed controlled capture,
recovery, local authenticated status, unchanged relaunch and supported rebuild
observations. The Allow/Always Allow dialog requester and cause remain unconfirmed.
The existing #55 controlled fixture and procedure remain its supported preparation;
this task does not launch/install an app, request consent, touch private data or
operate on installed Keychain items.

The handoff preserves #13's hosted master/Nova-3 compatibility gate, #32's
infrastructure recovery gate before first personal deployment, and #10's upload
while recording, post-call ASR/sync, full-receipt cleanup, transcript UI, compact
measured feedback, double-Left-Option/Input Monitoring and real-call acceptance.
No tracker/PR writes, push, main merge or deployment belong to this slice.
