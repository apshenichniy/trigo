# Native UI acceptance foundation

Implementation of #72 on the shared production desktop shell from #71. The
dedicated fixture executable uses production views, AppKit presentation,
`DesktopShell`, `RecordingCoordinator`, capture ingress and SQLite persistence.
It injects in-memory credential/status/login adapters and no-input capture
transport. The installed targets do not compile this fixture entry point.

## Core acceptance and first failures

The first complete core run passed three native UI scenarios on 2026-09-08:

- Background bootstrap; menu-bar Open Library; empty archive; foreground/Dock
  activation policy; close/reopen; Command-comma Settings; login switch and
  Settings tabs; terminate/relaunch with the retained isolated namespace.
- Menu Start; real recording coordinator; microphone mute acknowledgement;
  Finish; one durably saved call; panel hidden; background Quit.
- Denied capture access; Start disabled; Settings and diagnostics still usable;
  no call created.

The local run was
`.local/ui-runs/2026-09-08T20-46-27.946Z-a1cc998a`: three passed, zero failed,
skipped or expected failures; 88.283 seconds for the command, including a
4.905-second current-source build and 81.972-second test phase. It recorded dirty
source fingerprint `a097a85978ab90e3639a60cd990377a5961ece6b3c41627307bc8c23988bfdb6`
on base `bc74d958c32445b2964764dca51a71cf38e0df65` and input hash
`abe588e0d9de046b02bab1ab938777b7d3601e017a31cc2b8d14a004a2598cd6`. These are
iteration evidence, not a claim that subsequent source revisions were tested.
Final candidate checks and CI belong in the PR body.

Earlier runs remain failed evidence. The initial launch guard rejected XCTest's
dedicated container temp directory; it now accepts only that exact runner temp
root or the current user's normal temp directory. A subsequent test used the
wrong accessibility control type for the native login switch, then compared its
numeric value to a string. Actual accessibility snapshots identified both test
errors. All failures propagated through the command; an Xcode runner restart and
its later passing test did not turn a partial run into success.

The native runner needed no new OS consent during the performed fixture tests.
This says nothing about the installed app's capture/Input Monitoring grants.
Named screenshots cover only controlled fixture windows and require visual
review before sharing. Raw automatic recordings remain local and ignored.

## Evidence and extension seams

`bun run test:ui --suite shell` builds the current `Trigo UI` scheme, runs a serial
selection and checks the actual `.xcresult` totals. It fails on an empty selection,
missing/skipped tests, timeout, changed inputs or failed collection. The GUI lease
is per user, and each test has an explicit configuration/run ID and temporary
SQLite namespace. The fixture guards its exact bundle and storage location;
there is no installed-composition fallback.

The fixture configuration reserves fixed clock/time-zone inputs for the reader
catalog. The early suite uses the shared empty reader and real wall-clock capture
timing; it does not claim date grouping, transcript selection, measured levels,
fullscreen, real source focus or gesture coverage. #20, #45 and #58 extend these
same targets and #24 executes the full integrated matrix. This foundation does
not add the deferred export, manual Retry/Re-transcribe or Delete actions.

The separate [installed protocol](installed-capture-acceptance.md) establishes
signing, GUI automation, capture permissions, independent microphone stimulus,
source pinning, mute, interruption and real gesture evidence. Its promoted
selected-call collector has 22 disposable self-checks for admission, read bounds,
hash/index agreement, mute/silence, recovery prefixes and additive schema versions.
Those fabricated inputs validate the collector; actual installed capture remains
part of #24. `--require-measured-mute` cannot pass on an all-zero microphone track.

Review added executable guards for early preflight failures and missing/duplicate
required screenshots/input/state. A malformed previous cursor is rejected before
any media read. The GUI lease now uses a kernel `flock` on a stable descriptor,
through the pinned Bun runtime's macOS FFI; it never reclaims ownership by
unlinking a PID file. A controlled two-process probe established exclusion while
the owner lived and release after its death, even while its unrelated spawned
child remained alive. These changes preserve the earlier failed evidence and
require a final run on the reviewed candidate.
