# Double Left Control acceptance

Implementation of #58 against the Start-or-reveal seam from #71. Two complete
Left Control taps dispatch once, on the second release. Each press may last at
most 250 ms; the gap from the first release to the second press is at most 350 ms.
A late second press may begin a fresh pair. Held/duplicate/out-of-order edges and
intervening keys, modifiers, mouse buttons, drags or scroll cancel the candidate.
Pointer movement is not subscribed to and does not cancel it. Caps Lock being on
is deliberately treated as a non-neutral modifier state.

The decoder uses public `kVK_Control`/`kVK_RightControl` identities and the public
left/right device masks from the macOS SDK's `IOKit/hidsystem/IOLLEvent.h`; an
aggregate Control flag without the left-device identity is insufficient. The
adapter uses a passive session tap, main-run-loop delivery and returns each
original event unchanged. It retains only the current recognition phase and two
timestamps, without characters, event history or input logging. This follows the
[Apple DTS passive-listener guidance](https://developer.apple.com/forums/thread/724608).

## Availability and ownership

The gesture starts disabled in a new preference namespace. The General and
Diagnostics sections show its state and the ordinary Control-Option-Command-R
fallback. Only the explicit Enable action can request Input Monitoring; startup,
readiness polling, Check Again and recording attempts never prompt. Prior request
and verified-grant markers distinguish unconfigured, denied and revoked states.
The fixture injects an in-process denial and never calls TCC or installs a tap.

Permission loss, sleep/wake, login-session changes, Secure Input, disabled taps
and ownership changes retire the listener and reset its candidate. Each listener
and lifecycle subscription has a generation fence. The adapter checks live
availability on input and polls every 500 ms for changes without notifications;
the polling interval is not a claim that an unobserved transient OS state can be
reconstructed. Ordinary input and the existing operation remain untouched.

All installed variants use the same per-user application-support lock at
`io.github.apshenichniy.trigo.shared/recording-gesture.lock`, independently of their
archive, bundle or worktree. A stable `flock` descriptor excludes another Trigo
listener; close or process death releases it. The lock is never unlinked for a
PID-based takeover and cannot be a symlink or multiply linked file. This shares
the already tested kernel primitive with application-namespace ownership while
keeping their lock paths and ownership scopes distinct. It does not reserve the
gesture against another vendor's utility.

Both keyboard routes invoke the same synchronous shell intent. The shell selects
a new foreground source before showing Trigo, or immediately reveals the current
starting, recording, saving or recovery operation. It never queues an extra Start.
Finish remains explicit; the adapter does not alter menu source snapshots or
original-source Retry.

## Verification and retained failures

Deterministic native tests cover both sides, timing boundaries, duplicate/held
edges, all subscribed cancellation types, unchanged fabricated events, permission
loss, Secure Input, tap failure, lifecycle reset, stale callbacks, independent
fallback registration and owner transfer. Two controllers with separate
preferences also exercise the actual shared kernel lease. The existing
cross-process crash/replacement and symlink tests exercise the extracted primitive.

The first compiled trace run exposed a listener restart retaining its old sleep
flag: `gestureRestartDoesNotKeepOldSessionFlagsOrObservers` failed before the
restart/reset and subscription-fence correction. Its native build input identity
was `714ff6c615f8dc6ea80d2f0c8aa82c54357cfd16914c463570370a4b651b3a53` on
base `c5bf3713b`; the local log is `gesture-restart-red-compiled.log` in the
delivery evidence directory. An initial fabricated `CGEvent(source: nil)` was
also unsuitable for keyboard-field tests: the null event ignored its keycode.
Those tests now construct typed keyboard events and assert their actual identity.
The corrected iteration passed all 18 selected tests; final candidate checks
and expanded selections belong in the PR body.

The new UI scenario clicks Enable, observes an injected denial, checks the
reachable Settings actions, disables the gesture and uses the native menu to
start and finish a durably saved fixture call. Its first successful run was
`.local/ui-runs/2026-09-08T21-37-21.836Z-211eabdd`, one selected test, four required
attachments and 40.317 seconds. Named Settings screenshots were visually checked.
The earlier fixture build failure remains failed evidence in
`.local/ui-runs/2026-09-08T21-35-50.028Z-c0ba9d20`; its explicit closure annotation
resolved a compiler diagnostic failure. Neither run is physical-key or TCC proof.

## Installed integration

Use the [signed installed protocol](installed-capture-acceptance.md) in #24 with
the stable Dev path and the admitted controlled source. Enable the gesture from
General and record the actual Input Monitoring outcome before Start. Establish
the ordinary chord and menu on that same installed build, then test real left
and right Control, mixed shortcuts, held input, pointer movement and source/focus
pinning. Record physical delivery on the target keyboard separately from synthetic
event injection. Repeat around permission revocation, Secure Input and sleep/wake
when those OS interactions are available; verify the gesture can transfer between
two explicitly admitted Trigo copies without opening Personal archive data.

The installed record identifies any other utility responding to the same gesture.
No Accessibility request or input suppression is introduced by this listener.
The fixture's in-process shortcut adapter is explicitly marked in its evidence;
it does not prove Carbon registration, global event delivery or installed consent.
Unavoidable physical/OS observations remain identified in the #24 handoff.
