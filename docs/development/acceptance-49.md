# Issue #49: native check performance

This evidence covers [issue #49](https://github.com/apshenichniy/trigo/issues/49)
under the approved [recording foundation specification](https://github.com/apshenichniy/trigo/issues/48).
The implementation starts from `815d572b6`; native application and fixture sources
are unchanged by this ticket.

## Preserved verification

- All 95 native tests run in Release, including the complete one-hour common-clock
  fixture and three-hour media writer fixture. No filter, skip list, shortened
  duration, changed fixture, or relaxed assertion was introduced.
- The five Swift contract tests still run separately in Debug. SwiftPM does not
  discover a dependency package's test target when testing its consumer, so both
  package test boundaries remain necessary.
- Both `Trigo Dev` and `Trigo` still build in Debug with the existing identity and
  usage-description checks. Shared dependencies reuse the same DerivedData.
  These builds require no signing credentials and do not install or launch apps.
- Source inspection found no `#if DEBUG`, `assert`, `assertionFailure`, or
  optimization-configuration predicates in the native app, native tests, or
  contracts sources. There is no distinct current Debug-only execution branch
  omitted by the Release native suite. Debug contract tests and both Debug app
  builds retain that compile boundary. Future Debug-specific behavior must bring
  corresponding test coverage.
- Each `swift test --skip-build` follows a successful `swift build --build-tests`
  of the current package and configuration. The build explicitly enables testable
  imports, matching `swift test` in Release. Cache hits never skip this build.
  A failed build aborts before any cached test executable can run.
- The server checks, generated contract checks, frozen install, toolchain checks,
  tracked-lock guards, and local Worker/R2/fake-ASR smoke remain in the gate.
  The local smoke retains OS-enforced external network denial on macOS.

## Cache and dependency boundaries

CI uses two `native-v1` caches: SwiftPM dependency downloads and both package
scratch/build directories; and Xcode DerivedData including SourcePackages.
Each key includes the runner OS/architecture, actual selected Xcode/Swift/SDK/
XcodeGen identity, all four dependency locks, both Swift manifests, `mise.toml`,
the project specification, and affected build/toolchain wrappers. Configuration
names are explicit in the keys (`contracts-debug-native-release`, `debug`).
The full key also includes the commit; restore prefixes omit only that commit.
There is no fallback across a dependency, toolchain, platform, or configuration
change. A cache miss follows exactly the same checks after locked setup.

Generated projects and XcodeGen's generation cache are not restored across
worktrees. Generation and app identity checks therefore preserve the current
worktree namespace. The extra CI lock-restoration probe removes the generated
nested lock, runs the same project preparation code, and compares it with the
canonical lock; it no longer performs an unnecessary third app build.

`bun run macos:setup` fetches missing native dependencies using the committed
resolutions with version updates disabled. It restores the canonical app lock
and verifies that tracked locks did not change. It is separate from the existing
explicit version-update command, `macos:dependencies`. Subsequent native checks
require no dependency fetch; setup must run before checking a cold clone offline.
SwiftPM/Xcode retain their existing sandbox behavior. Wrapping SwiftPM in a second
macOS sandbox was rejected during validation because nested manifest sandboxing
fails; the implementation does not disable either tool's sandbox.

## Measurements

The local host is an Apple M1 Pro with 16 GiB RAM, macOS 26.6.2 (25G83), Xcode 26.6
(17F113), Swift 6.3.3, Swift Format 6.3.0, XcodeGen 2.46.0, Bun 1.3.13, and Node
24.14.1. Measurements are wall-clock seconds, collected on 2026-09-06 with
`TRIGO_TIMINGS_FILE` and `/usr/bin/time -p`. Build/test rows include the wrapper's
tool invocation overhead; Swift Testing's internal suite duration is reported
separately below.

Cold means no package compilation products after `swift package clean` for both
packages and no preexisting Xcode build products in this new worktree. Dependencies
were already resolved by setup. System SDK/module/download caches were not wiped;
this is not a pristine-machine benchmark. Warm means an immediate repeated setup
and complete check using the same worktree's products. These are local cache
reuse measurements, not GitHub cache restore/download measurements.

| Phase                       | Cold local | Warm local |
| --------------------------- | ---------: | ---------: |
| Swift format                |      0.671 |      0.660 |
| Contracts Debug build tests |     17.259 |      3.819 |
| Contracts Debug test        |      4.161 |      4.111 |
| Native Release build tests  |     53.352 |      2.436 |
| Native Release test         |     21.118 |     17.851 |
| Trigo Dev Debug build       |     25.065 |      6.542 |
| Trigo Debug build           |      5.083 |      3.000 |
| Local Worker smoke          |      4.961 |      3.487 |
| Complete `check:macos`      |     133.17 |      43.21 |

First worktree dependency setup took 22.870 s for contracts, 9.001 s for native,
and 15.626 s for Xcode; it is excluded from the cold check total. Existing global
download caches may assist setup. Both Xcode project generation calls during the
cold check took about 0.020 s each.

Repeated warm setup took 10.22 s overall (contracts 3.451 s, native 1.273 s,
Xcode 4.999 s). The warm check total is 89.96 s lower than the cold compilation
run on this host, about 68%; setup time is excluded from both check totals.

The cold Release native suite reported 95 tests passing in 19.153 s: the one-hour
fixture took 19.152 s with 0.0 ms source-relative drift, and the three-hour fixture
took 15.380 s. These fixtures execute concurrently; their times are not additive.
The separate Debug contract suite reported five passing tests in 2.338 s.
The warm run passed the same 95 native tests in 16.356 s, with the one-hour
fixture at 16.355 s and 0.0 ms drift, the three-hour fixture at 14.676 s, and all
five contract tests passing in 2.333 s.

The approved local baseline was approximately 181 s Debug versus 16 s Release
for the one-hour fixture. It motivated the configuration change; the numbers
above are the new actual measurements and do not assume identical machine load.

The verified pre-change GitHub baseline is
[run 34021920137](https://github.com/apshenichniy/trigo/actions/runs/34021920137/job/101455951020)
at source `36d381e2a`: macOS job 364 s, `check:macos` 330 s, and the extra
lock-restoration app rebuild 8 s. Its logs report contracts Debug build 41.37 s,
five contract tests 2.745 s, native Debug build 40.76 s, and 95 native tests
173.258 s (one-hour fixture 173.257 s, three-hour 14.594 s, 0.0 ms drift).

## Integrated GitHub Actions measurements

Both attempts of [run 34060187403](https://github.com/apshenichniy/trigo/actions/runs/34060187403)
passed on source `42e09ba688c3c5a09a8c7067961bc592281765ce` (implementation
`3e78a0e5cf403c3befc43d9e451d09200401eb1e`). The server gate also passed.
[Attempt 1](https://github.com/apshenichniy/trigo/actions/runs/34060187403/job/101559209192)
missed both native caches, fetched locked dependencies, and successfully saved
both caches. [Attempt 2](https://github.com/apshenichniy/trigo/actions/runs/34060187403/job/101560157420)
reran only the macOS job on the identical source and restored both exact keys.

| Runner phase                     | Cold caches |                  Restored caches |
| -------------------------------- | ----------: | -------------------------------: |
| SwiftPM cache restoration        |  1 s (miss) |                             30 s |
| DerivedData restoration          |  0 s (miss) |                             12 s |
| Locked native dependency setup   |        86 s |                             34 s |
| Complete `check:macos`           |       215 s |                             86 s |
| Native suite, internal test time |    28.189 s |                         19.687 s |
| Native cache publication         |        26 s | 0 s (exact keys already present) |
| Complete macOS job               |       368 s |                            198 s |

The restored SwiftPM archive was about 1154 MiB and DerivedData about 502 MiB.
Both runs built current sources before running all 95 native tests, passed all
five Debug contract tests and both Debug application builds, retained 0.0 ms
one-hour source-relative drift, and passed the network-denied local smoke.
The missing nested-lock repair and tracked-file diff gates passed in both runs.

The cold total is similar to the earlier 364 s accepted-main baseline. A fresh
pre-refactor [PR baseline](https://github.com/apshenichniy/trigo/actions/runs/34059126350/job/101556359284)
also passed its macOS job in 404 s, with 95 native tests taking 189.396 s.
Faster native tests do not make the first complete job proportionally faster:
optimized cold compilation, dependency setup and first cache publication remain
visible costs. With restored caches, the measured 198 s job is about 46% below
the 364 s accepted-main baseline and 46% below the new cold run. This is one
measured cold/restored pair, including cache transfer overhead, not a guaranteed
runner speedup or a local-to-runner comparison.

## Reproduction and remaining acceptance

From a new isolated checkout with the pinned tools installed:

```sh
mise exec -- bun install --frozen-lockfile
mise exec -- bun run doctor
TRIGO_TIMINGS_FILE=.local/setup-cold.jsonl mise exec -- bun run macos:setup
TRIGO_TIMINGS_FILE=.local/check-cold.jsonl /usr/bin/time -p mise exec -- bun run check:macos
TRIGO_TIMINGS_FILE=.local/setup-warm.jsonl mise exec -- bun run macos:setup
TRIGO_TIMINGS_FILE=.local/check-warm.jsonl /usr/bin/time -p mise exec -- bun run check:macos
mise exec -- bun run check:server
git diff --exit-code
```

Phase records contain the phase name, wall-clock seconds, and pass/fail result.
They append to the selected JSONL file; use a fresh file for each measurement.
CI also emits each phase in the GitHub job summary, including failures.

Focused regression tests cover lock/toolchain/platform/configuration invalidation,
missing canonical cache inputs, current-source builds before warm-cache test
execution, fail-fast build ordering, and timing/failure propagation. The existing
lock-restoration test still covers missing nested/canonical locks. Installed app,
Keychain, TCC, actual capture, and cloud/provider acceptance are outside this slice.

The live generator cache-hit probe restored a deleted nested lock and matched the
canonical lock without rebuilding an app. A temporary wrong-Xcode executable
caused the cache-identity command to exit nonzero without emitting a key. Both
successful full native runs left all tracked dependency locks, native sources,
and fixtures unchanged. `check:server` also passed; the final unit suite contains
142 tests and the Workers suite contains 17 tests.

Issue #49's implementation, deterministic checks and cold/restored-cache runner
comparison are verified. The later installed-app acceptance and remaining epic
work retain their separate requirements.
