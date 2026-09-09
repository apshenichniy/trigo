# Native audio capture

The macOS 15+ capture library records one permanent master per call. The selected
shared Swift/TypeScript profile is `caf-lpcm-s16le-16000-stereo-v1`: interleaved
PCM s16le CAF at 16 kHz, microphone channel 0, application channel 1, and an
explicit three-hour capture limit. The independent WAVE profile remains the
hosted-provider probe input; it does not define permanent capture files.

## Desktop integration

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
enable one permission through `SystemCaptureSource.requestPermission(_:)`;
Start only checks readiness. Resolve
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
calls and use `CaptureArchiveSession.recoverCompletion()` for admitted sessions
with unfinished publication; recovery never starts capture. Expose rejected
media evidence as errors, not as an empty archive. Production stop/recovery returns
a compact `CaptureCompletion`, without loading every interval into memory.

Direct archive-library callers can allocate a `CaptureArchiveSession`, retain it,
then call `prepare()`. Preparation commits session identity, the initial canonical call, lifecycle and
optional caller work in one SQLite transaction. The convenience
`begin()` returns `CapturePreparationFailure.session` on a preparation failure.
Instance `recover()` also works after correcting a failure before the first write;
static recovery uses the durable session metadata after relaunch. Both finalize
a never-opened capture as zero-duration interrupted and never open a stream.

`setMicrophoneEnabled` acknowledges only after the serial audio queue applies
the policy. It does not change microphone controls in the calling application.
`stop()` is independent of current focus. Call `stop(reason: "application_termination")`
from the application's coordinated termination path before allowing quit. Sleep
and source-process loss are observed by the facade itself. The library contains
no global shortcuts or panels; those are composed by `RecordingCoordinator`; see [recording controls](recording-controls.md).

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
allowance and waits for already-admitted pending input. The separate callback
queue admits at most one second per source and 256 audio buffers including
in-flight work. Each drain processes at most eight buffers before yielding to
controls; stop freezes admission and drains the bounded remainder before sealing.
Foreign/replaced streams and audio wholly before confirmed media progress are
rejected before reserving capacity. The engine publishes that host-clock boundary
only after a successful durable flush. Delayed native bursts after a silent start
cannot fill the live-input queue with audio that can no longer change the master.
Packets crossing the committed boundary remain admitted, with a conservative
output-frame margin for conversion rounding. Silence and missing callbacks do
not interrupt capture; their unavailable intervals continue on the call clock.
Overload of current input still fails
explicitly instead of accumulating tasks or buffers. A millisecond with any
missing source sample is unavailable, and all its source samples become silence. Physical device
absence takes precedence over muted intervals while mute policy remains unchanged.

Microphone suppression happens before persistence. Policy changes clear pending
microphone samples and converter history. Muted and stale pre-unmute callbacks are
discarded before conversion, so suppressed speech cannot reappear through a
resampler tail. No `.screen` output or `SCRecordingOutput` is registered: no video
or screen samples enter the writer.

## Local media and recovery

Each call owns only `media/master.caf` and `media/master.index` under its stable
call identity. The namespace SQLite repository owns admission, progress, stop
intent, final publication and processing lifecycle. Media directories and files
are owner-only. Every append applies microphone policy, synchronizes at most one
second of PCM, synchronizes its integrity/index record, then commits the returned
certificate to SQLite. There is no minute rollover, raw spool, growing checkpoint
JSON, separate metadata publication protocol, or legacy sealed-WAVE receipt.

The CAF header is immutable, including its indefinite final data chunk. Finalization
appends/synchronizes a final index record and never rewrites uploaded media bytes.
Recovery verifies every complete integrity record and the repository-confirmed
cursor. It may discard bytes lacking a valid committed record. A terminal,
complete-sized torn index record is also discardable only after independently
matching the SQL witness and with at most one append of unindexed PCM. Damage
at/below that witness, nonterminal index corruption, committed audio corruption
or a missing repository witness fails explicitly without truncating retained evidence. A fully synchronized external commit whose
SQLite acknowledgement was lost is reconciled idempotently. Recovered writers
can finalize/read/extract but cannot accept new recording input.

A known stop intent is committed before external final synchronization. Caller work,
when supplied, is retained as session finalization intent and becomes runnable only
with the canonical publication. Final call/audio reference, stable master witness,
capture lifecycle and associated work commit together. Retrying after process death
preserves identities, exact snapshot bytes and clean or interrupted stop semantics.
An unopened capture finalizes with no invented media witness; a zero-frame opened
master retains its real 68-byte header hash and publishes no audio object.

Final publication streams merged intervals from bounded repository pages into exact
exchange bytes and stages them in 256 KiB SQLite chunks. The production completion
path never builds a call-long interval array or revalidates a call-long JSON tree.
Generated scalar encoding and public contract conformance are checked on shared
fixtures. Explicit full-aggregate APIs remain available to callers that need them.
No successful range, extraction or finalization deletes local media. See the
[downstream media interface](capture-master-interface.md) for stable ranges,
final evidence, extraction and the future complete-receipt cleanup authority.

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
exercise, focus changes, actual TCC prompts and app-owned credential continuity
remain the human-assisted #57 foundation acceptance. No real call, private audio, upload or paid ASR is used.
