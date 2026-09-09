# Library and transcript reader

Issue #20 connects the accepted desktop reader to the canonical repository from
#19 and retained-audio playback from #73. The installed composition shares the
application's upload/synchronization owner and uses the real HTTP playback
transport and AVAudioEngine output. Closing the library pauses its player and
cancels reader work; it does not stop upload, transcription or synchronization.

## Reading and navigation

`RepositoryLibrary` exposes paged metadata, retained revision identities and
counts without loading audio intervals or transcript JSON into the sidebar.
`LibraryModel` owns selection, local calendar groups and paged passages. Dates
are parsed before sorting so optional ISO-8601 fractional seconds cannot change
chronological order or the descending call-ID tie break. Day groups update when
the local day or time zone changes even if the repository has not changed.

The native List supports keyboard navigation. Selection persists in the current
app namespace across close/reopen and relaunch. An explicit Open Call route
selects that call before or after the repository opens. A new imported revision
becomes selectable without replacing a retained revision currently being read;
viewing a different revision never changes the canonical active pointer.

The floating sidebar and bottom player use native glass on macOS 26 and material
on macOS 15. The native toolbar toggles the sidebar and provides Recording
Details. The sidebar width and window size can be adjusted while paragraphs
wrap. Source metadata supplies the call label. Independent capture, upload,
transcription, import and replica states remain available in Recording Details.
Empty, locally saved, pending, interrupted, failed, offline and no-speech records
keep their available text and metadata accessible.

## Explicit speaker annotations

Rename, Group with, Manage group, member removal and Ungroup call #19's atomic
annotation services. The editor shows original scoped labels, sources and
excerpts. Equal provider numbers from separate scopes remain distinct; unknown
attribution is never assigned an identity. Group merges include complete chosen
groups and preserve individual names underneath them. Removing a member or
ungrouping restores its individual or neutral name.

Each save retains one operation identity for retry. Offline changes remain
durable and show pending synchronization. Conflicts open a comparison of this
Mac's names/groups and the server's names/groups, followed by an explicit choice.
Editing a retained revision preserves evidence bytes, passage IDs, timing and
the active revision. New revisions receive no implicit annotation transfer.

## Playback and recovery

Timestamp actions, play/pause and seeking use `CallAudioPlayer`. Successful
verified master cleanup does not prevent playback: audio comes from the private
server through a temporary capability. No-speech transcripts can still play
their retained audio. Known playback failures disable the affected controls and
show a reason; recoverable failures expose Retry Playback, and access failures
also expose Connection Settings. Retry reacquires access at the selected
position and returns paused. Closing during an outstanding seek cannot restart
playback after the media arrives.

The reader exposes no Export, manual Retry/Re-transcribe or Delete Call command;
those remain the explicitly deferred #21/#22 scope. Technical recovery of the
initial upload/synchronization pipeline continues through its existing owner.

## Verification coverage

`LibraryModelTests` exercise real isolated repositories and cover local midnight
and time-zone grouping, chronological ties, selection across insertion/relaunch,
explicit call routing, retained/new revisions, Unicode/group annotations,
processing failures, conflicts without a document-version change, grant renewal,
unavailable playback, close-during-seek and close-during-revision-read races.

The native/local Worker acceptance creates a 31-second two-source master, loses
the first local receipt commit, replays upload/finalization, verifies normal local
master removal, runs automatic fake ASR, imports exact result/provenance bytes,
confirms the canonical replica and restores it into a fresh repository. The
reader then selects the restored no-speech transcript, plays its audio, seeks across
the 30-second segment boundary and back, and checks distinct stereo samples with
real AVAudioEngine offline rendering. This is local shared-service integration;
it is not a hosted-ASR or audible-device claim. Timestamp-button dispatch is
covered separately by the seeded native UI scenario and focused reader tests.

The `reader` UI scenario uses the production views and real canonical repository
with a validated synthetic archive. Its playback transport and held output are
explicit fixture adapters; it opens no microphone, network or audio device.
It adds three XCUITest scenarios to the existing ten shell/panel scenarios:

- Date groups, keyboard navigation, retained revision selection, timestamp
  playback, close/reopen/relaunch selection, and narrow light/dark layouts.
- Unicode naming on an old revision, two named groups, group merge, member
  removal, Ungroup, unchanged evidence identity, a neutral new revision and
  explicit conflict resolution.
- No-speech audio, unavailable playback with disabled controls, explicit retry at
  the retained position, and pausing when the library closes.

The fixture explicitly sets its own AppKit appearance and records the effective
appearance. Launch defaults alone were observed to leave a nominal Dark launch
light on macOS 26.6.2. Tests assert the effective appearance before treating a
screenshot as dark. Container accessibility elements preserve the individual
timestamp, speaker, revision and player identifiers; SwiftUI's inherited parent
identifier previously replaced them.

Run affected checks and the full acceptance commands from this checkout:

```sh
TRIGO_TIMINGS_FILE=.local/library-timings.jsonl bun run test:native --suite fast --filter LibraryModelTests
TRIGO_TIMINGS_FILE=.local/library-timings.jsonl bun run check:macos:smoke
TRIGO_TIMINGS_FILE=.local/library-timings.jsonl bun run test:ui --suite shell
TRIGO_TIMINGS_FILE=.local/library-timings.jsonl bun run check:macos
bun run check:server
```

## Retained implementation evidence

