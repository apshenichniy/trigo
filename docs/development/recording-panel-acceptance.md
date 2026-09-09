# Compact recording panel and finalization acceptance

This implements [#45](https://github.com/apshenichniy/trigo/issues/45) under the
[#66 recording contract](https://github.com/apshenichniy/trigo/issues/66#issuecomment-5577008210)
and the immutable `desktop-ux-accepted-2026-09-08` prototype. The normal panel is
192 × 44 points, permanently dark, with microphone activity/control, elapsed
time, one application-audio scale, Finish and Hide. Source identity and the
application-wide capture warning remain in help/accessibility and menu status.

## Recorded activity and controls

`CaptureTimeline.flush` measures the latest appended half-second of the actual
interleaved PCM after stream admission, overlap rejection and microphone policy.
It includes samples only after the corresponding writer append succeeds. The
snapshot retains linear RMS for each independent channel; the panel maps that
measurement to its display range. This is an observation of recorded contribution,
not an additional durable-commit or remote-storage claim. No waveform history is
retained for display.

Muted/unavailable microphone contribution is zero. A control or availability
boundary excludes earlier microphone energy from subsequent display. Silence
leaves the icon neutral; unavailable input has an explicit glyph and reason.
During a pending microphone change, the last effective state stays visible,
duplicate toggles are disabled and Finish stays available. New recordings reset
the per-call microphone choice. Reduced motion disables measured pulsing.

## Independent finalization confirmations

Capture termination, local save and pending native Start are distinct facts.
New Start and safe Quit remain blocked until all required confirmations settle.
A late microphone replacement Start must retire its exact stream even when the
call was already saved. Local recovery can finish while native retirement still
needs retry; retained audio never implies that the native stream has stopped.

Starting exposes Cancel. Saving has no live timer/level controls. A fully settled
local save hides the panel and emits one brief acknowledgement without opening
the library or claiming upload/transcription completion. This also applies after
Retry stopping/saving. Failure remains reachable after Hide. Recovered calls
retain their committed duration, source and interruption reason for status
presentation; restoration does not fabricate a new live capture session.
New Start failures take precedence over historical restoration status while the
recovered calls remain available in Diagnostics. Live interruptions also preserve
their cause in the panel's accessible detail.

Finish freezes the capture clock before queued timer work resumes. A delayed
tick cannot commit beyond the requested end and then make finalization rewind
the timeline. Native stream retirement and durable save remain independent.

The native host uses a nonactivating floating window, accepts pointer actions
without becoming key/main, and exposes the floating-window accessibility subrole.
Position is retained in the app namespace and clamped to remaining displays.
Microphone loss leaves application audio running and emits one nonactivating
notice per availability transition, including when controls are hidden.

## Focused native evidence

The first late-microphone replacement test failed before the lifecycle fix:
Finish incorrectly admitted Start and Quit while a replacement Start was still
pending. `panel-late-microphone-red.log` retained the 77.339-second run from
`acec76f32c3aea79182bb4e5f09c1088ba384abc` plus the new test. Its build input identity
was `8d58e7e2b9c93e74ab11d91b2ab00567f3abfb0d4412bb008c54519994fa542c`.
A subsequent controlled-start test exposed a fixture's iteration-count wait;
its replacement waits for the actual native-start hold through a continuation.

Independent stop/save combinations, a held save, late Start and exact PCM-level
checks then passed eight selected tests in 72.061 seconds. The first panel
presentation pass covered 43 selected tests in 74.308 seconds.

Review found two additional observable recovery defects. Against `78a72fbe9`,
real coordinator/repository tests failed with eight expectations in 0.494 seconds
(52.488 seconds including build): successful stop/save recovery left a Ready strip,
and restart recovery omitted source, duration, reason and saved outcome.
`panel-recovery-presentation-red-compiled.log` retains that result. After the fixes,
50 selected tests, including existing microphone/capture/launch-recovery proofs,
passed in 67.275 seconds (`panel-native-review-corrections.log`). A separate review
correction preserves actual status titles for non-start notices such as capture
access setup. Compilation failures are retained separately and are not test results.

The first complete UI run at `6511f4571` exposed a Finish/queued-timer race.
`panel-final-regressions-red.log` reproduces it with the actual production timer:
hold the audio queue until a timer event is pending, enqueue mute and Finish,
then release the queue more than the reorder allowance after Finish. Before the
fix, the call ended as `interrupted` with `media_write_failed`. The same red run
also proves that three new Start failures were masked by a restored interruption.
Two tests failed with 18 expectations in 1.450 seconds (51.192 seconds including
build); input identity `501fe03aa7ea7df177ec9778c80b4ce69d11afc9cf205c0a1e1d7e58aed3dcfd`.
After the fixes, eight selected tests passed in 1.540 seconds (64.496 seconds
including build), including retained ingress/drain coverage, queued timer work,
normal Finish, live/restored interruption details and error precedence.
`panel-final-regressions-green.log` retains that result.

## Native UI evidence

The isolated UI executable uses the real coordinator, repository, PCM ingress,
writer and production panel. Only device/transport/permission adapters are fake.
The panel scenario delivers independent 440 Hz application and 880 Hz microphone
PCM. A bounded, sequential fixture control file changes signals, device presence
or explicit boundary faults; every Start/Cancel/mute/Finish/retry still uses the
actual native menu or panel. No live capture, owner credential, external server,
Input Monitoring request or hosted ASR is reachable through these adapters.

The independent focus app creates a deterministic native text window and reports
actual fullscreen enter/exit acknowledgements. Pointer events are anchored to
that already-foreground controlled window, because XCTest otherwise activates the
background accessory app before event synthesis. Tests check focus before typing
or any subsequent activation. Only explicit fixture-window images and bounded
fixture state/accessibility text are curated; automatic desktop recordings remain
ignored and are not acceptance exports.

Retained iteration results under `.local/ui-runs`:

| Run                                 | Result and purpose                                                                                                                                                                                                                                                                 |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `2026-09-08T22-28-54.727Z-ea5e7541` | First compact-panel pilot failed before Start; XCTest activated the background target during menu synthesis. Input hash `943e69ec10df46d66718e3c353d1bcc3ca7e8f273ae6478bdd7039a383669211`.                                                                                        |
| `2026-09-08T22-33-39.763Z-3e4ed557` | Foreground-anchored Start succeeded and captured the actual 192 × 44 strip. Later menu interaction failed because the panel was exposed as an interrupting AXDialog. Input hash `29f9d39d93d9bd5eca856dcc9fd02dc66428f13c2429dd3e8f06ded092246a42`.                                |
| `2026-09-08T22-35-29.420Z-5f47928b` | Correct floating-window role: Start, mute, Finish, saved call and background Quit passed in 85.295 seconds.                                                                                                                                                                        |
| `2026-09-08T22-45-35.772Z-f694ef04` | Independent measured signals, silence, effective mute, hidden microphone-loss notice and muted reattachment passed in 88.175 seconds.                                                                                                                                              |
| `2026-09-08T22-47-24.850Z-8965c742` | Five boundary/focus scenarios passed in 283.903 seconds: native fullscreen/drag/hide/reveal; pending mute and next-call reset; Cancel/late Start; held/failed save; failed Stop with saved audio.                                                                                  |
| `2026-09-08T23-01-09.777Z-1b5a9ce0` | First complete selection at `6511f4571`: seven passed, three failed, no skips. The stronger saved-call assertion exposed the queued-timer interruption. Two harness failures read a macOS text label instead of its value and tried to anchor a click to a closed Settings window. |

The first two runs used `cca2daa08` plus their recorded dirty inputs. The
`2026-09-08T22-45-35.772Z-f694ef04` and `2026-09-08T22-47-24.850Z-8965c742` pilots
used the same source fingerprint
`772f4605f25ab93cced7cb9931eed983d64ebdea1929701919da17bec4ccc52e`,
subsequently committed as `78a72fbe9`. Those runs preceded the review corrections.
The saved-call assertions now additionally require the panel to disappear after
recovery, and denied-permission UI includes the actual non-start status text.
The earlier pending-mute pilot did not require the panel to hide, so it does not
establish that normal finalization passed that stronger acceptance condition.

Run the current complete selection on the final committed candidate:

```sh
TRIGO_TIMINGS_FILE=.local/daily-use-panel-timings.jsonl bun run test:ui --suite all
```

The evidence contract requires all ten selected tests, their named attachments,
zero failures/skips and unchanged inputs. Final source/receipt IDs, screenshots,
timings, reviews and CI links belong in the PR body after this document is committed.
A focused result never substitutes for the complete current candidate.

## Installed and integrated acceptance

Signed installed checks use the [installed capture procedure](installed-capture-acceptance.md)
and the real ScreenCaptureKit pipeline. Fixture PCM does not establish physical
microphone stimulus, actual capture grants, hardware removal, display removal,
physical gesture input or installed Keychain/signing continuity. These performed
observations and any exact OS/physical boundary still pending are recorded with
the installed candidate and the integrated #24 handoff. Final Meet/Telegram use
remains #23. Cloud deployment and paid provider execution retain their separate
explicit authorization.

## Menu and fullscreen follow-up

The complete `a69f0b209` run `2026-09-08T23-17-37.371Z-fab50e27` passed eight
cases; fullscreen reveal and the legacy recording/menu case failed while opening
the menu. Pending mute/Finish and both corrected access/setup cases passed.
Fullscreen detection now accepts the macOS accessibility value as well as label.
The native host raises the panel only when showing it or responding to an explicit
Reveal, rather than on every measured-level update. This preserves explicit
reveal without continuously reordering windows during menu tracking.

A direct-event driver experiment (`2026-09-08T23-32-25.365Z-387053f4`) stopped at
its access preflight. No access request was made; that driver was removed and the
existing XCTest pointer route remains. The focused follow-up
`2026-09-08T23-38-47.148Z-023b98a4` passed both affected cases in 168.209 seconds
including build. The complete selection remains required on the committed result.
