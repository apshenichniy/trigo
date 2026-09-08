# Hosted Nova-3 master submission profile

Issue [#13](https://github.com/apshenichniy/trigo/issues/13) owns this adapter and
extraction contract. The [hosted acceptance record](acceptance-13-hosted-master.md)
contains the successful one-/three-hour proof and the rejected larger request.
Issue #18 owns production admission, Workflow execution, publication and retries.

## Selected profile

The executable definition is `packages/contracts/src/asr-profile.ts`:

| Property                   | Accepted value                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Profile ID                 | `nova3-wav-s16le-16000-stereo-stream-v1`                                                                                        |
| Model                      | Cloudflare-hosted `@cf/deepgram/nova-3`                                                                                         |
| Submission API             | `AI.run(model, { audio: { body: ReadableStream, contentType: "audio/wav" }, ...options }, { returnRawResponse: true, signal })` |
| Audio                      | 44-byte canonical WAVE header; signed little-endian PCM16, 16 kHz, two interleaved channels                                     |
| Source mapping             | Channel 0: microphone; channel 1: application                                                                                   |
| Options                    | `channels=2`, `multichannel=true`, `diarize=true`, `punctuate=true`, `smart_format=true`; explicit requested language           |
| Maximum selected interval  | 7,200,000 ms / 460,800,044 WAVE bytes                                                                                           |
| Verified language controls | English (`en`) and Russian (`ru`)                                                                                               |
| Ukrainian finding          | The repeated `language=uk` control explicitly returned `No such model/language/tier combination found.`                         |
| Speaker scope              | One independent scope per submission/channel; provider labels are not identities                                                |

Use the longest selected interval that covers the remaining call. A one-hour
master uses one request. A three-hour master uses `[0, 7,200,000)` and
`[7,200,000, 10,800,000)` milliseconds. Each interval has a fresh submission UUID,
distinct from the master UUID and all other submission UUIDs. Recording commit
cadence, upload-part boundaries and ASR intervals are independent.

Do not select a single three-hour request: the live API returned HTTP 200 after
consuming only 512 MiB of PCM, omitted the final markers and failed the complete
input witness. Two hours was subsequently accepted with consumer EOF. The
512-MiB observation is not a published universal model limit or evidence that
every smaller possible size has been tested.

The final adapter limits one retained raw response to 8,000,000 bytes. This is a
local memory guard, not a provider limit. If exceeded, preserve the acknowledged
status, request ID and bounded prefix with `responseBodyComplete=false`; never
normalize that prefix. The controlled probe additionally bounds the combined
raw set at 16,000,000 bytes. Production #18 must retain explicit result-memory
bounds; denser results and larger response shapes are not covered by the measured
3,267,723-byte three-hour result set. No input truncation or automatic paid
resubmission is an acceptable response to either bound.

## Verified storage to input bytes

Resolve the source from #17's server-owned
`storedMaster(db, archiveId, callId)` result. Its `receipt` must be the current
`complete-master-sha256-v1` receipt for a stored, non-deleted master. The returned
`objectKey` is an internal immutable key, not a caller-supplied R2 address. Preserve
the receipt's source-state hash in #18's admission context.

Construct `AsrMaster` using this mapping:

| ASR witness                      | Verified storage receipt                           |
| -------------------------------- | -------------------------------------------------- |
| `callId`, `masterId`             | Same receipt identities                            |
| `manifestId`, `manifestSha256`   | `audioManifest.manifestId`, `audioManifest.sha256` |
| `sha256`                         | `masterSHA256`                                     |
| `frameCount`                     | `durationMs * 16`                                  |
| `byteLength`, `mediaProfileId`   | Same receipt values                                |
| Microphone/application track IDs | Verified channel map, indices 0 and 1              |

Check the exact retained `audioManifest` UTF-8 bytes against the receipt hash;
do not hash a reserialization. The nonempty master witness requires
`byteLength = 68 + frameCount * 4` and distinct source tracks. Headers alone are
not an ASR input; handle an empty recording before provider admission.

`planMasterSubmissions(master, nova3StreamProfile.maxSubmissionDurationMs, makeId)`
creates ordered, gapless frame intervals. The low-level planner also accepts
other durations for capability diagnostics; that is not permission to select an
unproven production interval.

For a half-open interval `[startFrame, endFrame)`, extraction reads:

```text
CAF source bytes: [68 + startFrame * 4, 68 + endFrame * 4)
WAVE bytes:       44 + (endFrame - startFrame) * 4
Call start/end:   startFrame / 16, endFrame / 16 milliseconds
```

`r2MasterSource` validates the complete object length, pins the first observed R2
ETag, and conditions every following read on that version. `extractMasterWave`
validates the native CAF header before producing submission bytes.
The caller must preserve the verified immutable-key and deletion/admission
fences. A multipart ETag is not substituted for the whole-master SHA-256.

`extractMasterWave` copies exact interleaved frames without resampling, mixing,
channel loss or silence removal. Each R2 range is at most 2,097,152 bytes. It
incrementally hashes the complete WAVE output and returns
`AsrExtractionEvidence`: master identity/hash, manifest identity/hash, submission
identity/index, exact frame/time interval, transformation, channel mapping,
input byte count and SHA-256. Its extraction evidence proves produced bytes.
Only the transport's separate consumer-EOF witness proves complete local delivery
to the binding. Streams have a single owner and are cancelled on every early
return, failure or interruption.

The diagnostic pre-extracts and retains input evidence before the paid admission,
then streams a second extraction from the same ETag-pinned source. Even two full
three-hour passes require fewer than 1,000 internal R2 subrequests. Both passes
use bounded ranges; neither buffers the retained master.

## Acknowledgement, raw retention and recovery

The accepted binary request is synchronous. Preserve the exact raw response bytes
and SHA-256, HTTP status, `cf-ai-req-id` when returned, response completeness and
actual delivered byte count before acknowledging success to the caller.

The raw success envelope observed here contains `results` and `usage`. It does
not return Deepgram `metadata.duration`, model version or a provider job handle.
Keep missing metadata null/absent. Do not manufacture a detected language or a
model version from the requested language/model.

The [published Batch binding](https://developers.cloudflare.com/workers-ai/features/batch-api/workers-binding/)
accepts queued JSON envelopes and provides request-ID polling. Its documented
envelope bound and JSON transport are different from this binary stream path.
This work does not claim a queued binary submission, a presigned-URL input, or
that polling an arbitrary synchronous `cf-ai-req-id` recovers its result.

| Durable state                                              | Recovery behavior                                                                              |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Raw success and complete input/response witnesses retained | Read the exact bytes; normalize or recover the retained revision without another provider call |
| HTTP error or incomplete response retained                 | Preserve the evidence and classify the concrete failure; never call it a successful transcript |
| HTTP 200 with incomplete input consumption                 | Reject normalization, including the observed three-hour partial response                       |
| Admission exists, acknowledgement/raw result missing       | Outcome is uncertain; recover retained artifacts first and do not silently submit again        |
| No admission exists                                        | A validated and budget-authorized request may atomically admit one side effect                 |

`submitNova3Stream` retains status/request identity even when body streaming fails.
A failure before acknowledgement remains uncertain because inference may have
been billed. The dev probes atomically create an immutable admission before
calling the provider and check raw/admission state on every replay. They have no
delete-to-retry operation.

Production #18 must persist command, candidate revision and attempt identities,
apply the original-plus-one-replacement budget across restarts, disable provider
side-effect retries in Workflow defaults, fence late/deleted/superseded work and
own final publication. A foreground request or `waitUntil` is not that durable
orchestrator. Recovery of retained evidence is distinct from a newly authorized
paid attempt. Configuration, funds and unsupported-input failures require
correction.

## Normalization and publication boundary

`normalizeNova3Master` accepts the verified master, ordered submissions with exact
raw bytes/artifact keys and extraction/transport witnesses, a revision identity,
timestamp, requested language and UUID factory. It checks complete frame coverage,
master equality, unique submission identities/artifacts, two-channel responses,
and any returned provider duration before using the existing word normalizer.

Word times are converted to integer milliseconds and offset by the exact interval
start. Punctuation, confidence and provider labels are preserved. Missing speaker
labels stay unknown. The revision and the separate provenance sidecar retain raw
hashes, request IDs, optional provider metadata and transformation evidence.
They do not merge equal labels across submissions or channels. Owner-approved
speaker grouping in #46 is a separate annotation concern.

Publication requires `provenance.allConsumerEOFVerified === true`, successful raw
HTTP status and complete responses. Legacy results may be examined using the
explicit `legacy-producer-hash-v1` qualification; omitted witnesses are
`unobserved`. Neither qualification is silently promoted to consumer EOF.
The three-hour success has strict witnesses for both submissions.

The fixture probe derives stable normalization UUIDs from its persisted revision
seed, writes immutable provenance/revision artifacts and returns retained bytes on
replay. #18 must provide the equivalent stable identity and publication behavior.
A valid no-speech response creates an empty transcript, not invented text.

## Controlled reproduction

`scripts/asr-master-fixtures.ts` generates non-private 60-second CAF templates
using installed macOS voices. English has separate Samantha, Daniel and Karen
voices. Russian/Ukrainian use the available Milena/Lesya voice on both source
channels, so those controls do not establish same-channel multi-voice quality.
Three 20-second blocks contain Alpha, Bravo and Charlie markers. Long fixtures
repeat Alpha, place Bravo at the middle block and Charlie at the final block.
The generated metadata records source/voice and known speech windows.

The owner-authenticated dev-only endpoints are
`/__trigo/hosted-asr-probe/:fixture` for the small transport control and
`/__trigo/hosted-master-probe/:fixture` for complete master fixtures. The latter
supports immutable template preparation, one explicit interval POST, status/raw
artifact reads and retained normalization. Production/personal routes remain
separate. Store credentials outside tracked files and routine logs; every new
provider request set needs the continuing authorized ledger reservation.

After retrieving `plan-0.json`, `raw-N.json`, `provenance-0.json` and the exact
`normalize.json`, run the independent checker without another ASR call:

```sh
bun scripts/asr-master-acceptance.ts TEMPLATE.caf.json FIXTURE_DIRECTORY
```

It reconstructs master and interval hashes from the bounded template, checks
language/model/revision references, complete EOF witnesses, every source marker,
exact canonical words/turn text and speaker-scope separation. It assigns words
to source-event slots separated at silence midpoints and reports timing errors;
the 500-ms statistic is not an acceptance threshold or a timestamp correction.
Historical controls require explicit `--allow-legacy` and retain that limitation.
Synthetic controls establish transport/shape/coverage, not real Russian
technical-speech quality or completed desktop Ready latency.
