# Desktop shell acceptance and automation handoff

This change implements [#71](https://github.com/apshenichniy/trigo/issues/71)
against main `8e65ee1b6f11421d3102b6ec75911720d5b8bf96`. The completion boundary
is a tested, reviewable production-shell PR. It is not completion of the daily-call
archive or installed desktop acceptance. The PR records the final candidate SHA,
full check results, timings and CI run URLs after this document is committed.

## Accepted contract

- [Recording/window contract](https://github.com/apshenichniy/trigo/issues/66#issuecomment-5577008210).
- [Visual baseline and retention](https://github.com/apshenichniy/trigo/issues/67#issuecomment-5583747807).
- [Reading defaults](https://github.com/apshenichniy/trigo/issues/68#issuecomment-5583749276).
- [Implementation ownership/order](https://github.com/apshenichniy/trigo/issues/70#issuecomment-5583897958).
- [Agent-run acceptance route](https://github.com/apshenichniy/trigo/issues/69#issuecomment-5576810189).

The retained `desktop-ux-accepted-2026-09-08` tag and
`codex/prototype-desktop-library` branch are unchanged. No sample service or
immediate workbench Quit has been imported into production.

## Composition and lifetime

`Sources/App.swift` creates `DesktopAppDelegate.installed()` and runs AppKit.
The `TrigoDesktop` SwiftPM product contains the shared native presentation;
`TrigoNative` contains the app-lifetime services and tested shell decisions.
Neither a SwiftUI scene nor a view task owns bootstrap.

`DesktopComposition` retains `RecordingApplication` and its existing instance
lease. `DesktopShell.bootstrap()` retains one restore task. The saved local
binding and recovery path remain usable before the remote health request finishes.
Closing the library, settings or recording presentation cannot cancel this work.
Duplicate-instance and unsafe-store startup failures retain their existing
messages and expose no recording or shortcut service in the rejected copy.

The persistent status item routes menu/keyboard actions to
`DesktopShell.startOrReveal(from:)`. Menu opening snapshots the source
synchronously; selection is not repeated after presentation or an asynchronous
boundary. A busy intent reveals the existing operation and is never replayed as
a Start after completion. `RecordingCoordinator.startSelectedSource(_:)` admits
one attempt synchronously and retains the existing native capture protections.
Explicit Retry retains the selected process identity; an invalid fresh Start
clears an earlier source instead of offering an unrelated retry.

`DesktopLibraryLifecycle` switches to regular activation before creating a
library window. Reopen reveals and deminiaturizes that same window. Only its
actual close returns to accessory activation; minimization, fullscreen, settings
and recording-panel visibility do not change the ownership rule. Window frames
and SwiftUI preferences use the selected namespace. Native state restoration
does not automatically recreate these windows on a background launch.

Launch at login uses `SMAppService.mainApp`. Initialization only reads status;
registration requires the explicit toggle and never happens by default. Login
and service Apple events, nondefault restoration and `--background` select
background startup. Finder/Spotlight reopen reveals the library. No launch starts
or resumes capture. These choices use the public
[login service](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
and [login launch marker](https://developer.apple.com/documentation/coreservices/1556410-launch_apple_event_constants/keyaelaunchedasloginitem),
with the selected Xcode SDK supplying the AppKit launch notification key.

## Settings and safe Quit

General exposes the currently implemented fallback shortcut and opt-in login
registration. Connection retains validated same-archive replacement, token
clearing, saved-connection retry and the existing connection error/recovery
messages. Diagnostics holds permission actions, shortcut readiness, recording
recovery and server pipeline facts. The library contains no endpoint/token form
or pipeline controls.

Menu Quit and Command-Q use `DesktopShell.requestQuit`. Starting/recording asks
for **Finish and quit** or **Keep Trigo open**. A pending finalization waits without
another confirmation. Deferred exit requires the existing
`RecordingCoordinator.prepareForTermination()` result, including late Start,
capture retirement, local completion and outstanding recovery. Failure cancels
Quit and reveals the recovery presentation. Repeated Quit shares the pending
request. Idle immediate Quit also fences new shell Start commands.

`DesktopQuitRequirement` is the explicit presentation boundary for #45. The
current adapter uses the existing safe termination primitive and conservative
generic finishing/recovery text; it does not infer separate stop/save success
from the current combined capture phase. #45 supplies those richer independent
facts and the measured compact panel. The shell's basic nonactivating controls
remain functional in this PR.

## Explicit fixture route for #72

The production entry accepts only the exact Dev and Personal bundle IDs.
`AppVariant.installed`, `AppNamespace.installed` and the installed composition
reject unknown or fixture bundles before selecting credentials. Installed
`ServerConnection.live` additionally rejects fixture namespaces and a mismatched
variant before constructing a credential adapter.

#72 should create a dedicated executable/target using the same `TrigoDesktop`
product and a separate fixture entry point. Its actual bundle ID must match
`io.github.apshenichniy.trigo.fixture.<name>`. The public factory requires that
identity, a fresh run ID, a disposable support root and explicit service adapters:

```swift
let composition = try DesktopComposition(
  fixtureBundleIdentifier: fixtureBundleID,
  runID: runID,
  support: temporaryRoot,
  makeServices: { namespace in fixtures.makeServices(namespace: namespace) }
)
let delegate = try DesktopAppDelegate(
  fixture: composition,
  loginService: fixtures.login,
  reader: .empty
)
let application = NSApplication.shared
application.delegate = delegate
withExtendedLifetime(delegate) { application.run() }
```

The snippet identifies the API; `fixtures` and argument parsing belong to #72.
The fixture presentation initializer verifies the actual bundle identity too.
It never registers the live global shortcut or selects the system login service.
`DesktopRecordingServices` requires every recording, connection/repository,
readiness and termination action, with no default live implementation. Its
`DesktopRecordingState` and connection/source value types are public. The
committed fixture helper imports the public API without `@testable`.

Each fixture namespace has its own archive, journal, connection, preferences and
credential-service names. Its instance lease is acquired before adapter creation.
Use the supplied namespace for seeded repository state; never pass installed
paths or credentials. A second fixture with the same run identity is rejected
before its adapters execute. The UI fixture route itself does not access Keychain,
TCC, capture hardware or the network. Existing lower-level connection tests may
still exercise their own disposable Keychain service.

`DesktopReader(content:)` permits a seeded reader in the existing library host.
The production default is an honest unavailable reader placeholder, since this
slice does not enumerate the retained archive. It never interprets unavailable
reader data as an empty archive. `.empty` is available when an injected reader
actually establishes an empty corpus. #20 should retain its reader model across
view creation so close/reopen preserves selection.

Stable accessibility identifiers include:

| Surface         | Identifiers                                                                                                                                                                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Status/menu     | `trigo-status-item`, `menu-recording-status`, `menu-start-recording`, `menu-show-recording`, `menu-finish-recording`, `menu-microphone`, `menu-retry-recovery`, `menu-open-library`, `menu-settings`, `menu-quit`                                                    |
| Library         | `library-window`, `library-host`, `library-sidebar`, `library-detail`, `library-start-recording`, `library-open-settings`                                                                                                                                            |
| Settings        | `settings-window`, `settings-section`, `settings-general-tab`, `settings-connection-tab`, `settings-diagnostics-tab`, `settings-general`, `settings-connection`, `settings-diagnostics`                                                                              |
| Connection      | `server-url`, `owner-token`, `connect-button`, `retry-connection-button`, `connection-status`, `archive-id`                                                                                                                                                          |
| Login/readiness | `launch-at-login`, `login-approval-required`, `login-error`, `open-login-settings`, `screen-audio-readiness`, `microphone-authorization`, `enable-screen-audio`, `enable-microphone`, `refresh-capture-readiness`, `shortcut-readiness`                              |
| Recording/Quit  | `recording-window`, `recording-panel`, `recording-state`, `recording-source`, `recording-hide`, `recording-cancel-start`, `recording-finish`, `microphone-toggle`, `recording-recovery`, `quit-finish-and-quit`, `quit-keep-open`, `startup-failure`, `startup-quit` |

#72 owns the XCUITest target, scenario control, evidence collector and signed
installed protocol. Its early smoke should cover background launch, one status
item, library reopen/minimize/fullscreen/close, settings without Dock presence,
source-before-menu ordering, nonactivating recording presentation, and both Quit
choices including held/failing safety acknowledgements. Native menu/window,
Spaces/fullscreen, real login registration and actual focus behavior still need
that executable UI/installed evidence; tested routing and configured AppKit flags
are not a substitute.

## Verification and remaining integration

`DesktopShellTests` and `DesktopIsolationTests` cover bootstrap once, explicit and
background launch, source ordering, repeated/busy intents, window policy routing,
settings independence, login opt-in/acknowledgement/failure, Quit confirmation,
waiting/recovery and fixture isolation. Existing source/connection/capture tests
continue to cover same-archive replacement, offline recording, credential errors,
duplicate instances and native late-Start retirement. Historical toggle tests
now assert Start-or-reveal and use explicit Finish/Cancel.

Focused development used:

```sh
bun run test:native --suite fast --filter 'desktop|repeatedShortcut|savedBindingRecords|terminationWaits|secondAppCannot'
bun run check:quick --scope native
```

For the stable candidate, run `bun run check:files` and `bun run check:macos`.
The latter includes all native suites/resource proofs, shared Swift contracts,
both production-variant Debug builds and the native/local Worker smoke. Preserve
timings with `TRIGO_TIMINGS_FILE` and publish exact run outcomes in the PR. The
affected CI selection is full macOS checks plus the always-running selection and
All checks gates; this change does not alter server behavior or shared tooling.

Remaining owners:

- **#72:** launchable isolated UI automation and signed installed evidence.
- **#45:** measured compact panel, richer capture retirement/local-save facts,
  independent activity/microphone presentation and final stop/save acknowledgements.
- **#58:** passive double Left Control recognition and physical-input acceptance;
  dispatch through `DesktopShell.startOrReveal(from: .keyboard)`.
- **#20/#19:** retained call reader and repository/import/annotation integration
  through the reader/service boundary; #73 owns playback services.
- **#17/#18:** application-lifetime upload/ASR work. Attach to the restored bound
  archive independently of windows; no hosted work was added here.
- **#24/#23:** integrated runnable delivery followed by owner-operated real calls.

No app installation, permission reset, personal credential access, real owner
call, cloud deployment or paid ASR request is claimed by this shell acceptance.
#71 stays open until its normal PR merge/closure lifecycle.
