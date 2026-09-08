# Recording controls

The desktop shell from [#71](https://github.com/apshenichniy/trigo/issues/71)
hosts the existing local recording services in a persistent menu-bar application.
`DesktopComposition` retains `RecordingApplication`, its instance lease and the
coordinator for the application lifetime. Restoring the connection and recovering
local work do not depend on opening a window. Closing the library, Settings or
the nonactivating recording panel does not end capture.

The [recording/window decision](https://github.com/apshenichniy/trigo/issues/66#issuecomment-5577008210)
defines the current behavior. The [shell acceptance handoff](acceptance-71.md)
documents the composition, launch/window policy and fixture route for #72.

## Start and finish

The implemented global shortcut is **Control–Option–Command–R**. Before first
pairing, recording requires archive setup in **Settings → Connection**. Once
bound, local recording remains eligible while remote health is checking,
unavailable, unauthorized or incompatible. Server operations remain separately
blocked. The retained binding supplies the archive ID; the app namespace supplies
the local archive root.

Start checks current OS readiness. Application readiness code makes explicit
authorization requests only through Enable actions. Invoking ScreenCaptureKit
may independently display macOS-controlled consent/reminder UI even when
CoreGraphics preflight reports granted access. Before a call, use **Settings →
Diagnostics → Capture readiness** to enable screen/system-audio and microphone
access separately. Connection settings retain distinct credential-failure and
saved-connection retry guidance.

After granting access, focus the target application and invoke the shortcut or
**Start Recording** in the Trigo status menu. Keyboard Start snapshots the
frontmost application synchronously. The menu snapshots it when the menu opens,
before presentation can change focus. Validation keeps that selected application
instance; it does not resolve another source after asynchronous work begins.
If Trigo is frontmost or no eligible source exists, the controls explain how to
focus the intended application and invoke Start again. No display-wide or
unrelated background source is selected. Application audio can include other
windows and browser tabs of the selected application.

During Start, recording or finalization, the shortcut reveals the existing
controls. Repeated Start is not queued for a later call. Use **Cancel Start**
while starting, or **Finish** in the panel / **Finish Recording** in the status
menu during capture. Hiding the panel changes only its visibility; the shortcut
or **Show Recording Controls** in the status menu reveals it again. An explicit
**Retry This Source** after a start failure retains only the still-valid selected
application instance.

The UI acknowledges Recording only after capture does and remains non-idle until
pending starts and native streams retire. After successful finishing, the shell
hides the controls. Failures surface the recovery presentation and remain
reachable from the status menu and Diagnostics.

## Safe Quit

The status menu's **Quit** and **Command-Q** use the same guarded route. While
starting or recording, Trigo asks for **Finish and quit** or **Keep Trigo open**.
If finalization is already pending, Quit waits without another confirmation.
New shell Start commands are fenced while Quit is pending. The existing
termination authority handles `application_termination`, pending Start, native
capture retirement and local recovery. Failed retirement/finalization keeps the
app open and reveals recovery. Repeated Quit shares the pending request.

The shell currently presents conservative finishing/recovery text from that
safety authority. Independent capture-retirement and local-save facts and richer
acknowledgements belong to #45; a combined control phase is not proof of both.

## Microphone and truthful status

Every new call starts with microphone recording enabled. The microphone action's
icon and accessibility label change after the awaited capture operation
acknowledges the change. A second toggle while one is pending is ignored. Device
unavailable is a separate state from muted; application audio continues while
Trigo retries the default input when permission allows it. Revoked microphone
permission retires only its stream and prevents repeated starts until access
returns; loss of screen access interrupts the call. Trigo mute is independent
of the calling application's mute. The capture engine suppresses microphone
frames before persistence and preserves application audio and timeline alignment.

Microphone availability is published only after that exact native stream
acknowledges Start and still belongs to the active capture. A failed microphone
Start leaves application capture running with the microphone unavailable;
pre-acknowledgement microphone samples are suppressed.

The current panel shows the pinned application, elapsed duration, control phase,
microphone recording action and actionable errors. The source window title is
available in the source help and Diagnostics. The UI does not claim audible
speech from stream state and shows no synthetic activity meters. The measured
compact panel and independent microphone/application activity remain #45 work.

## Local recovery

After restoring the retained archive binding, recovery pages the namespace SQLite
repository for admitted recording sessions. It validates direct call/media paths
and their retained archive, call and root identity before reconciling the external
master. Linked entries, foreign identities and corrupt committed evidence are
rejected visibly. Discovery does not recurse into unrelated directories, delete
media or resume capture.

Incomplete final publication is recovered idempotently. Already finalized calls
do not count as newly recovered calls on later launches. Bytes without a complete
integrity record may be discarded. A terminal complete-sized torn record is also
discardable only above the independently matched SQL witness, with at most one
append of unindexed PCM. Corruption of witnessed media, an index record at/below
the witness, a nonterminal record or a missing witness rejects recovery while
retaining evidence. Known persisted stop reasons are shown without inferring new
causes. Failures block new recording until corrected and retried. This is a
recovery surface, not an archive browser or deletion interface.

The local retry action is offered only for pending capture recovery or failed
call recovery. Connection metadata recovery instead shows the connection issue
in **Settings → Connection**, where the saved connection can be retried.

## Accessibility contract

The installed-app coordinator can use these stable identifiers. The complete
shell/window/login/fixture handoff is in [acceptance-71.md](acceptance-71.md).

| Surface                                   | Identifiers                                                                                                  |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Status / recording summary                | `trigo-status-item`, `menu-recording-status`                                                                 |
| Menu Start / reveal / Finish / microphone | `menu-start-recording`, `menu-show-recording`, `menu-finish-recording`, `menu-microphone`                    |
| Panel / phase / source / elapsed          | `recording-window`, `recording-panel`, `recording-state`, `recording-source`, `recording-elapsed`            |
| Panel actions                             | `recording-hide`, `recording-cancel-start`, `recording-finish`, `microphone-toggle`, `recording-retry-start` |
| Panel error / recovery / Settings         | `recording-error`, `recording-recovery`, `recording-open-settings`                                           |
| Settings / shortcut readiness             | `settings-diagnostics`, `shortcut-readiness`, `shortcut-retry`                                               |
| Diagnostics recovery / connection         | `diagnostics-recording-state`, `diagnostics-retry-recovery`, `diagnostics-open-connection`                   |
| Connection                                | `server-url`, `owner-token`, `connect-button`, `connection-status`, `archive-id`, `retry-connection-button`  |
| Quit confirmation                         | `quit-finish-and-quit`, `quit-keep-open`                                                                     |

## Verification boundary

Deterministic tests exercise the real coordinator, connection, capture engine,
local media writer and archive with OS/network adapters. They do not request TCC,
open actual capture streams or use physical microphone/network inputs. The shell
adds tested command/window routing and an explicitly isolated fixture composition.
Both Trigo Dev and Trigo builds preserve their existing identities and privacy
keys.

#72 owns the launchable UI fixture, automated window/menu scenarios and signed
installed protocol. Actual focus, Spaces/fullscreen, login registration, physical
shortcut input and capture hardware need that separate evidence. Earlier #57
acceptance remains evidence for its recorded source. Fixture results cannot
substitute for installed checks or owner-operated calls.

The future double **Left Control** recognizer and Input Monitoring behavior belong
to #58. It should dispatch to the same Start-or-reveal command; the fallback chord
and visible controls remain available. #45 owns measured recording feedback,
#20/#19 the retained reader/repository integration, and #17/#18 background
upload/ASR. This shell slice does not complete those downstream product features.
