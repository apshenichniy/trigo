# Durable transcription service

Issue [#18](https://github.com/apshenichniy/trigo/issues/18) consumes the verified
master receipt from #17 and the hosted Nova-3 profile from #13. The shared product
API and Effect services execute in the cloud Workflow and the local fake Workflow.
The local composition never binds Workers AI and marks its evidence as fake.

## Desktop contract

`POST /v1/calls/{callId}/transcriptions` accepts `RequestTranscription`: schema
version 1, independent operation and candidate revision UUIDs, the requested
language, and `nova3-wav-s16le-16000-stereo-stream-v1`. English and Russian use the
proven profile. Ukrainian is structurally understood but rejected with
`asr_language_unsupported` before attempt or provider admission. Unknown execution
options and arbitrary models fail request validation.

The response is a `TranscriptionOperation`. One active logical request is admitted
per call. Repeating identical content with the same identities returns that
operation; a different concurrent request conflicts. The durable desktop owner
must retain those identities across retries.

`GET /v1/operations/{operationId}` reads operation and Workflow status without
starting, restarting or submitting work. The independent states are `queued`,
`running`, `result_available`, and `failed`. A running/queued operation can carry a
recoverable infrastructure failure. For `asr_workflow_interrupted` or transient
storage/status unavailability, retry the original POST with the same command.
The server restarts an errored Workflow under the same identity; its durable
provider admission records prevent duplicate paid submissions. An operator-paused
or terminated Workflow reports `asr_workflow_stopped` and requires administrative
correction. Polling does not override that action.

An available result contains exact revision and provenance byte lengths and
SHA-256 hashes. Fetch the retained bytes through:

- `GET /v1/calls/{callId}/revisions/{revisionId}`
- `GET /v1/calls/{callId}/revisions/{revisionId}/provenance`

The responses are private, authenticated, and `no-store`. Validate the response
identity and exact bytes before canonical import. #19 owns atomic local import and
the independently confirmed server replica. These ASR routes neither mutate the
canonical document nor acknowledge local import or synchronization. A valid
no-speech response produces an empty revision. A verified zero-duration master
produces explicit no-audio provenance without invoking a provider.

## Admission and recovery

The D1 migration `0003_transcriptions.sql` retains operation, attempt, submission,
link and writer records. It stores IDs, hashes, sizes, extraction metadata and
short errors. Audio, provider responses and transcript text live privately in R2;
Workflow step outputs contain only IDs and compact state/error records.

Each logical request admits the original attempt and at most one automatic
replacement. The complete call is planned as the longest proven intervals: up to
two hours per submission, so a three-hour master produces two hours plus one hour.
Each interval/channel has an independent diarization scope. An admitted provider
submission is never sent again. Recovery first checks every retained raw response;
a replacement reuses successful intervals and submits only intervals whose outcome
remains uncertain. Configuration, funds, unsupported input and invalid evidence
require correction instead of an automatic paid replacement.

Workflows disable retries on provider steps. Storage steps have three bounded
retries; interruption after those retries remains visible and can resume through
the original command. D1 admission is authoritative even if Workflow history is
replayed, restarted or loses an acknowledgement. Owner-generation changes, call
deletion fences, a newer operation and a newer attempt prevent new side effects
and publication. A restarted Workflow resolves the latest admitted attempt from
D1 before continuing, even when its platform history was cleared. A queued request
invalidated by owner rotation becomes a visible
failure and releases its active slot.

## Evidence and resource bounds

The extractor reads the immutable CAF master in bounded ranges, preserves both
source channels, verifies the exact retained audio-manifest bytes against the
master receipt, and records source/master hashes, frame ranges, WAV hashes and
call-time offsets. Provider transport must witness consumer EOF for the complete
input and a complete successful response. Reported provider duration and channels
must match the submitted interval before another paid interval is started.

Raw response retention is capped at 8,000,000 bytes per submission and at two
submissions per attempt. An oversized or interrupted response can retain a
diagnostic prefix but cannot publish a transcript. Normalized revision retention
is capped at 16,000,000 bytes and provenance at 65,536 bytes. Neither audio masters
nor responses enter durable Workflow state. The dense-result Worker fixture
normalizes 64,000 words from two multi-megabyte responses through R2.

Raw writers are admitted before paid submission, including an explicit unknown
hash/size until the provider responds. Every external write targets a fresh
immutable key. Lost write acknowledgements reconcile against exact R2 metadata and
hashes. Already-admitted writers may finish after a fence to retain diagnostics;
they cannot publish a stale result. Their admission/uncertainty records remain
enumerable for #22's later deletion/drain implementation. An absent object alone
does not establish that an uncertain writer is drained.

Normalization uses deterministic IDs within the candidate revision. Replay after
immutable writes and before publication produces identical revision bytes.
Provenance and revision writes precede one conditional atomic publication.
Later failed requests and late original responses preserve successful revisions.
Manual names/groups remain outside immutable ASR evidence.

## Verification and hosted boundary

`bun run check:server` runs the structural/semantic corpus and Worker integration
tests. The transcription suites cover duplicate commands, side-effect-free polling,
the real local Workflow, uncertain submissions, raw/storage acknowledgement loss,
restart, owner/deletion/attempt fences, late responses, retained earlier revisions,
empty results, actionable errors, repeated labels across independent intervals and
dense provider bodies. The virtual three-hour fixture exercises production range
extraction while avoiding a large R2 write per test; it is not hosted media proof.

See [the hosted submission profile](asr-submission-profile.md) for #13's retained
long-master provider evidence. A new #18 hosted service probe requires the exact
Dev deployment and paid request set to be authorized separately. Final source,
local/CI results, hosted request identities and accounting are recorded in the PR
handoff. #21's explicit user retry/re-transcribe and #22's user deletion workflow
remain deferred by the first daily-use amendment.

## Prepared hosted service probe

The operator command uses `TRIGO_ASR_OPERATOR_TOKEN` as a redacted environment
input and never discovers desktop credentials. Supply the token without printing
it or saving it in the prepared directory. Prepare separate English and Russian
directories before requesting authorization:

```sh
bun scripts/transcription-service-probe.ts prepare --stage dev \
  --config /absolute/path/to/dev.json --language en \
  --directory /absolute/path/to/prepared-en
```

Preparation reads authenticated status and creates a local synthetic 60-second
stereo master and immutable `plan.json`. It neither uploads nor invokes ASR. The
plan fixes call, upload, finalization, operation and revision identities, the
requested language and exact master hash. Repeating preparation preserves it.

After the exact Dev deployment and paid request set are authorized:

```sh
bun scripts/transcription-service-probe.ts run --stage dev \
  --config /absolute/path/to/dev.json --language en \
  --directory /absolute/path/to/prepared-en --allow-paid
```

Execution uses the production registration, chunk, finalization and transcription
routes; polls the durable operation; repeats its command to verify idempotence;
and checks exact revision/provenance hashes and speech on both source tracks.
It retains the master receipt, operation and returned immutable bytes alongside
the plan. A rerun uses the same identities and refuses to overwrite different
evidence. One directory admits at most an original and one replacement attempt
for its one-minute call. This command selects Dev explicitly and rejects Personal.

The deployment adds D1 tables and indexes through `0003_transcriptions.sql`, keeps
the existing Workflow resource/class name, and raises its step limit for bounded
recovery. It does not rewrite existing archive rows or delete stored objects.
