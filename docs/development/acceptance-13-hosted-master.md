# Issue #13 hosted master acceptance

The current [#13](https://github.com/apshenichniy/trigo/issues/13) controlled
Cloudflare-hosted gate passed on **2026-09-08**: English, Russian, silence,
multi-voice/source evidence, independent submission scopes, and complete one- and
three-hour retained masters. The selected maximum submission is **two hours**.
The Ukrainian check produced an explicit hosted model/language/tier rejection.
This is the implementation handoff for #18, not acceptance of real-call ASR
quality or the complete desktop release.

The [profile and integration contract](asr-submission-profile.md) defines the
production-facing boundaries. The [machine-readable evidence](acceptance-13-hosted-master.json)
records identities, hashes, sizes, timings and qualifications without publishing
audio, raw transcripts or credentials. The older
[capture-profile checkpoint](acceptance-13.md) remains historical evidence.

## Source and actual API

All long-call proof used deployed source
[`860f491af6959b31acce3c21a90cc2e1d866148e`](https://github.com/apshenichniy/trigo/commit/860f491af6959b31acce3c21a90cc2e1d866148e)
on the authorized dev Worker `trigo-dev-api`, private R2 and its existing owner
authentication. The retained #29 R2/D1 fixture was verified after each deployment.
No personal deployment or production workflow was started by this work.

The earlier binary control proved the current
[workerd stream route](https://github.com/cloudflare/workerd/blob/b3b584c2680f60dfa8b2c4978b98a06ec0f61340/src/cloudflare/internal/ai-api.ts):
`audio.body` must be an actual `ReadableStream`. The binding sends its bytes on
the binary path while forwarding model options separately. This avoids the
historical JSON/base64 `5006` failure without creating a broader account API key.
The 18-second, 1,152,044-byte control returned HTTP 200, request
`06e3b3f5-4505-4c0c-9f51-c940b215169f`, raw SHA-256
`8629f3756f7cc5993c38d06c96b3388b9c99c3b6921e1c19c47c1592f75f1d95`
and 141.819 neurons.

The language and multi-request controls used source
[`dab8f86296f447ee10175dcb44c5b37bf2273766`](https://github.com/apshenichniy/trigo/commit/dab8f86296f447ee10175dcb44c5b37bf2273766).
They retained complete extraction hashes and all expected speech events, but did
not separately instrument consumer EOF. Their evidence stays qualified as
`legacy-producer-hash-v1`. The one-/three-hour success has the later strict EOF
witness for every submitted interval. No old receipt was rewritten to imply a
measurement it did not make.

Final local changes codify the two-hour interval, add shared Swift/TypeScript
conformance and the independently reviewed evidence checker, and raise the
adapter's local raw-response retention bound from 4,000,000 to 8,000,000 bytes.
The larger response bound is checked locally; the observed hosted results fit the
earlier bound. Audio bytes, model options, range size, stream ownership and EOF
semantics of the accepted long-call inputs are unchanged. The final PR checks
cover this candidate; no unchanged paid proof is rerun solely for documentation
or the larger local response guard.

## Complete masters and observed cutoff

| Observation                        |        WAVE input | Provider result            | Coverage                                                  |
| ---------------------------------- | ----------------: | -------------------------- | --------------------------------------------------------- |
| Separate one-hour master           | 230,400,044 bytes | HTTP 200, consumer EOF     | All 540 source events and 5,220 words                     |
| Three-hour master, one request     | 691,200,044 bytes | HTTP 200, incomplete input | Rejected; only 512 MiB PCM consumed, final markers absent |
| Three-hour master, first two hours | 460,800,044 bytes | HTTP 200, consumer EOF     | Complete `[0, 7,200,000)` ms                              |
| Same master, final hour            | 230,400,044 bytes | HTTP 200, consumer EOF     | Complete `[7,200,000, 10,800,000)` ms                     |

The complete three-hour CAF is 691,200,068 bytes, SHA-256
`4bcd43883c0465a39d0a57dad1171b261021dddab44453fea287275bb550865a`.
Both the rejected single request and accepted two-request plan derive from those
same bytes. The successful result contains **all 1,620 known source events and
15,660 words**, including the unique middle/final markers and both sides of the
two-hour boundary. The final application-channel word ends at 10,796,315 ms;
the remaining tail is controlled silence and was delivered through EOF.

Accepted request IDs are `8070adbc-62fb-4b95-a5d3-47908c7f3505` and
`8f6910a8-365d-4148-a954-f28b28fdb520`. Their raw bodies total 3,267,723 bytes.
The 1,449,954-byte normalized revision has SHA-256
`836436b76dfcf8a44754b9f002144f666f9bf3e51fab51c6e3c930b7d6a29036`.
It retains six speaker IDs and four independent submission/channel scopes. The
same physical remote voices appearing in both requests are intentionally
fragmented; equal numeric provider labels are not merged automatically.

The negative three-hour request
`7968bef5-04c4-47dd-a935-3e41b61ad56f` returned a complete HTTP response after
only 536,870,956 delivered bytes: 44 header bytes plus exactly 512 MiB PCM.
Word output ends around 8,389 seconds and contains no final Charlie marker.
Its retained raw SHA-256 is
`150207c844c008fb89d3eedb0ebbd40a250eb4b6b30111e3ba3fc40e23170c92`.
The normalization endpoint returned 409 and created no successful revision.
This confirms why status 200 and a producer hash alone are insufficient. It is
an observed boundary, not a claim that every model deployment has a universal
512-MiB limit.

The range source never reads more than 2 MiB at once, checks the immutable CAF
header/object size and fences subsequent reads with the observed ETag. The
independent checker reconstructs every master/input hash from the bounded
template, then verifies interval continuity, raw bytes, strict EOF metadata,
language/revision references, exact canonical text/word fields and speaker scope
bijections. Live success occurred within the platform's
[128-MB Worker memory limit](https://developers.cloudflare.com/workers/platform/limits/);
no hosted peak-RSS measurement is claimed. Local tests prove bounded reads and
consumer cancellation, including the prefetched-final-chunk race.

## Language, timing and quality qualifications

The English template uses three installed synthetic voices: Samantha on the
microphone channel and Daniel/Karen on the application channel. Its separate
120-second master was submitted as two independent 60-second inputs, producing
all 18 expected source events, 174 words, six speakers and four scopes. The
longer fixtures reuse these voices with distinctive middle/final blocks.

The Russian 60-second control produced all nine source events and 72 words on
both channels. It uses one installed Russian voice, so English supplies the
same-channel multi-voice evidence. The silence control returned two explicit
empty channel alternatives and normalized to zero words, turns and speakers.

English event start/end errors were at most 150/338.5 ms in the one-/three-hour
proof. Russian event-edge errors reached about 1.014 seconds, with nine words
outside the corresponding speech window expanded by 500 ms. All returned
timestamps are retained exactly apart from documented integer-millisecond
conversion. Provider timestamp accuracy is separate from frame alignment and
capture clock drift; these controls do not establish real technical-speech WER.

Both Ukrainian attempts used the same 3,840,044 WAVE bytes, SHA-256
`614acec873b43e19d0ef4aee539c6c3448d36b8e5b10a6d8519832e16c3d7890`:

| Attempt                   | Request                                | HTTP/code  | Exact description                                             |
| ------------------------- | -------------------------------------- | ---------- | ------------------------------------------------------------- |
| Original                  | `edc02dd9-2164-4ca8-ad78-03aba3efd418` | 400 / 8007 | `Failed to handle request.`                                   |
| One owner-directed repeat | `f9b8e222-aec7-42c2-af33-da3c3de51101` | 400 / 8007 | `Bad Request: No such model/language/tier combination found.` |

The repeat changed stream instrumentation/cleanup and range size, as recorded in
the [reservation](https://github.com/apshenichniy/trigo/issues/13#issuecomment-5585595354),
but preserved the audio/model options. It delivered all input bytes through EOF.
Neither failure returned usage. The second result establishes rejection of this
tested combination; it does not disclose the first failure's cause or establish
support in another provider endpoint. The
[current model documentation](https://developers.cloudflare.com/workers-ai/models/nova-3/)
does not publish an exhaustive language enum. The
[Workers AI changelog](https://developers.cloudflare.com/workers-ai/changelog/)
lists ten real-time languages without Ukrainian; that is supporting context,
not a substitute for this HTTP observation. Optional Ukrainian support is not
silently treated as successful. Separately authorized direct-provider research
does not replace Cloudflare evidence or change this adapter.

## Recovery and latency

Live repeated POSTs for both accepted three-hour submissions returned identical
request IDs and receipt bytes. Repeating normalization returned the exact same
1,449,954 bytes and hash in 413 ms, without another provider admission. The raw
artifacts are private, immutable and available through authenticated GETs.

Worker tests separately cover concurrent admission, lost acknowledgement,
response-body failure, retained-prefix classification, failed/partial input,
immutable fixture identity and source ETag changes. Unknown provider outcome
remains recoverable/uncertain rather than an automatic fresh paid request.
There is no demonstrated queued binary API or synchronous request-ID polling
endpoint; #18 must use retained raw evidence and its durable attempt policy.

| Measured stage                                 |  One hour | Three hours as two hours + one hour |
| ---------------------------------------------- | --------: | ----------------------------------: |
| Diagnostic retained-master preparation         | 11,921 ms |                           22,568 ms |
| Pre-extraction/hash                            | 26,671 ms |                  53,795 + 26,615 ms |
| Streamed provider call, including its R2 reads | 39,786 ms |                 104,762 + 37,607 ms |
| Complete submission request from client        | 67,880 ms |                 160,350 + 65,716 ms |
| Normalization computation                      |    308 ms |                              312 ms |
| Normalization request from client              |  1,998 ms |                            2,208 ms |

These are observed, overlapping stage measurements, not additive provider-only
compute times or service-level guarantees. Fixture preparation is not production
upload. Upload backlog, Workflow waiting, local import and replica sync belong
to #17/#18 and later integrated Ready-latency acceptance.

## Usage and verification

Returned usage matches the documented HTTP rate of **472.73 neurons per audio
minute** in the complete stereo controls: 472.73 for one minute, 28,363.8 for one
hour and 85,091.4 for the accepted three-hour pair. These observations do not
double the neuron count merely because the input has two channels. Published
HTTP [list pricing](https://developers.cloudflare.com/workers-ai/models/nova-3/)
is USD 0.0052 per audio minute; it is not an observed invoice charge. The safety
ledger deliberately used two-channel counting, EUR 2 per USD,
rounding and setup allowances. Read-only billing access was insufficient and was
not broadened.

The Cloudflare probe scope settled at **EUR 9.70 conservative actual with no
remaining reservation**, inside the existing shared EUR 20 ceiling. The
[settlement](https://github.com/apshenichniy/trigo/issues/13#issuecomment-5585948701)
and subsequent issue comments also reconcile separately owner-authorized
direct-provider research. Those later shared-ledger entries are authoritative
for the cumulative balance; no earlier reservation is retroactively invented.

Local checks before the final PR source:

- Server quick gate: 395 unit tests, 43 Worker tests, types, lint, generated
  contracts and bundles passed; 37.654 seconds for the selected server scope.
- Full macOS gate on `dab8f8629`: all 176 discovered native tests, including
  contention and seven resource groups, nine Swift contract tests, both Debug
  app variants and native/local Worker smoke passed in 557.251 seconds.
- After the final shared conformance fixture: nine Swift contract tests passed;
  the affected native/local Worker smoke passed in 18.367 seconds. Native
  application/resource-test code was unchanged, so its prior full evidence was
  reused for those ASR changes. Final CI selects both complete components and
  tests the candidate integrated with current `main`, including its desktop shell.
- The independent checker has self-contained negative tests for changed master,
  revision, language, turn text, erased speaker attribution, merged scopes and
  contradictory EOF/status/body witnesses.
- Two-axis review found and corrected producer/consumer EOF confusion, stream
  cleanup, partial-response metadata loss and evidence-checker false positives.
  Final Standards and Spec reviews each reported zero unresolved findings.

Tracked implementation and this evidence are committed before the final CI run.
The PR body holds the resulting CI URL, outcomes and source identity. Neither
main merge nor production #18 execution is part of this handoff.
