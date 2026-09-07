# Capture master interface

Issue #53 connects the selected #51 CAF master and #52 SQLite repository to
production capture. Upload, synchronization, server receipt handling and hosted
ASR remain downstream work. This document specifies the boundary they consume.

## Identity and profile

`CaptureArchiveSession` allocates archive/call, microphone/application track,
audio-manifest and master identities before opening media. Admission commits them
with the initial call and lifecycle. All retries retain those identities.

The new session-intent columns and removal of the transitional sealed-WAVE receipt
use SQLite schema version 2. An older or mismatched schema is rejected before
mutation; no implicit migration or deletion of an existing namespace is performed.
The approved clean cutover uses a new explicit development namespace.

The authored `CaptureMasterProfile` Effect schema and checked
`capture-master-profile.v1.json` produce the shared JSON Schema and Swift values.
The native `MediaMasterProfile` reads this selected profile.

| Concept          | Contract                                                                                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Permanent master | `caf-lpcm-s16le-16000-stereo-v1`, `audio/x-caf`, interleaved signed 16-bit little-endian PCM, 16 kHz.                                                                                        |
| Source mapping   | Channel 0 is the admitted microphone track; channel 1 is the admitted application track. No speaker or participant identity is inferred.                                                     |
| Master bounds    | Three hours, 172,800,000 frames, 691,200,068 bytes including the immutable 68-byte CAF header.                                                                                               |
| Durable commit   | At most one second / 16,000 frames. One 2,120-byte integrity record plus the 128-byte index header.                                                                                          |
| Upload range     | At most 8,388,608 bytes. The 5,242,880-byte multipart minimum applies to nonfinal parts; range boundaries need not be independent audio files.                                               |
| Source time      | Call-relative integer milliseconds; unavailable or muted source samples are all zero before persistence, hashing or range access. A partially available millisecond is entirely unavailable. |
| Final identity   | Stable master/call/track IDs, final frame count, stable byte length, profile, source mapping and whole-master SHA-256 including the CAF header.                                              |

The WAVE profile `trigo-call-wav-s16le-16khz-stereo-60s-v1` remains the supported
provider-probe input from #13. It has separate object/request limits. Neither CAF
selection nor local decoding proves hosted-provider acceptance. A master larger
than 8 MiB is valid; one upload request larger than that cap is not.

## Durable range reads

The capture queue alone owns `CaptureMediaWriter`. `append` completes external
media sync, index sync and SQLite progress publication before returning. An
uncertain append closes that writer for new audio. `recover(session:)` verifies
the persisted witness, reconciles synchronized external commits incrementally,
and returns a writer that can finalize/read/extract but cannot resume recording.

`confirmedCursor()` returns repository-confirmed progress, including the actual
header boundary before the first nonempty commit. `readStableBytes(in:)` accepts
only nonempty ranges within that progress and the 8 MiB cap. It returns exact
immutable media bytes, not reconstructed PCM. Callers must serialize access with
the writer owner; there is no public mutable master escape from this adapter.
Future uploader state must retain the same master identity and absolute byte
offsets independently of integrity commits. A successful range does not establish
the final size/hash, complete-server receipt, or permission to remove local media.

## Final publication and replay

Persist `requestCaptureStop` before invoking external finalization. If finalization
has associated durable work, call `prepareCaptureFinalization` with that work
before the final index synchronization. It retains operation identity/payload and
the stop intent; the operation is not runnable until final publication.

`CaptureRecordingEngine.stop` flushes the timeline and produces a
`FinalizedMediaMaster`. `CaptureArchiveSession.complete` publishes that witness,
the final call/audio reference, capture lifecycle and prepared work through one
repository transaction. Nonempty calls have one `AudioObject`: the stable master
ID, index zero, full call duration, final size/hash and the two original tracks.
An opened zero-frame master retains its real header witness but has no audio
object. Admission without any opened media publishes no fabricated witness.

The compact `CaptureCompletion` contains `LocalCallSummary`, optional final
master witness, exact snapshot SHA-256 and byte count. Production stop/recovery
use it so dense long-call intervals do not become an in-memory aggregate.
`recoverCompletion()` never opens devices and preserves clean stop or known
interruption cause. Repeated completion accepts matching evidence/work and rejects
conflicts. Fully synchronized media whose final SQL publication was interrupted
retains its master identity, final hash and pending work.

Public `finalizeCapture(callSnapshot:audioManifest:verifiedMaster:)` admits exact
exchange bytes with the same retained stop/work intent and source-state witness.
Semantically equivalent adjacent intervals may remain split in those bytes.
Once published, replay requires the exact retained bytes at the supplied document
version; different whitespace or metadata conflicts. Exact historical finalization
replay after a later manifest version returns the current aggregate and preserves
both versions without rewriting history.

`forEachSnapshotChunk(callID:version:consume:)` yields exact retained exchange bytes
in at most 256 KiB chunks and verifies their whole stored hash. Final projection
merges source intervals with bounded cursors and stages immutable rows/bytes
before the small publication transaction. Temporary snapshot staging bytes are
not recovery authority; an interrupted attempt can leave only unreachable
preparation until retry. Explicit `finish`, `recover` and `loadCall` aggregate
conveniences materialize full documents when a caller chooses that cost.

## Extraction and retention

After the final witness is committed, `CaptureMediaWriter.extract(frames:to:intervals:)`
creates a bounded-streamed CAF slice. The returned `MediaMasterExtraction` retains
the parent final master, original call/track identities, exact call-relative frame
range, output byte count/hash, profile, channel mapping and
`identity-stereo-pcm-frame-slice-v1` transform. Its optional source-interval callback
delivers bounded clipped evidence in original call-relative time. No call-long
array is required. Whole-call extraction has the same bytes/hash as the master.

ASR intervals, transport parts and integrity commits are independent concepts.
Future provider adapters must preserve original time/source provenance and record
any additional conversion. Hosted limits or a short provider response cannot
truncate the permanent master or become its final duration.

Capture/recovery/extraction never delete the local master or index. Cleanup
authority is the future durably committed complete, verified server receipt;
partial transport success, operation acknowledgement alone, local finalization
and ASR success do not grant that authority.
