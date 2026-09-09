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

## Native desktop UI acceptance

Run `bun run test:ui --suite shell` in an unlocked macOS GUI session. It builds
the dedicated `Trigo UI` scheme and runs the shared production shell, views and
recording coordinator through XCUITest. `--filter <regular expression>` selects
named tests and rejects an empty selection. `--suite all` currently includes the
same core scenarios, including injected gesture setup denial and the retained
menu fallback. Reader, measured-panel and further gesture tests extend this suite
as those components arrive.

The fixture has its own bundle identity, per-test temporary SQLite namespace,
in-memory credentials, synthetic source/permission/status adapters and no live
capture, HTTP, login registration or global shortcut. It requires a validated
configuration and has no installed-app fallback. A relaunch test retains only
its own namespace. Test teardown terminates the fixture and removes its temporary
store. Personal and Dev targets do not compile fixture sources.

Only one UI acceptance command may own the user's GUI session. Its lease and
the normal one-heavy-check rule prevent competing automated interactions. Keep
other windows away from the fixture during screenshots; a window screenshot
can include an occluding window. No UI test resets TCC or grants itself access.
An actual OS authentication prompt is an explicit environmental prerequisite.
The host coordinator selects an already enabled ABC or U.S. layout during the
test phase because XCTest character-key synthesis depends on the active input
source. `run.json` records the original/fixture identifiers and verified
restoration. A `finally` restores the original layout after success, failure or
test-process timeout. No layout is installed or enabled. If the host coordinator
itself is forcibly killed, its retained record identifies the original layout
for recovery. The isolated XCTest runner cannot access the host input-source API.

Each invocation writes `.local/ui-runs/<timestamp-id>/run.json`, build/test logs,
the `.xcresult`, actual summary and `evidence/index.json`. The index contains
hashes of explicitly named fixture-window screenshots and synthetic input/state
attachments. Automatic desktop recordings and diagnostic snapshots remain in
ignored local artifacts; review curated screenshots before sharing them. Never
commit the raw result bundle. Preserve a failed run's source/input identity and
exit status. Missing, skipped, timed-out or empty tests cannot pass this command.

UI acceptance is an explicit GUI gate, separate from the existing headless CI
component checks. The integrated daily-use handoff in #24 runs it after all
components are present. A fixture pass does not establish signing, physical
microphone input, OS consent, real key delivery or hosted ASR. Use the separate
[signed installed-capture procedure](installed-capture-acceptance.md) for those
boundaries.

## Timings and evidence

Set `TRIGO_TIMINGS_FILE` to an ignored JSONL path, for example
`.local/check-timings.jsonl`. Each record carries the command invocation, shared
run ID, source revision and dirty-content fingerprint, selected scope/suite or
variant, configuration, timestamps,
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

Bootstrap uses full checks regardless of the proposed selection. Component jobs
explicitly fail when planning fails, preserving the existing required statuses
during migration. Selected normal work remains cancellable. After `All
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
