# Recording gestures on macOS

Research for [Establish reliable Right Control and Fn recording gestures on macOS](https://github.com/apshenichniy/trigo/issues/65), checked on 2026-09-08.
Repository baseline: `8e65ee1b6f11421d3102b6ec75911720d5b8bf96`.
Trigo [targets macOS 15 or later](https://github.com/apshenichniy/trigo/blob/8e65ee1b6f11421d3102b6ec75911720d5b8bf96/apps/macos/project.yml#L2-L12);
the inspected local Apple SDK is macOS 26.5.
This is source research, not installed-app or physical-keyboard acceptance.

## Recommendation

Prefer **two complete taps of Right Control**, provided the target keyboard has
that key and delivers its distinct events. Keep **Control–Option–Command–R** and
visible menu/panel actions as fallbacks. Do not include Fn/Globe in the initial
gesture scope: it already has system assignments and its hardware delivery is
conditional. This recommendation follows the platform evidence below; it does
not establish that Right Control is unclaimed by every installed utility.

The gesture starts recording when idle. The owner's updated interaction has
no pause/resume; **Finish** is an explicit button. Revealing the existing panel
on a repeated gesture during recording remains a proposed product behavior,
not a decision established by this research.

## Current implementation

The current app registers `⌃⌥⌘R` with Carbon `RegisterEventHotKey` and
`kEventHotKeyExclusive`. It owns a cancellable registration and fences callbacks
from retired registrations. Registration failure leaves panel controls usable.
There is no modifier double-tap recognizer or Input Monitoring flow in this
code. These are implementation facts, not evidence that the future gesture
already works.
[Shortcut implementation](https://github.com/apshenichniy/trigo/blob/8e65ee1b6f11421d3102b6ec75911720d5b8bf96/apps/macos/Native/GlobalRecordingShortcut.swift#L18-L64),
[exclusive registration](https://github.com/apshenichniy/trigo/blob/8e65ee1b6f11421d3102b6ec75911720d5b8bf96/apps/macos/Native/GlobalRecordingShortcut.swift#L113-L131),
[tests](https://github.com/apshenichniy/trigo/blob/8e65ee1b6f11421d3102b6ec75911720d5b8bf96/apps/macos/Tests/RecordingShortcutTests.swift#L6-L52).

The existing callback selects the capture source before showing its
nonactivating panel. Preserve that ordering when changing the shortcut action.
[Application composition](https://github.com/apshenichniy/trigo/blob/8e65ee1b6f11421d3102b6ec75911720d5b8bf96/apps/macos/Sources/RecordingAppDelegate.swift#L18-L37).

## Platform findings

| Question | Evidence and implication |
| --- | --- |
| Can macOS distinguish Right Control? | Apple's SDK defines `kVK_Control = 0x3B` and `kVK_RightControl = 0x3E` among layout-independent keycodes. Use the changed key's identity with `flagsChanged` and `keyboardEventKeycode`; the aggregate Control flag alone cannot identify a side. Apple also publishes separate device-dependent left/right Control bits. These are API/source capabilities, not proof that every keyboard or remapper supplies them. [SDK evidence](#sdk-evidence), [Apple event flags](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDSystem/IOKit/hidsystem/IOLLEvent.h#L237-L261). |
| Is Fn/Globe observable? | The SDK defines `kVK_Function = 0x3F`. Apple's published keyboard driver dispatches that code for an Apple-vendor Function usage when the keyboard advertises Fn support. This shows a supported path, not universal Fn delivery: a key labelled Fn on an arbitrary keyboard is insufficient evidence. [SDK evidence](#sdk-evidence), [Apple keyboard source](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDKeyboard.cpp#L250-L254). |
| Is double Fn free of system conflicts? | No. Apple's current shortcut list assigns Fn–Fn to Character Viewer. Keyboard settings also offer input-source switching, emoji, double-press Dictation, or no action. Therefore choosing Fn would require checking the actual OS/settings combination; a passive listener cannot suppress those actions. [Mac shortcuts](https://support.apple.com/102650), [Keyboard settings](https://support.apple.com/guide/mac-help/keyboard-settings-kbdm162/mac). |
| Can a listener reserve the gesture? | No. A `listenOnly` event tap observes events without modifying or diverting them. A second app may react to the same taps. Trigo must preserve normal input; successfully creating its tap proves neither exclusive ownership nor absence of third-party conflict. [Apple event-tap options](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions). |
| Which permission applies? | Apple's WWDC guidance distinguishes Input Monitoring for passive listening from Accessibility for modifying/posting events. Use event-listening preflight and a user-initiated enable action. The SDK exposes `CGPreflightListenEventAccess` and `CGRequestListenEventAccess`; Apple also documents the IOHID listen-access path. Existing Accessibility authorization can already permit listening, so do not insist on a second permission just because an Input Monitoring row is absent. [Apple security session](https://developer.apple.com/videos/play/wwdc2019/701/), [Apple DTS clarification](https://developer.apple.com/forums/thread/828052), [SDK evidence](#sdk-evidence). |
| What happens during Secure Event Input? | Apple's technical note explicitly includes Core Graphics event taps among interceptors whose keyboard delivery is withheld while secure input is enabled. Treat the gesture as unavailable there and discard incomplete recognition state. Do not attempt to disable another process's secure input or claim a permission grant overcomes it. The note is archived; the current SDK still exposes the secure-input APIs. Exact behavior on supported systems remains an acceptance item. [Apple TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html), [SDK evidence](#sdk-evidence). |

Modifier remapping is a supported macOS setting. Consequently, a label or
keyboard layout name does not establish the delivered side identity. Do not
silently substitute Left Control, remap keys, or select Fn if Right Control is
unavailable. Use the existing fallback.
[Apple modifier-key settings](https://support.apple.com/guide/mac-help/change-the-behavior-of-the-modifier-keys-mchlp1011/mac).

## Recognition and ownership requirements

These are recommended engineering constraints, rather than Apple-prescribed
gesture semantics:

- Use a passive session event tap. Interpret two complete Right Control
  down/up cycles from a clean released state; act on the second release.
  Reject long holds, repeats and ambiguous/missing transitions. Keep timing
  constants explicit and test their boundaries; choose the final interval
  during implementation rather than presenting an unmeasured value as settled.
- Cancel a candidate on another key, another held modifier, a pointer button,
  drag or scroll. Left/Right Control overlap must not look like another tap;
  discard it and wait for a clean released baseline. Caps Lock's latched state
  should not be mistaken for a held chord.
- Do not depend on undocumented raw `CGEventFlags` bits as the only side
  detector. The SDK's public Control flag is device-independent and unspecified
  Core Graphics bits are reserved. Keep device-dependent evidence within the
  native adapter and reject ambiguous sequences.
- Reset on timeout, tap disablement, loss of authorization, secure input,
  sleep/session transition, keyboard change where observed, and registration
  retirement. Re-enabling a tap must never finish an old partial gesture.
  Keep the callback short; queue the product action outside it. Apple exposes
  tap-disabled notifications and an enable API.
  [Core Graphics events](https://developer.apple.com/documentation/coregraphics/cgevent).
- Preserve input without suppression or synthesized replacement events.
  Discard unrelated key details immediately; recognition does not require
  retaining typed text.
- Admit only one Trigo variant as the gesture owner. Passive taps do not
  provide the current Carbon registration's exclusivity; keep an explicit
  cross-process ownership mechanism and the existing retired-callback fence.
  This controls Trigo/Trigo Dev contention, not other utilities.

## Fallback and proof boundary

Keep the existing ordinary shortcut as a fallback without making passive-tap
authorization a prerequisite for visible controls. The eventual menu action
must preserve a valid intended capture source; opening Trigo must not silently
retarget recording to Trigo. A Carbon registration success is also not a promise
that the chord works in every secure-input or OS state. Keep explicit Finish
reachable through the recording panel/menu if gesture delivery is unavailable.

Autonomous verification can cover recognition traces, mixed modifiers, timing
boundaries, cancellation, adapter failures, permission-state presentation,
ownership races and retired callbacks. An installed signed build and target
keyboard still need acceptance for actual press/release delivery, permission
denial/revocation/relaunch, sleep/wake, Secure Event Input, normal Control
shortcuts and Control-click, Trigo/Trigo Dev contention, and coexistence with
the owner's other shortcut utility. Record keyboard model/connection, macOS
version, mappings and build identity with that evidence.

No physical keyboard events, event taps, permission requests, recordings,
system-setting changes or installed-app mutations were performed here. Synthetic
event tests would establish recognizer behavior, not physical delivery or TCC
acceptance. These limits do not block designing and implementing the feature;
keep unverified environment behavior explicit at the final app check.

## SDK evidence

Read from the Apple macOS **26.5 SDK**, selected by `xcrun --show-sdk-path`:

- `HIToolbox.framework/Headers/Events.h`, lines 263–280: layout-independent
  Control/Right Control/Function keycodes.
- `CoreGraphics.framework/Headers/CGEventTypes.h`, lines 75–141: aggregate
  modifier flags, `flagsChanged`, tap-disabled event types and reserved-bit
  notice; the same header defines `kCGKeyboardEventKeycode`.
- `CoreGraphics.framework/Headers/CGEvent.h`, lines 320–333 and 398–402:
  disabled-tap recovery and event-listening preflight/request APIs.
- `HIToolbox.framework/Headers/CarbonEventsCore.h`, secure-event-input API
  comments at lines 2971–3064: keyboard isolation and process-wide status query.

SDK declarations establish available interfaces. Apple open-source snapshots
above explain specific behavior but are not asserted to match the running
macOS kernel revision. Source inspection does not establish an installed result
on macOS 15, 26, or the owner's keyboard.
