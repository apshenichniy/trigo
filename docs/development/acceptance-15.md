# Issue #15 capture checkpoint

Implementation base: `bff3fa2e39deed149e81d2bcd2b04fe25bd2b8c8` from
`codex/mvp-integration`. Implementation checkpoint:
`3df2734847d5dda4a0f5417821bea49ffcd506ca` on `codex/issue-15-screen-capture`.
The coordinator owns rolling integration and the subsequent #16 UI work.

## Environment and scope

Verified on macOS 26.6.2 (25G83), Xcode 26.6 (17F113), SDK 26.5, with deployment
floor macOS 15. Both unsigned build variants compile with locked dependencies.
The production library includes source/permission resolution, ScreenCaptureKit
adapters, shared-clock PCM conversion, effective microphone suppression, durable
WAVE objects, recovery and canonical local publication. `App.swift` is unchanged.

## Automated evidence

`mise exec -- bun run check` passed on the implementation checkpoint:

- 137 TypeScript unit tests and 17 Worker tests.
- Five shared Swift contract tests, including the chosen media profile.
- Native suite (66 tests reported), both Trigo/Trigo Dev builds, artifact privacy-key assertions and
  the external-network-denied local Worker/R2/fake-ASR smoke.
- All capture fixtures run without requesting TCC access or opening an actual
  capture stream; the existing opt-in live pairing test remains opt-in.

The main capture proofs exercise the actual library interfaces:

| Boundary                     | Result                                                                                                                                                                                                  |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WAV interoperability         | AVAudioFile independently decodes 16 kHz stereo s16le objects; known microphone/application levels occupy channels 0/1                                                                                  |
| Permission/source resolution | Denied screen audio/mic access, unresolved source and own process fail closed; PID/bundle/launch identity pins the application                                                                          |
| Callback admission           | Foreign/replaced stream callbacks rejected; microphone decoding failure does not stop application capture                                                                                               |
| Mic policy/device loss       | Initial silence and gaps retained; loss during mute is unavailable, return retains mute; delayed muted callbacks cannot prime the resampler or leak persisted speech                                    |
| Native conversion            | 48 kHz and 44.1 kHz controlled CMSampleBuffers converted using requested input pulls and absolute host timestamps                                                                                       |
| Force termination            | Each child is SIGKILLed after its third PCM sync: 192000 spool bytes, exactly two durable checkpoint fragments, exactly 2000 ms recovered; 275 successful terminations in focused/repeated short checks |
| Corruption                   | Corrupt second active fragment rejected; preceding 60-second object and one valid active second retained as a 61-second prefix                                                                          |
| Finalization replay          | Crash after immutable audio-manifest publication reuses the durable finalization intent; no new object identities or immutable conflicts                                                                |
| Partial Start                | First-write failure and crashes after each of three preparation writes preserve the call ID and recover as zero-duration interrupted; facade retains needsRecovery                                      |
| Late Start cancellation      | Four controlled application/microphone late success/failure cases retain cancellingStart until retirement, reject overlapping Start and isolate the next recording                                      |
| Stream retirement            | A failed stop remains owned and blocks replacements until retry succeeds                                                                                                                                |
| Three-hour writer            | 180 independently decodable objects, 172,800,000 frames, 10,800,000 ms; no silent truncation; an extra millisecond is rejected explicitly                                                               |
| One-hour common clock        | Independent 48/44.1 kHz callbacks and simultaneous per-second markers; maximum measured source-relative marker drift 0 ms (target at most 200 ms)                                                       |

Tests first exposed and then guarded against native converter input truncation,
muted-speech converter-history leakage, lost interruption reasons between media
sealing and canonical publication, and immutable-manifest replay conflicts.
The full suite also exposed a test-host race: self-directed `kill(2)` could return
before termination, allowing the third checkpoint to commit. The child now checks
kill success and cannot return to the writer; the exact two-second assertion was
retained and strengthened with independent checkpoint/spool evidence. The focused
25-case fixture and ten repeated short native suites passed before the final full
check. Production recovery behavior was not weakened or changed for this test fix.

## Review and remaining acceptance

Review findings were repaired with regression coverage: reason validation,
partial preparation/finalization ownership, duplicated profile arithmetic,
immutable finalization replay, late start/callback generations and physical
microphone absence during mute. Independent exact-range re-reviews from the
integration base through the implementation/test checkpoint reported:

- Standards: no documented-standard violations or clear baseline smells.
- Spec: no findings within the agreed library/checkpoint scope.

The test-only SIGKILL repair was independently re-reviewed on both axes with no
findings. Final PR-head CI results are recorded in PR #41 and the issue handoff;
the acceptance-document commit adds no implementation changes.

This is not physical capture acceptance. The owner-authorized sequence explicitly
defers installed Trigo Dev, controlled Chrome/mic audio, actual permission prompts,
focus-change isolation and hardware behavior until #16 integration. No real call,
private audio, paid ASR, provider switch, cloud deployment or personal app data was
used. Full #13 hosted transcription remains separately unproven and does not gate
this profile/capture checkpoint. Issue closure remains with the coordinator after
the deferred acceptance boundary.

See [native capture integration and recovery](capture.md) for the #16 API handoff.
