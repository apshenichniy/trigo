# Verification

## Development and acceptance

Use `bun run check:quick --scope native` for ordinary native iteration and
`--scope server` for portable server iteration. The default `all` scope requires
macOS. Quick native checks run formatting, Swift contract conformance and the
fast native suite against a current Release build. They omit app builds,
contention and resource proofs. Server quick checks retain `check:server`.

Use `bun run test:native --suite fast|contention|resource|all` to select native
tests. `--filter <regular expression>` narrows that suite and fails when no test
matches. A current-source build always precedes discovery and execution. The
same Release products serve quick and full checks. New tests enter the fast
suite by default; the explicit slow-test classification must match discovery.

`bun run check:macos` retains native formatting, Swift contracts, every native
test, both Debug app builds, and the native/local Worker smoke. `bun run check`
also runs the full server checks. Resource proofs run in separate processes so
their memory measurements are attributable. Their logical duration and existing
correctness, two-second durability and 80-MiB resource bounds remain intact.

`bun run check:files` performs portable repository formatting. CI uses it for
documentation changes. `bun run check:macos:smoke` runs the native/local Worker
integration without the unrelated native suites or app builds; server and
infrastructure changes still need that cross-component coverage.

Coordinate one heavy local check at a time. Start with a focused failing probe,
then the affected suite, then full acceptance for a stable implementation. A
quick pass reports only its selected scope.

## Timings and evidence

Set `TRIGO_TIMINGS_FILE` to an ignored JSONL path, for example
`.local/check-timings.jsonl`. Each record carries the command invocation, shared
run ID, source revision and dirty-content fingerprint, configuration, timestamps,
duration, result and parent span. Nested command durations overlap their parent:
use the outer command for feedback latency, phase intervals for attribution, and
GitHub job intervals for runner minutes. Do not sum parent and child spans.

Tracked acceptance documents belong in the candidate before final CI. Record
the subsequent CI URL and results in the PR body; job summaries and artifacts
hold measurements. Historical acceptance documents remain evidence for their
recorded source, not a mutable log of every later run.

## CI selection and required checks

The workflow always starts. Its selection/formatting job reads the entire PR
diff from the merge base to the PR head, or the incoming `main` push range.
Renames include both old and new paths. Unknown paths, unavailable history and
unsupported events select both complete component checks. Consequently, a
documentation update inside a native PR continues to require native checks;
batch acceptance documents before the final run to avoid repeating it.

| Changed inputs                                               | Selected component checks                   |
| ------------------------------------------------------------ | ------------------------------------------- |
| Root README/AGENTS/CONTEXT or Markdown under `docs/` only    | Portable formatting and selector tests      |
| `apps/macos/`                                                | Full native checks                          |
| `apps/server/` or `infra/`                                   | Server checks and native/local Worker smoke |
| Contracts, scripts, dependencies, workflows or unknown paths | Both full component checks                  |

Selections combine across all changed paths. The always-running `All checks`
job validates selection/formatting and every assigned component result. Failed,
cancelled, missing and unexpectedly skipped work cannot satisfy it. Selection
and timing artifacts are kept for 14 days; CI run logs retain test output.

Bootstrap uses full checks regardless of the proposed selection. After `All
checks` succeeds on the migration PR, add it to the existing required
`Server checks` and `macOS checks`, preserving their GitHub App restriction and
strict up-to-date policy. Then set the repository Actions variable
`TRIGO_SELECTIVE_CHECKS` to `true`. The existing component status names remain;
intentional job skips are accepted only when `All checks` validates the plan.
Clearing that variable restores full component checks for subsequent runs.

## Native caches and build reuse

Downloaded SwiftPM dependencies have an identity based on Swift package locks,
manifests, platform and toolchain. Build intermediates and DerivedData use the
broader build identity and retain current-source compilation checks. Unrelated
Bun or wrapper edits therefore preserve downloaded Swift dependencies. Measure
restore/save time as well as compilation before retaining larger cache archives.

Full native checks build current tests once and pass a receipt to their local
Worker smoke. The receiving process checks the shared invocation, current native
inputs, build environment, toolchain and bundle contents. Standalone smoke or an
invalid receipt performs its own current-source build. Its test process retains
the external-network sandbox and the explicitly selected Xcode.

App builds also record validated inputs and bundle contents. A subsequent
`macos:install` or `macos:run` may reuse that bundle when the variant, signing
settings, worktree, inputs, toolchain and environment match. Identity, signature,
installation and replacement checks still run. `macos:build` always asks Xcode
to build current sources and refreshes the receipt. Changed/missing artifacts,
changed inputs or external compiler overrides cause a fresh build. A failed
fresh build removes the previous success receipt.

Receipts live under ignored `.local/build-receipts/` and contain hashes, not
environment values or credentials. Writable build products and receipts remain
local to their checkout; CI caches are acceleration inputs rather than proof
that the current sources have passed.
