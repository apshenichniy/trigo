# Native audio capture

Issue #15 provides a macOS 15+ native library, not the recording UI. The selected
profile is `trigo-call-wav-s16le-16khz-stereo-60s-v1`, loaded from the shared
Swift/TypeScript contract: stereo PCM s16le WAVE at 16 kHz, microphone channel 0,
application channel 1, independently decodable objects of at most 60 seconds,
and a three-hour explicit capture limit.

## Integration boundary for #16

The desktop entry point first creates `RecordingApplication`, which holds an
exclusive OS file lock for the lifetime of its variant/worktree namespace. Only
the admitted instance constructs a coordinator or starts connection recovery,
shortcut registration, permission checks or capture. A second installed/build
copy displays an actionable startup error without touching archive recovery.
The kernel releases ownership when the process exits, including after a crash.
The owner-only `application.lock` file stays in place; never delete it while an
instance is running, because a replacement inode would defeat exclusion. Separate
dev worktree namespaces remain independent.

`ScreenCaptureRecording` is a main-actor facade. From an explicit user action,
request permissions through `SystemCaptureSource.requestPermissions()`. Resolve
the chosen frontmost application window with `SystemCaptureSource.frontmost()`
before the panel takes focus, and pass that immutable source to `start(root:
archiveID:source:)`. An explicit application selection can supply the same source
snapshot. The root is the active variant's local archive directory, and the
archive identity comes from the existing connection/local archive owner.

The resolver rejects denied permissions, Trigo itself, and unresolved/non-regular
applications. The filter includes exactly the selected application, identified
by PID, bundle ID and launch time. It never falls back to a display-wide audio
source. All audio from that application can be included, including other windows
and browser tabs; this is not tab isolation.

Observe `phase`, `snapshot`, `onChange` and `onFailure`. `phase` distinguishes
starting, recording, stopping, cancellingStart and a retained `needsRecovery(callID:)`
state. Enable Start only when idle. A Stop during an outstanding OS start can
finish local media first, but remains cancellingStart until that exact late
transport is retired. A new recording cannot overlap the unfinished attempt.
Failed preparation, writer setup or finalization retains the allocated call ID
and cannot silently admit a replacement recording.
Use `retryRecovery()` after correcting the failure. On launch, enumerate local
calls and use `CaptureArchiveSession.recover(root:callID:)` for capture sessions
with unfinished publication; recovery never starts capture. Expose rejected
checkpoints as errors, not as an empty archive.

Direct archive-library callers can allocate a `CaptureArchiveSession`, retain it,
then call `prepare()`. Preparation is replay-safe at all three durable boundaries:
session metadata, initial canonical call and initial lifecycle. The convenience
`begin()` returns `CapturePreparationFailure.session` on a preparation failure.
Instance `recover()` also works after correcting a failure before the first write;
static recovery uses the durable session metadata after relaunch. Both finalize
a never-opened capture as zero-duration interrupted and never open a stream.

`setMicrophoneEnabled` acknowledges only after the serial audio queue applies
the policy. It does not change microphone controls in the calling application.
`stop()` is independent of current focus. Call `stop(reason: "application_termination")`
from the application's coordinated termination path before allowing quit. Sleep
and source-process loss are observed by the facade itself. The library contains
no global shortcuts or panels; those remain #16 responsibilities.

## Audio and interruption behavior

Two ScreenCaptureKit streams share the same pinned filter and monotonic host-clock
origin: one supplies `.audio`, the other `.microphone`. Independent stream identity
admission rejects foreign and replaced callbacks. Microphone decoding/device
failure retires only that stream, reports unavailable, and attempts to reacquire
the current default input without changing the retained mute policy. Failed stops
remain owned and block replacements until a confirmed retirement. Application
stream, shared timeline or media-write failures interrupt the recording.

The native PCM converter handles hardware sample rates and pulls only the frame
count requested by AVAudioConverter. Adjacent hardware packets retain the
converter's fractional output-frame phase: independently rounding every packet's
PTS would introduce periodic single-sample holes at rates such as 48 kHz with
512-frame callbacks. Continuity requires adjacent input PTS and placement within
one output frame of the common host clock. Real gaps, format/origin changes, or
drift outside that bound reset the converter and re-anchor to source PTS; this
also prevents filter history from leaking across a discontinuity. The timeline permits a
bounded two-second reorder window; a 500 ms timer flushes behind a 250 ms delivery
allowance. Missing samples are silence with unavailable intervals. Physical device
absence takes precedence over muted intervals while mute policy remains unchanged.

Microphone suppression happens before persistence. Policy changes clear pending
microphone samples and converter history. Muted and stale pre-unmute callbacks are
discarded before conversion, so suppressed speech cannot reappear through a
resampler tail. No `.screen` output or `SCRecordingOutput` is registered: no video
or screen samples enter the writer.

## Local media and recovery

Each call owns `media/`, `capture-session.json` and `capture-finalization.json`
beside its canonical call document. Media directories are owner-only. The writer
syncs PCM fragments of at most one second, then atomically publishes a checkpoint
with each fragment's length/hash and the durable source intervals. At 60 seconds
it atomically seals a canonical WAVE object before advancing the checkpoint and
removing the superseded raw spool. A crash between these steps retains a valid
prefix, not an assumed wall-clock duration.

Recovery checks object bounds, headers and hashes, then validates the contiguous
active-fragment prefix. Uncommitted bytes are ignored; corrupt fragments and later
tail are rejected. The measured controlled SIGKILL case loses one second, within
the two-second target. Recovery preserves media and never resumes a session.

Finalization stores its immutable intent before publishing the finalized call,
audio manifest and call reference through `LocalArchive`. Retrying after a crash
reuses the same object and manifest identities. The independent lifecycle store
records stopped/interrupted without claiming upload or transcription. Neither
successful finalization nor tests delete media on a presumed server receipt.

## Permissions and verification limits

Both app variants declare `NSScreenCaptureUsageDescription` and
`NSMicrophoneUsageDescription`; the build wrapper verifies the actual bundled
values. No Core Audio process-tap permission is declared because the implementation
does not use taps. See Apple's [ScreenCaptureKit overview](https://developer.apple.com/documentation/screencapturekit)
and [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).

Ordinary native tests require no TCC grant or actual recording source. They use
controlled PCM/CMSampleBuffers, independent AVAudioFile decoding, filesystem fault
injection, a SIGKILL child fixture, a three-hour writer fixture and a one-hour
48/44.1 kHz common-clock replay. These prove local production-library behavior, not
physical-device capture or real-call quality. The installed Trigo Dev/Chrome/mic
exercise, focus changes and actual TCC prompts remain the explicitly deferred #16
integration acceptance. No real call, private audio, upload or paid ASR is used.
