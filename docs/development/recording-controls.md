# Recording controls

Issue #16 adds the minimal runnable local-capture controls on top of #14, #15
and #31. The app composes one main-actor `RecordingCoordinator`, one exclusive
global shortcut registration, the existing archive connection form, and a
nonactivating floating `NSPanel`. Closing the panel does not end capture; use
the shortcut or Window → Show Recording Controls to reopen it.

## Start and stop

The global shortcut is **Control–Option–Command–R**. Before first pairing,
recording requires archive setup. Once bound, local recording remains eligible
while remote health is checking, unavailable, unauthorized or incompatible.
Server operations remain separately blocked. The retained binding supplies the
archive ID; the app namespace supplies the local archive root.

When either capture permission is missing, an explicit Start/shortcut action
only requests permissions. Even a successful grant does not select a source or
record: focus the target and press the shortcut again. With permissions already
granted, an idle shortcut snapshots the frontmost eligible application before
asynchronous capture validation. The application instance and selected window
remain pinned. Start in the panel only reuses a still-valid prior pin; it never
selects Trigo or falls back to display-wide recording. Application audio can
include other windows and browser tabs of the selected application.

During Start/Recording, the same shortcut or Stop cancels/stops that call,
regardless of current focus. The UI acknowledges Recording only after capture
does, and remains non-idle until pending starts and native streams retire.
Quit awaits stop with `application_termination`, pending Start and local recovery;
failed native retirement/finalization keeps the app open for recovery.

## Microphone and truthful status

Every new call starts with microphone recording enabled. The persistent on/off
text and icon change only after the awaited capture operation acknowledges the
change. A second toggle while one is pending is ignored. Device unavailable is
a separate state from muted; application audio continues while Trigo retries
the default input. Trigo mute is independent of the calling application's mute.
The #15 capture engine suppresses microphone frames before persistence and
preserves application audio and timeline alignment.

Microphone availability is published only after that exact native stream
acknowledges Start and still belongs to the active capture. The initial control
state remains “Microphone: starting” while acknowledgement is pending. A failed
microphone Start leaves application capture running with the microphone
unavailable; pre-acknowledgement microphone samples are suppressed.

The panel shows the pinned source/window, elapsed duration, capture phase,
application capture state, microphone device/state and actionable errors.
“Capturing” describes the stream state, not evidence of audible speech. Audio
levels and activity are explicitly not measured; no synthetic activity meters
are shown. Under the corrected runnable-capture boundary in #10/#16, full
per-track recorded-activity UI is follow-up work, not a blocker for this slice.

## Local recovery

After restoring the retained archive binding, recovery discovers only direct
call directories containing `capture-session.json`. Before invoking recovery it
validates the canonical directory call ID, matching metadata call ID, exact
standardized namespace root and retained archive ID. Linked entries/inputs,
foreign identities and corrupt metadata are rejected visibly. Discovery does
not recurse into unrelated directories, delete files or resume capture.

Incomplete publication/lifecycle state is recovered idempotently. Already
finalized calls do not count as newly recovered calls on later launches. A
rejected corrupt media tail is distinguished from full recovery: only the
verified prefix is accepted and the original retained files remain available.
Known persisted interruption reasons are shown without inferring new causes.
Failures block new recording until corrected and retried. This is a recovery
surface, not an archive browser or deletion interface.

The local retry action is offered only for pending capture recovery or failed
call recovery. Connection metadata recovery instead shows the connection issue
and links to Archive connection, where the saved connection can be retried.

## Accessibility contract

The installed-app coordinator can use these stable identifiers without a
test-only interface:

| Surface                            | Identifier                                                             |
| ---------------------------------- | ---------------------------------------------------------------------- |
| Panel / phase                      | `recording-panel`, `recording-state`                                   |
| Source / elapsed                   | `recording-source`, `recording-elapsed`                                |
| Start / Stop                       | `recording-start`, `recording-stop`                                    |
| Shortcut / conflict / retry        | `recording-shortcut`, `shortcut-error`, `shortcut-retry`               |
| Application capture                | `application-audio-state`                                              |
| Microphone policy / state / device | `microphone-recording-policy`, `microphone-state`, `microphone-device` |
| Microphone action                  | `microphone-toggle`                                                    |
| General error                      | `recording-error`                                                      |
| Recovery action / summary          | `recording-recovery`, `recording-recovery-summary`                     |
| Recovery error / warning rows      | `recording-recovery-error`, `recording-recovery-warning`               |
| Recovered interruption cause       | `recording-recovery-cause`                                             |
| Connection action                  | `recording-connection`                                                 |

Connection recovery in the panel uses `recording-connection-error`.
The existing connection identifiers remain: `server-url`, `owner-token`,
`connect-button`, `connection-status`, `archive-id`, `retry-connection-button`.

## Verification boundary

Deterministic tests exercise the real coordinator, connection, capture engine,
local media writer and archive with OS/network adapters. They do not request TCC,
open actual capture streams or use physical microphone/network inputs. Both
Trigo Dev and Trigo builds preserve the existing identities and privacy keys.

The integration coordinator owns installed-app/Chrome acceptance, actual global
shortcut and nonactivating-panel button interaction, physical known-phrase
mute/silence inspection, device loss/return and retained-media checks. No real
call, personal deployment, upload/ASR/transcript/archive product UI or public
release is included in this slice. A passing automated check does not substitute
for those installed-app gates.