The following pre-commit probes used base
`e4f7f7d9d94ef1126af3f6e8e6859a0937dcc67c`. Fingerprints identify the dirty input
state recorded by the timing harness; elapsed time includes the current-source
Release build. These are focused evidence, not the final full acceptance gate.

| Probe                                         | Result and elapsed time                   | Input fingerprint                                                  |
| --------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------ |
| Close during seek and known unavailable audio | Red: two tests, four assertions, 79.078 s | `21bf0713154216fbadca59019d74b244cac058d0ef3fcd0627bd1fd80b739098` |
| Reader and affected shell routes after fixes  | Green: 11 tests, 79.023 s                 | `9f0192fc1ee701f75c4f1665ef3752fa43c49b3bde33e5b7e42d7426a86a7793` |
| Close before selected revision read completes | Red: one test, 60.938 s                   | `024ab191a09a189bde9ac16d210b7af1f1df25dd4e8d49e4c8392627d53c816c` |
| Reader after invalidating the unfinished read | Green: eight tests, 35.891 s              | `eebf322dba618ff4e6f8997d0c870782351cc788c69bfa115d3732289ddaea59` |
| Equivalent/mixed-precision ISO timestamps     | Red: one test, three assertions, 57.711 s | `2d64bd19c33aec520c48a3fb798856600d9c37aefc60d0d5bac81900d3a290c6` |
| Reader after chronological date comparison    | Green: nine tests, 79.407 s               | `0ca6501a750c29ad65e83bb4de4f377e387417007fd3933d27fd83bb87b849bb` |

The first reader UI build failed on a missing `try` in fixture source-state
construction (38.326 s); it was corrected. Two subsequent invocations built
successfully but failed before executing any test with “Timed out while enabling
automation mode.” Preserve the corresponding ignored runs:

- `2026-09-09T00-34-08.095Z-92ddf24a`: 90.267 s,
  input `f847f2519cde2bb76dbe7b594a83f7743ec09b4c7298cd009b2a3feb45fff6ba`.
- `2026-09-09T00-48-51.436Z-f90fd48e`: 91.546 s,
  input `5595ab79113d64000cc51de3f6dcfbbfcf08007da938839c39c6e8514e09237d`.

Supplementary native UI interaction on September 9 exercised timestamp playback,
retained revisions, Unicode rename, two-group merge, member removal, Ungroup,
server conflict choice, unavailable/no-speech playback recovery, close/pause,
and the 820-by-670 light/dark reader. The isolated repository confirmed unchanged
retained evidence hash and passage IDs, restored individual names and neutral
names on the current revision. This found and corrected the accessibility and
fixture-appearance issues above. It does not replace the required XCUITest gate.

The PR records final source identity, complete local/CI results and any remaining
GUI limitation after this document is committed. Signed installed controls,
hosted playback and the complete one-/three-hour provider path remain integrated
#24 acceptance; fixture text alone is not first-use delivery.

The first full native check on `9fe2b3c21ae5c02583cd01a9d502fff5ce92b192`
passed nine contract tests, 267 fast native tests, three contention tests, all
seven resource proofs and both app builds. The final local Worker smoke failed
because its new reader assertion incorrectly expected a speech turn from the
deliberately empty fake provider. The corrected assertion requires the no-speech
revision and exercises retained-audio playback and seeking through the reader.
The failed full invocation is retained at 552.200 s; focused rerun and final CI
outcomes belong in the PR. No provider or product behavior was changed for this
test correction.

The corrected smoke on `8be04935e111c146028c5405688ba231ecff2d1e` then exposed a
product crash when the reader paused real AVAudioEngine playback before its first
offline render: AVAudioPlayerNode rejected a render time with neither valid sample
time nor valid host time. That failed invocation is retained at 61.511 s, including
6.696 s of local transport acceptance. The playback service now validates the time
before conversion and preserves the selected position while no frames have
rendered. Its minimized failing regression and seven-test passing result are
recorded in [retained call playback](playback-service.md). The PR records the
original reader/Worker smoke rerun after integrating that service fix.

## Performed XCTest integration and selector correction

The first complete thirteen-scenario invocation on `6fe2e0193` initialized and
executed all tests. Its ten shell/panel scenarios passed; all three reader tests
failed on inaccessible query matches in run `2026-09-09T08-18-20.466Z-f45a42cb`
(659.063 s). The retained accessibility hierarchy shows the model's four calls
already rendered: row content and day headings are child static-text elements,
while the test queried text on their parent outline rows. The opened revision
menu stores its text in `title`, while the test queried `label`.

The tests now select call content through its existing stable accessibility
identifier, check day-heading static text inside the call list, and select a
revision by its title within the actual popup. These are native pointer actions;
all subsequent model/evidence assertions and all thirteen scenarios are retained.
No production view, repository, text or timing contract changes for this fix.

The focused three-reader selection passed without failures or skips in run
`2026-09-09T08-33-01.712Z-f91764cd`: 230.308 s overall, 217.588 s in the test
command. It exercised no-speech playback failure/recovery, revisions and timestamp
playback, keyboard navigation, reopen/narrow Dark Aqua layout, Unicode names,
group merge/removal/Ungroup and explicit server conflict selection. Both successful
and failed commands verified restoration of the original keyboard input source
through the [host coordinator](verification.md). Final committed integration,
the full thirteen-scenario result and required CI remain in the PR evidence.
