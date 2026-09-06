# Cloudflare-hosted Nova-3 research for issue #13

Checked on 2026-09-06. This note covers only Cloudflare-hosted
`@cf/deepgram/nova-3`. No provider request or cloud mutation was made during
this research. Product requirements come from the approved
[#10 specification](https://github.com/apshenichniy/trigo/issues/10) and the
narrow [#13 integration gate](https://github.com/apshenichniy/trigo/issues/13).

## Executive finding

The public contract is sufficient to build a short-input probe, but it is not
sufficient to freeze Trigo's long-call media profile:

- Cloudflare publishes synchronous Workers binding and REST transports, an
  asynchronous Batch queue, and a real-time WebSocket transport for Nova-3.
  [Model catalog](https://developers.cloudflare.com/workers-ai/models/nova-3/)
- The Batch queue cannot yet be accepted as Trigo's one- or three-hour path as
  currently
  documented: the complete batch payload must be below 10 MB, while the model
  has no URL/R2-reference input. The current Cloudflare adapter base64-encodes
  audio in binding requests, reducing the usable raw-audio budget further.
  [Batch limit](https://developers.cloudflare.com/workers-ai/features/batch-api/)
  [model input schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L46-L64)
  [official adapter](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/workersai-transcription-model.ts#L166-L197)
- Regular HTTP has no published Nova-3 byte or audio-duration maximum. A generic
  Workers AI `413` exists, but Cloudflare does not publish the numeric threshold
  for this model. Therefore a full-length request, a segmented request, and a
  zero-copy R2-to-AI request are all unproven until the dev probe runs.
  [Workers AI errors](https://developers.cloudflare.com/workers-ai/platform/errors/)
- The catalog promises diarization, but its published output schema omits the
  speaker field. It also does not define the scope of speaker numbers across
  channels or separate inference calls. The real response must be retained and
  inspected before normalization is frozen.
  [input options](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L93-L100)
  [output schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L233-L281)
- Cloudflare explicitly includes English and Russian among the languages for
  its real-time Nova-3 path. It does not publish an HTTP/Batch language list,
  and its explicit real-time list does not include Ukrainian. English, Russian,
  and Ukrainian must therefore all be exercised on the actual HTTP path;
  Ukrainian remains a concrete unresolved gate.
  [Cloudflare Nova-3 language changelog](https://developers.cloudflare.com/workers-ai/changelog/#2026-03-06)

No codec/container/sample-rate combination should be described as accepted from
documentation alone. A conservative probe should start with self-describing WAV
or FLAC and then test a compressed Opus container for the long-input path.

## Authoritative request contracts

### Workers binding

The generic binding method is `await env.AI.run(model, input, options)`.
[Workers AI binding](https://developers.cloudflare.com/workers-ai/configuration/bindings/#async-envairun)
For Nova-3, Cloudflare's current first-party adapter implements this request:

```ts
await env.AI.run("@cf/deepgram/nova-3", {
  audio: {
    body: base64Audio,
    contentType: mediaType,
  },
});
```

That implementation is pinned here:
[binding implementation](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/workersai-transcription-model.ts#L166-L180).
The catalog schema says `audio.body` and `audio.contentType` are required, but
types `body` only as an unspecified object; the adapter's base64 string is more
specific current first-party implementation evidence, not a promise that every
other body representation works.
[catalog schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L46-L64)

The model schema also accepts the following relevant top-level options:

| Concern            | Published option and semantics                                                          |
| ------------------ | --------------------------------------------------------------------------------------- |
| Codec              | `encoding`: `linear16`, `flac`, `mulaw`, `amr-nb`, `amr-wb`, `opus`, `speex`, or `g729` |
| Input channels     | `channels`: numeric channel count                                                       |
| Channel separation | `multichannel`: transcribe each channel independently                                   |
| Speaker changes    | `diarize`: assign each word a speaker number starting at zero                           |
| Language           | `language`: a BCP-47 hint; availability depends on model and endpoint                   |
| Detection          | `detect_language`: detect the dominant language                                         |
| Formatting         | `smart_format`, `punctuate`, `numerals`, and `measurements` are independent booleans    |
| Segmentation       | `utterances`: semantic units; `utt_split`: pause duration in seconds                    |

These fields and descriptions come directly from the
[pinned model schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L93-L226).
The schema does not publish defaults for these options. Trigo must send every
option whose behavior matters and record the effective option set.

### Regular REST

Cloudflare's first-party adapter sends Nova-3 audio as raw bytes, not JSON:

```http
POST /client/v4/accounts/{account_id}/ai/run/@cf/deepgram/nova-3 HTTP/1.1
Authorization: Bearer {api_token}
Content-Type: {audio MIME type}

{raw audio bytes}
```

The implementation and exact endpoint are in the
[pinned binary REST helper](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/utils.ts#L230-L276).
The Cloudflare API's generic route is also documented as
`POST /accounts/{account_id}/ai/run/{model_name}`.
[REST API reference](https://developers.cloudflare.com/api/resources/ai/methods/run/)

The REST response uses Cloudflare's usual envelope, with the model value under
`result`; the first-party helper unwraps `result` and defensively accepts a bare
model response.
[binary REST helper](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/utils.ts#L250-L276)

```ts
type RestEnvelope = {
  result: Nova3Result;
  success: boolean;
  errors: unknown[];
  messages: unknown[];
};
```

The current helper provides no way to send Nova-3 options alongside the binary
body. The public model page also does not explain whether REST options belong in
query parameters, headers, or another envelope. Direct REST with `language`,
`diarize`, `multichannel`, or `smart_format` is therefore unresolved and must be
probed; the binding path has the only fully composed documented input object.

### Published model-result body

The catalog documents this model result structure:

```ts
type Nova3Result = {
  results?: {
    channels?: Array<{
      alternatives?: Array<{
        confidence?: number;
        transcript?: string;
        words?: Array<{
          confidence?: number;
          start?: number;
          end?: number;
          word?: string;
        }>;
      }>;
    }>;
    summary?: { result?: string; short?: string };
    sentiments?: unknown;
  };
};
```

The schema does not mark the nested fields required and does not close objects
against additional fields.
[raw output schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L233-L335)
Cloudflare's adapter reads only the first channel/alternative and maps each
word's `start` and `end` directly to seconds, confirming the documented numeric
values are interpreted as seconds by current first-party code.
[normalizer](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/workersai-transcription-model.ts#L200-L234)

For Trigo, the first-party adapter is not sufficient: it discards all channels,
speaker data, word confidence, provider metadata, language, and duration except
the first channel's text and timing. Trigo must validate and retain the raw
model result before producing its normalized revision.

## Transport and recoverability

| Transport          | Submission                                                                                | Result and recovery                                                                                                                                                                                      | Suitability for issue #13                                                                                                                |
| ------------------ | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Binding, regular   | `AI.run(model, modelInput)`                                                               | The invocation waits for the model result; no provider job ID or lookup operation is documented.                                                                                                         | Short control requests; long-input size and memory behavior unproven.                                                                    |
| REST, regular      | Raw audio POST to `/ai/run/@cf/deepgram/nova-3`                                           | One HTTP response; no provider job ID or lookup operation is documented.                                                                                                                                 | Potential binary/streaming path, but model options, maximum size, and R2 stream forwarding are unproven.                                 |
| Asynchronous Batch | `AI.run(model, { requests: [...] }, { queueRequest: true })` or REST `?queueRequest=true` | Immediate `{status:"queued",request_id,model}`; poll with `AI.run(model,{request_id})` or POST the same REST endpoint with `{request_id}`. Polling reports `queued` or `running`, then a response array. | Recoverable only after `request_id` is durably recorded; the payload is below 10 MB and the Nova-specific batch body is not exemplified. |
| WebSocket          | AI Gateway Workers-AI WebSocket with model/options in the query, then binary audio frames | Real-time messages expose `channel.alternatives[0].transcript` and `is_final`; no reconnect/resume or post-recording result lookup is documented.                                                        | Not the selected post-recording route; useful only as a transport comparison.                                                            |

The generic Batch request, acknowledgement, polling, and completed response
shapes are documented for the
[binding](https://developers.cloudflare.com/workers-ai/features/batch-api/workers-binding/)
and [REST API](https://developers.cloudflare.com/workers-ai/features/batch-api/rest-api/).
Nova-3 is marked `async_queue: true` in its
[catalog record](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L13-L17).
The real-time endpoint and event example are documented by
[Cloudflare AI Gateway](https://developers.cloudflare.com/ai-gateway/usage/websockets-api/realtime-api/#deepgram-workers-ai).
Its exact demonstrated URL is:

```text
wss://gateway.ai.cloudflare.com/v1/<account_id>/<gateway>/workers-ai?model=@cf/deepgram/nova-3&encoding=linear16&sample_rate=16000&interim_results=true
```

The example authenticates with the `cf-aig-authorization` request header, sends
binary microphone frames, and reads JSON messages. This is the AI Gateway
WebSocket path; it does not establish the regular HTTP or Batch contracts.

Batch `external_reference` is a caller-provided correlation value returned in a
completed response; it is not an audio URL or a job lookup key.
[Batch REST request and response](https://developers.cloudflare.com/workers-ai/features/batch-api/rest-api/)
Cloudflare documents no idempotency key, client-selected `request_id`, job list,
or lookup by `external_reference`. If the acknowledgement is lost, the caller
cannot distinguish "not submitted" from "queued but request ID unknown" using
the published API. Retrying can therefore duplicate work and spend. Trigo must
persist admission before submission, classify a lost acknowledgement as an
uncertain attempt, and not automatically resubmit beyond its explicit attempt
budget.

Cloudflare says the Batch queue will eventually fulfill capacity-delayed work,
but does not publish queue/result retention, terminal error response fields, a
poll deadline, or cancellation semantics.
[Batch overview](https://developers.cloudflare.com/workers-ai/features/batch-api/)

## Media formats and numeric size implications

### What Cloudflare actually publishes

- The codec enum is limited to `linear16`, `flac`, `mulaw`, `amr-nb`, `amr-wb`,
  `opus`, `speex`, and `g729`.
  [Model schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L105-L118)
- The input carries a free-form `contentType`, but Cloudflare publishes no
  container/MIME allowlist and no file-extension contract for Nova-3.
  [Audio input schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L46-L64)
- The HTTP/Batch schema has no `sample_rate` field and publishes no accepted
  sample-rate range. Cloudflare's real-time example uses raw `linear16`,
  `sample_rate=16000`, and one microphone channel, but that is evidence only for
  the demonstrated WebSocket path.
  [WebSocket example](https://developers.cloudflare.com/ai-gateway/usage/websockets-api/realtime-api/#deepgram-workers-ai)
- The first-party adapter takes an arbitrary MIME string and its Nova comment
  gives `audio/wav` as the example MIME type. That makes WAV the best documented
  control fixture, not a complete hosted-format guarantee.
  [REST helper](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/utils.ts#L230-L258)
- Workers AI publishes a generic `413 / 3006 Request too large` error, but no
  numeric Nova-3 regular-request limit or maximum audio duration.
  [Workers AI errors](https://developers.cloudflare.com/workers-ai/platform/errors/)
- Automatic Speech Recognition is rate-limited to 720 requests per minute by
  task type; this is a request-rate limit, not a file-size or duration promise.
  [Workers AI limits](https://developers.cloudflare.com/workers-ai/platform/limits/#automatic-speech-recognition)

### Batch ceiling

Cloudflare requires the **entire** Batch payload to be below 10 MB.
[Batch overview](https://developers.cloudflare.com/workers-ai/features/batch-api/)
Because the current binding adapter sends base64, 10,000,000 payload bytes can
carry less than 7,500,000 raw audio bytes after base64 expansion, before JSON
overhead. This follows from the adapter's
[base64 request](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/workersai-transcription-model.ts#L166-L180)
and the standard 4:3 base64 expansion.

For a diagnostic `linear16` mono fixture at 16 kHz and 16 bits/sample:

| Duration | Raw bytes per track | Approximate MiB per track |
| -------- | ------------------: | ------------------------: |
| 1 hour   |         115,200,000 |                     109.9 |
| 3 hours  |         345,600,000 |                     329.6 |

These are arithmetic consequences of `16,000 samples/s * 2 bytes/sample`;
container headers are excluded. A base64 Batch payload would fit less than
approximately 234 seconds of this PCM before JSON overhead. A one-hour payload
would need an average encoded rate below about 16.7 kbit/s, and a three-hour
payload below about 5.6 kbit/s, merely to fit the Batch envelope. Those rates do
not establish transcription quality or a supported Opus container.

The selected 60-second stereo WAV `s16le`/16 kHz probe contains 3,840,000 raw
PCM bytes (`16,000 * 2 bytes * 2 channels * 60 seconds`) and approximately
5,120,000 base64 bytes before the WAV header and JSON overhead. It therefore
fits the documented Batch envelope by arithmetic and is suitable as a short
contract probe; that does not establish support for the one- or three-hour
production path.

The ordinary inbound Worker request limit is 100 MB on Free/Pro, 200 MB on
Business, and up to 5 GB self-service on Enterprise. These are account-plan
HTTP ingress limits and **must not** be presented as the Workers AI model limit.
[Workers request limits](https://developers.cloudflare.com/workers/platform/limits/#request-and-response-limits)

### External Deepgram is not hosted-path evidence

Deepgram's own API documentation currently lists more than 100 media formats,
a 2 GB prerecorded-file maximum, specific sample-rate rules, and Ukrainian
Nova-3 support.
[Deepgram formats](https://developers.deepgram.com/docs/supported-audio-formats)
[Deepgram direct-API limits](https://developers.deepgram.com/docs/pre-recorded-audio#limits)
[Deepgram sample rate](https://developers.deepgram.com/docs/sample-rate)
[Deepgram languages](https://developers.deepgram.com/docs/models-languages-overview/#nova-3)
Those are contracts for `api.deepgram.com`, not for Cloudflare's
`@cf/deepgram/nova-3`. They may justify which fixtures to try, but they do not
prove any Cloudflare container, sample rate, duration, response field, language,
or recovery behavior. No request may be sent to the external Deepgram API for
this issue.

## Timestamps, channels, speakers, and formatting

| Requirement      | Confirmed Cloudflare evidence                                                                                                                                                                                                                                                                                                                                                                                                                       | Unresolved point                                                                                                                           |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Word timestamps  | Each alternative can contain words with numeric `start` and `end`; Cloudflare's adapter interprets them as seconds. [schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L245-L277) [adapter](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/workersai-transcription-model.ts#L200-L228) | Precision, monotonicity, initial-silence behavior, and end-boundary behavior need fixture evidence.                                        |
| Channels         | Output is `results.channels[]`; `channels` and `multichannel` are accepted inputs. [input](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L156-L159) [output](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L237-L281)                                               | No channel-index field or array-order guarantee is published. Mapping channel position to Trigo `trackId` must be verified, never guessed. |
| Diarization      | `diarize=true` promises a zero-based speaker number on each word. [input description](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L93-L100)                                                                                                                                                                                                               | The published output word schema has no speaker property. Scope across channels, chunks, and retries is undocumented.                      |
| Utterances       | `utterances=true` and `utt_split` are published inputs. [input description](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L196-L207)                                                                                                                                                                                                                        | The output schema publishes no utterance array.                                                                                            |
| Smart formatting | `smart_format`, `punctuate`, `numerals`, and `measurements` are published inputs. [input description](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L139-L142) [format options](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L160-L195)                            | Defaults, word/token punctuation shape, and interaction with timestamps are undocumented.                                                  |

Trigo must scope every returned speaker label to `(trackId,
diarizationOperationId)` even if the provider returns the same number on another
channel or request. That is a product invariant required because Cloudflare does
not publish a stronger cross-request identity contract.
[#10 transcript contract](https://github.com/apshenichniy/trigo/issues/10)

## Language status

| Language  | Cloudflare-hosted evidence                                                                                                                                                                                                                                                                                                                                    | Issue #13 status                                                                                                                             |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| English   | Cloudflare's explicit 10-language **real-time** Nova-3 list includes English. [changelog](https://developers.cloudflare.com/workers-ai/changelog/#2026-03-06)                                                                                                                                                                                                 | HTTP/Batch still requires a controlled `language=en` probe.                                                                                  |
| Russian   | The same real-time list includes Russian. [changelog](https://developers.cloudflare.com/workers-ai/changelog/#2026-03-06)                                                                                                                                                                                                                                     | HTTP/Batch still requires a controlled `language=ru` probe.                                                                                  |
| Ukrainian | Ukrainian is absent from Cloudflare's explicit real-time list, while the generic model schema has no language enum. [changelog](https://developers.cloudflare.com/workers-ai/changelog/#2026-03-06) [schema](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L135-L138) | Unavailable or available is not established. A successful hosted `language=uk` probe is required; external Deepgram support is insufficient. |

`detect_language` identifies a dominant language according to the model schema,
but the published output does not include a detected-language field. Explicit
language probes are therefore needed in addition to detection.
[input](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L89-L100)
[output](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L233-L335)

## Private R2 to Workers AI path

The following is the narrow implementation path implied by the R2 and Workers
AI binding contracts. It is an inference, not a documented direct R2-to-AI
primitive:

```text
private R2 object
  -> R2 binding get(key)
  -> Worker validates object metadata and reads body
  -> Nova-3 AI binding or binary REST submission
  -> Worker validates and normalizes raw result
  -> R2 binding put(resultKey, immutable JSON bytes)
```

An R2 binding's `get()` returns object metadata plus a body `ReadableStream` and
also exposes `arrayBuffer()`, `blob()`, `text()`, and `json()` materializers.
`put()` accepts streams or byte containers, and successful writes are strongly
consistent.
[R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/#bucket-method-definitions)
[R2 object body](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/#r2objectbody-definition)

Nova-3's hosted input schema has no URL or R2-object reference. Batch
`external_reference` is only response correlation. Therefore a public bucket or
presigned URL is not part of the documented binding path; a private R2 object
must be turned into request body data inside the Worker.
[Nova input](https://github.com/cloudflare/cloudflare-docs/blob/db48c60f88614974d19b37dcd97d22502260540d/src/content/workers-ai-models/nova-3.json#L46-L64)
[Batch REST API](https://developers.cloudflare.com/workers-ai/features/batch-api/rest-api/)

No official Nova-3 example proves that `R2ObjectBody.body` can be passed directly
to `audio.body`. Cloudflare's current adapter instead starts with a `Uint8Array`
and base64-encodes the binding request; `arrayBuffer()` likewise materializes the
whole object. A zero-copy R2-to-AI stream and its backpressure behavior are
unresolved.
[adapter](https://github.com/cloudflare/ai/blob/7a6f8ddac6c38483da023201303b53d10c266860/packages/workers-ai-provider/src/workersai-transcription-model.ts#L166-L197)
[R2 body](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/#r2objectbody-definition)

Cloudflare treats audio inputs and generated outputs as Customer Content, does
not make them available to other customers, and says it does not use them to
train or improve models/services without explicit consent; storage occurs when
the customer deliberately combines Workers AI with R2 or another storage
service.
[Workers AI data usage](https://developers.cloudflare.com/workers-ai/platform/data-usage/)

## Worker and Workflow limits relevant to long audio

| Limit                             |                          Current published value | Consequence                                                                                                                                                                                                                    |
| --------------------------------- | -----------------------------------------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Worker isolate memory             |                                           128 MB | A one-hour 16 kHz mono PCM track is already about 110 MiB before base64 and object copies; whole-file buffering is unsafe. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/#memory)                 |
| Paid Worker HTTP CPU              |              30 s default, configurable to 5 min | Waiting for network/storage does not consume CPU, but base64 conversion, hashing, decoding, and normalization do. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/#cpu-time)                        |
| HTTP wall time                    | No hard limit while the client remains connected | Disconnect or response completion can cancel outstanding work; `waitUntil()` adds at most 30 s. This is not durable ASR orchestration. [Workers duration](https://developers.cloudflare.com/workers/platform/limits/#duration) |
| Paid Worker subrequests           |    10,000 default, configurable up to 10 million | R2, fetch, and other Cloudflare-service operations share the invocation budget; a bounded assembly must count calls. [Workers subrequests](https://developers.cloudflare.com/workers/platform/limits/#subrequests)             |
| Workflow step wall time           |                                        Unlimited | A step may wait for inference/polling, subject to CPU and step/result limits. [Workflow limits](https://developers.cloudflare.com/workflows/reference/limits/)                                                                 |
| Workflow step CPU                 |              30 s default, configurable to 5 min | Large in-memory transforms remain risky even though I/O wait is free. [Workflow limits](https://developers.cloudflare.com/workflows/reference/limits/)                                                                         |
| Non-stream step result            |                                            1 MiB | Persist raw/normalized transcript artifacts in R2 and return references, not full results, from ordinary steps. [Workflow limits](https://developers.cloudflare.com/workflows/reference/limits/)                               |
| Event payload                     |                                            1 MiB | Workflow input must carry object identity/metadata, never audio bytes. [Workflow limits](https://developers.cloudflare.com/workflows/reference/limits/)                                                                        |
| Persisted state per paid instance |                                             1 GB | Cloudflare still recommends external storage such as R2 for very large or long-lived artifacts. [Workflow limits](https://developers.cloudflare.com/workflows/reference/limits/)                                               |

Workflow steps are individually retryable, and Cloudflare's default is five
attempts with exponential backoff and a ten-minute timeout. That default must be
overridden for paid ASR because the product allows only the original attempt
plus one automatic replacement. Side-effecting calls belong inside idempotent
steps, but a step retry does not make an external inference idempotent.
[Workflow retry defaults](https://developers.cloudflare.com/workflows/build/sleeping-and-retrying/#retry-steps)
[Workflow side-effect rules](https://developers.cloudflare.com/workflows/build/rules-of-workflows/#ensure-apibinding-calls-are-idempotent)
[#10 attempt policy](https://github.com/apshenichniy/trigo/issues/10)

## Pricing and billing unit

Cloudflare publishes transport-specific prices:

| Nova-3 transport |                             Price |                       Neurons |
| ---------------- | --------------------------------: | ----------------------------: |
| Regular HTTP     | USD 0.0052 per input audio minute | 472.73 per input audio minute |
| WebSocket        | USD 0.0092 per input audio minute | 836.36 per input audio minute |

[Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/#audio-model-pricing)

At the published regular-HTTP unit, one mono one-hour track is USD 0.312 and one
mono three-hour track is USD 0.936. Processing Trigo's two tracks as two separate
requests would arithmetically double those figures to USD 0.624 and USD 1.872.
Cloudflare does not document whether a multichannel minute is billed once per
container minute or once per channel, nor whether asynchronous Batch has a
different rate from regular HTTP; both must be measured rather than inferred.

Workers AI has a 10,000-Neuron daily free allocation and bills usage above it at
USD 0.011 per 1,000 Neurons on Workers Paid. Cloudflare says usage is visible in
the Workers AI dashboard and resets daily at 00:00 UTC.
[Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
At 472.73 neurons/minute, the allocation corresponds arithmetically to about
21.15 regular-HTTP Nova-3 audio minutes if no other model consumes it that day;
this is not a provider-enforced budget for issue #13.

Each paid probe set should record before/after Workers AI usage, request IDs,
audio duration, channel count, transport, and the observed billing delta. An
uncertain acknowledgement reserves the worst-case spend until billing evidence
or a recoverable result settles it.

## Required dev probe matrix

The following observations are still necessary before issue #13 can select a
media profile or claim the hosted path:

1. **Short control inputs.** Submit self-describing mono WAV/linear16 fixtures
   through the binding with explicit `diarize`, `multichannel`, `language`,
   `smart_format`, and `punctuate`; retain the complete raw response.
2. **Language.** Run controlled English, Russian, and Ukrainian fixtures through
   the same regular HTTP path. Do not accept detection-only output as proof of
   the explicit language option.
3. **Sources and speakers.** Use two known logical sources with silence/gaps and
   multiple voices. Compare two independent mono requests with one two-channel
   request, but never merge equal speaker numbers across track/channel/request
   scopes.
4. **Format candidates.** Use WAV as the documented control, then test FLAC and
   Ogg/Opus candidates separately. Record content type, codec, container,
   channels, sample rate, exact bytes, decoded duration, and playback validation.
   An encoding enum alone does not prove the container.
5. **Batch mechanics.** Confirm the Nova-specific `requests[]` body, queue
   acknowledgement, polling states, final result envelope, errors, and result
   retention with a short fixture. Treat deliberate lost acknowledgement as a
   possibly billed attempt; do not blindly resubmit.
6. **Long input.** Exercise the chosen actual hosted transport with synthetic
   one-hour and three-hour inputs whose known speech markers appear near the
   start, middle, and end. Record request size, latency stages, provider IDs,
   complete timestamp range, channel/source mapping, and billing.
7. **Failure boundary.** Probe one controlled over-limit request only after its
   cost reservation. Record HTTP/internal error code, whether any request ID was
   issued, and whether usage was charged.
8. **Private persistence.** Read input only through the private dev R2 binding,
   validate/hash it, and write both immutable raw and normalized results back to
   private dev R2 before acknowledging success.

These probes remain restricted to the isolated dev target and controlled
synthetic non-private fixtures; the external Deepgram API is outside the
authorized boundary.
[#13 authorization](https://github.com/apshenichniy/trigo/issues/13#issuecomment-5555170969)

Until these probes pass, the accurate design statement is: **short hosted
Nova-3 inference is documentable; the one- and three-hour transport, accepted
container/sample rate, recoverable submission path, speaker field/scope, Batch
language coverage, and Ukrainian availability are unresolved.**
