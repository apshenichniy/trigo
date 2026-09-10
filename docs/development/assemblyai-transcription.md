# Direct AssemblyAI transcription

Decision [#92](https://github.com/apshenichniy/trigo/issues/92) and implementation
[#93](https://github.com/apshenichniy/trigo/issues/93) select Universal-2 through
`https://api.eu.assemblyai.com/v2`. Cloudflare still runs the private archive and
orchestration. New automatic desktop requests select
`assemblyai-u2-wav-s16le-16000-stereo-v1`; persisted commands keep their profile and
identity, and the legacy Nova-3 profile remains readable and executable. There is
no automatic cross-provider fallback.

## Source and evidence contract

One stereo PCM WAVE submission retains microphone channel 0 and application
channel 1. AssemblyAI's returned channels 1 and 2 map to those tracks. Each
submission/channel has its own diarization scope; equal provider labels never
merge across scopes. A track is not assumed to contain a single person. No speaker
count hints, speaker identity inference or experimental stereo/mono fusion run.
Explicit `ru`, `en` and `uk` use `speech_models: ["universal-2"]`,
`language_detection: false`, `multichannel: true`, `speaker_labels: true`,
`punctuate: true` and `format_text: true`.

The immutable CAF master is read in bounded ranges. Extraction records exact
master/manifest hashes, channel mapping, frame ranges, WAV length/hash and call-time
offset. A `FixedLengthStream` uploads those bytes; only a complete successful
upload and matching extraction digest authorize transcription admission. The
retained witness is `http-upload-ack-v1`, not provider-observed consumer EOF.
Returned duration is a coarse check with one-second tolerance for rounded seconds;
it does not replace the exact source witness. Word order, text and provider times
remain intact. Conflicting timings are flagged approximate and playback bounds
stay inside the interval. The shared 1,200-ms passage-gap rule from
[#91](https://github.com/apshenichniy/trigo/issues/91) splits reliable same-label
speech after a pause.

The application retains its two-hour interval cap: a three-hour master has two
independent submissions. This is an engineering bound, not a newly established
hosted AssemblyAI long-call limit. Per-result raw bytes are capped at 8,000,000,
the normalized revision at 16,000,000 and provenance at 65,536 bytes. No audio or
transcript payload enters Workflow history.

## Durable admission and recovery

Additive D1 migration `0006_assemblyai_jobs.sql` associates each existing submission
with upload phase, exact upload URL/witness, provider ID and cleanup state. Existing
operations, raw results and canonical documents are not rewritten.

1. Admit a raw writer and stream the upload. If the URL acknowledgment was lost,
   an upload may be repeated; only the latest upload claim can attach its URL.
2. Atomically transition `uploaded` to `submitting` under the current owner,
   operation and attempt fences. This transition alone authorizes the paid POST.
3. Record the returned provider ID even if a fence moved during HTTP, preserving
   cleanup responsibility. A lost/invalid acknowledgment stays `submitting`.
4. Recover unknown admission by bounded provider listing using the exact owned
   upload URL. Never follow a returned pagination URL. Ambiguous or absent matches
   do not prove the POST failed and never authorize another paid POST.
5. Poll the same provider ID using short Workflow steps and durable 30-second
   sleeps. After 360 rounds, retain the active attempt and expose
   `asr_processing_timeout`, or `asr_admission_uncertain` when the ID remains unknown.
   Replaying the same command resumes that attempt. The desktop permits one
   automatic timeout recovery; further or uncertain recovery requires its explicit
   Retry action.
6. Retain and verify complete/error/malformed response bytes before normalization.
   Only validated channel/model/language/source evidence publishes a revision.
   Confirmed no-speech produces an empty result; zero-duration masters bypass ASR.

Known provider failures may use the original-plus-one replacement ceiling.
Successful sibling intervals are reused. Authorization, funds, unsupported input
and invalid evidence require correction. Unknown admission stays recoverable and
does not consume a replacement. Retained-normalization repair reads only stored
bytes and cannot upload, submit or poll.

Cleanup deletes only provider IDs owned by this operation after retaining its
result/diagnostic bytes. A known job cancelled by owner rotation, supersession or
call deletion can be deleted without retaining cancelled content. The cleanup step
has ten retries; a failed deletion leaves durable debt and an errored Workflow.
Available transcript bytes remain readable. Replaying the available operation's
same command can restart cleanup without paid work. Unknown upload/POST identities
cannot be safely deleted by guess; preserve their admission records for recovery.

## Configuration and validation

`ASSEMBLYAI_API_KEY` is a redacted server deployment secret. The desktop only holds
its Trigo owner credential. Infrastructure reports secret presence without
claiming provider validation. See [cloud operations](cloud.md).

Local verification covers HTTP request options and streaming, lost/malformed POST
acknowledgments, pending jobs, replay, exact lookup, deletion identity, original-plus-one
replacement, retained repair, owner fences, cleanup failure and two-interval reuse.
The long-call fixture uses real extraction with virtual bounded R2 ranges; it does
not prove hosted upload throughput. AssemblyAI Workflow tests exercise the real
D1/R2 ledger with deterministic step callbacks. Existing local workerd Workflow and
native/HTTP acceptance continue using explicit fake ASR, while the hosted harness
requires the new upload witness. Shared TypeScript/Swift fixtures accept the new
revision and Ukrainian request without dropping Nova-3 fixtures.

The PR records the final verified source/tree, full `verify:push` receipt and
offline replay of the previously retained real stereo response. No new provider
request, installed-app update, deployment or main merge is implied by local tests.
Deployed smoke, new hosted one-/three-hour runs and installed group-call evaluation
remain separate acceptance boundaries.

Primary provider references: [multichannel transcription](https://www.assemblyai.com/docs/pre-recorded-audio/transcribe-multiple-audio-channels),
[submission API](https://www.assemblyai.com/docs/pre-recorded-audio/api-reference/transcripts/submit),
[listing API](https://www.assemblyai.com/docs/pre-recorded-audio/api-reference/transcripts/list),
and [retention and model training](https://www.assemblyai.com/docs/concepts/data-retention-and-model-training).
