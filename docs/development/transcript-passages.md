# Transcript passages across source pauses

Issue #91 fixes a source-channel grouping error: an early microphone word and
speech many minutes later could share a provider label and become one turn with
the early start time. Capture and individual word timestamps were correct.

New normalization ends a passage when two consecutive reliably aligned words have
more than 1,200 ms of silence, as well as when the speaker label changes. It keeps
source word order, text, times and scoped speaker identity. Approximate alignments
do not establish a new pause boundary. Channel heads are interleaved by playback
time without sorting a channel's provider text out of order.

The native v6 SQLite migration adds a rebuildable passage projection. Existing
revision bytes, hashes, turn IDs and canonical call annotations are unchanged.
Imports prepare this projection; old stores build it lazily from exact retained
revision bytes. Completion is recorded after all bounded preparation batches.
Pagination and the reader count use projected passage ordinals. Each displayed
passage retains its original turn ID and first word ordinal; their combination is
the stable UI identity. Speaker excerpts and timestamp playback use these passage
bounds. A turn whose text cannot be reconstructed losslessly from its words keeps
its original presentation.

## Verification

A failing normalizer regression reproduced a microphone greeting at 145,260 ms
followed by speech at 1,088,130 ms under the same label. The corrected output
interleaves intervening application speech and preserves every original word time.
The normalizer's 12 tests passed. A private retained-response replay also preserved
all 2,588 source words and their times and placed the returning speech at
1,088,130 ms, without another provider request.

Native tests cover a real v5-to-v6 store migration with an old unsplit revision,
pagination, stable passage identity, names, speaker excerpts, approximate timing,
and exact retained canonical/revision bytes. The native quick gate passed all
280 fast tests and shared contract conformance. Existing v2/v3/v4 upgrade cases
remain covered. Full local verification belongs to the final integration
candidate; deployment and installed-app acceptance are separate.
