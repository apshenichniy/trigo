# Approximate ASR word timing

Implements [#89](https://github.com/apshenichniy/trigo/issues/89) under the
[owner's timing decision](https://github.com/apshenichniy/trigo/issues/88).
The capture fix in [#87](https://github.com/apshenichniy/trigo/pull/87) remains
part of the candidate's baseline.

## Behavior

Nova-3 can return a complete HTTP 200 response with overlapping words and words
past the verified recording's end. The reproduced response contained a 281 ms
word overlap and a final word at 18.599–18.999 seconds in an 18.514-second master.
Neither condition establishes truncated input or an incomplete provider response.

Normalization version 2 retains the text, punctuation, reported millisecond
positions, confidence and source/speaker scope. It marks unreliable words with
`timingUncertain: true`; absence of the key retains ordinary timing validation.
Turn playback ranges are independently bounded to the submitted audio interval.
A wholly outside passage may have an empty playback interval. The reader and
speaker excerpts show `Approximate timing`; an empty passage interval has no
active timestamp-playback control. Full recording playback remains available.

Version 1 revisions retain their previous semantic constraints and exact bytes.
Version 1 does not admit the uncertainty marker. Unmarked version 2 words retain
strict ordering and containment checks. Structurally invalid responses, missing
channels/word timing, unrepresentable milliseconds, invalid confidence, and
incomplete or mismatched transport evidence still fail validation.

The optional wire key is generated from the Effect schema. Swift distinguishes
an absent optional key from an explicit null while retaining the existing
required-nullable behavior. SQLite version 5 adds only the bounded, rebuildable
turn-timing projection; migration from exact version 2, 3 or 4 stores preserves
canonical documents, audio and lifecycle state.

## Retained-result recovery

Replaying the identical initial transcription command can repair an operation
that failed with `asr_result_invalid`. It normalizes the retained complete raw
responses and publishes the result under the existing operation/revision IDs.
It does not reopen the operation or call the provider. Failure remains terminal;
no replacement attempt or Workflow admission follows this repair path.

Publication still requires the current owner generation, active call, latest
operation and latest failed normalization attempt. Immutable artifact durability
precedes the atomic transition from failed to result available. A repeated
command returns the retained result; interrupted publication reuses its artifacts.
Other failure classifications retain their existing behavior.

## Local evidence

- The focused production-normalizer reproducer failed before the fix and passed
  afterward. Independent overlap, beyond-end, reversed-order, reversed-span and
  invalid-number cases preserve the appropriate evidence or rejection boundary.
- Replaying the exact retained real response passed without network access or an
  ASR invocation: all 121 words retained their text, order, timestamps and
  confidence, 6 words were marked uncertain, and both turns stayed inside audio.
  Private audio/transcript contents remain outside the repository.
- Shared TypeScript/Swift fixtures cover version compatibility and marked versus
  unmarked timing. Native checks cover import/reopen, speaker excerpts, exact-byte
  retention and non-destructive version 4 migration; existing version 2 and 3
  migration checks remain required.
- Worker tests cover replay of the same failed command, interrupted publication,
  no duplicate provider admission, and owner/deletion/newer-operation/newer-attempt
  fences.
- `bun run test:ui --suite shell --filter 'testReaderApproximateTiming|testReaderSelectionRevisions'`
  passed both tests, including light/narrow-dark screenshots, bounded playback,
  disabled empty intervals, retained revision selection and application restart.

The final PR carries the committed source/tree and full local verification
receipt. Fixture acceptance and the private local replay are separate from a
hosted deployment and owner-operated real calls.

## Rollout boundary

Install the compatible native build before the server starts producing version 2
revisions. Upgrade the existing store in place. After an authorized Dev deployment,
replay the failed initial command with its original IDs and requested language,
then confirm native import, canonical replica publication and transcript reading.
Do not create a new ASR operation to repair retained normalization evidence.
Merge and cloud deployment follow the repository's explicit owner-authorization
rule; this local acceptance does not claim either has happened.
