# Silent-start capture queue overflow

Issue [#60](https://github.com/apshenichniy/trigo/issues/60) resumes the installed
startup failure investigation. The owner requires Ctrl+Ctrl to start and retain
recording when the selected application is silent, including when sound begins
later. Silence is not a capture failure.

## Confirmed failing boundary

The 2026-09-09 ordinary signed Dev attempt in silent Telegram interrupted after
2,077 ms with `capture_queue_overflow`. A subsequent attempt with playback stopped
normally after 4,802 ms. The failure-only trace retained format, timestamps, queue
counts and processing timings, without audio, transcript text or window titles.

At overflow, 50 application packets of 960 frames at 48 kHz occupied the one-second
source cap. The first was in flight for less than 0.8 ms and no packet had completed;
the rest arrived during that same sub-millisecond burst. Writer initialization
took 1.45 ms. The preceding timer flushes took 2.09, 86.72, 15.03 and 22.96 ms,
including media and repository work. This observation establishes a native burst,
not a second-long consumer stall, for this attempt.

Correlating host PTS with wall time placed the first packet approximately 0.40 s
after the recording origin and 1.67 s before delivery. Meanwhile the timer had
already durably filled most of that historical interval as unavailable. Exact
origin/delivery host times were not retained by this probe; the regression uses
rounded representative times. The defect is admission of wholly obsolete input
against the live-audio cap, before the timeline can ignore it.

## Reproduction and change

The production `CaptureStreamSink` regression advances the real engine to 1.725 s
with no input, committing through 1.475 s. It then delivers 20 ms packets covering
0.40...2.08 s as one deterministic burst. The consumer is held only across that
callback burst to eliminate scheduler variation.

Before the fix, the initial test
`productionSinkSurvivesSilentStartupAndDelayedApplicationBurst` failed in 0.934 s:
the sink reported `capture_queue_overflow`, ingress was rejected, and the surviving
interval was unavailable instead of retaining current audio. Its native source
was main at `d0b5b4432e77ba7bfe6885cbb3304e0875595d02`, with only the new test.

After a successful engine flush, the sink publishes the committed host-clock
boundary to ingress under its existing lock. Ingress ignores packets wholly
before that boundary before reserving capacity. A two-output-frame margin keeps
packets that could cross the boundary after placement rounding or resampler phase.
No persisted interval is rewritten. Current input retains the one-second/source,
256-buffer and eight-buffer drain limits and explicit overload failure.

Temporary instrumentation and unrelated experimental changes are absent from the
candidate. No activity/QoS change, increased queue, retry, storage-policy change or
transcription change is part of this fix.

## Acceptance

The expanded regression `productionSinkSurvivesSilentStartupAndDelayedAudioBurst`
tests both application and microphone input, each with continuous silence and
with sound beginning after startup. It verifies the exact unavailable/recorded
boundary, zero samples before that boundary, the later sound samples, channel
isolation, an empty final queue and the existing capacity limit. A separate
ten-second call-clock test verifies normal stop with no callbacks at all.

Existing ingress overload, yielding, multi-batch stop and delayed-timer durability
tests remain part of the affected checks. Full native contention/resource and
repository checks run through the normal local pre-push gate. Their final source
identity and results belong in the PR's verification evidence.

The installed acceptance uses the normal signed Dev namespace and physical
Ctrl+Ctrl in silent Telegram, followed by sound and explicit Finish. Record the
owner's result separately from deterministic tests. Neither fixture PCM nor this
change establishes hosted transcription success; that investigation follows the
capture fix.
