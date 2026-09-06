# Issue #13 capture-profile checkpoint

This record covers the narrowed capture-build dependency from
[#13](https://github.com/apshenichniy/trigo/issues/13) under the latest owner
correction in [#10](https://github.com/apshenichniy/trigo/issues/10). It accepts
a stable capture/writer profile for issues #15 and #16. It does **not** close the
full Nova-3 integration gate or claim successful hosted transcription.

## Selected capture profile

The shared repository artifact is
`packages/contracts/schema/media-profile.v1.json`, profile
`trigo-call-wav-s16le-16khz-stereo-60s-v1`:

- canonical RIFF/WAVE with a 44-byte header, signed little-endian 16-bit PCM and
  a 16 kHz sample rate;
- two interleaved channels in stable order: channel 0 is microphone and channel
  1 is application audio;
- independently decodable 60-second objects, with a two-second durable writer
  checkpoint cadence and silence representing missing frames;
- ordered-object playback which decodes each WAVE object and mixes its channels
  only at output; retained media and ASR input remain two-source;
- one object per ASR request, object-relative provider timestamps translated to
  the call timeline, and speaker labels scoped to one object/channel operation.

A full 60-second object is 3,840,044 bytes and its base64 representation is
5,120,060 bytes. It remains below the accepted 8 MiB upload request bound and
below Cloudflare Batch's documented 10,000,000-byte envelope before JSON
overhead. A three-hour call is 180 ordered objects; the format itself does not
truncate or accumulate fractional clock drift. This arithmetic establishes
capture/upload compatibility, not a successful Batch submission.

## Deterministic evidence

The TypeScript and Swift contract implementations load the same generated JSON
artifact. Tests prove channel provenance, canonical WAVE creation/inspection,
transport-size arithmetic, one-/three-hour object counts, and exact integer time
conversion. The Nova-3 normalizer additionally proves that:

- channel position maps to the corresponding retained source track;
- initial silence and gaps remain on the common call timeline;
- equal provider speaker labels from different objects or channels are not
  merged;
- missing speaker identity remains null; and
- text without word timing or a response without both channels is rejected.

The owner-authenticated dev-only harness persists its input and either raw result
or provider failure in private R2. A completed attempt marker prevents a
sequential repeat from invoking the provider again; a deliberate retry requires
deleting only that exact task-owned fixture first. The route is unavailable in
the personal stage.

The generated English control file was independently inspected with `ffprobe`:
18.000 seconds, `pcm_s16le`, 16 kHz, two channels and 1,152,044 bytes. Its SHA-256
was `d6dc1328c15ccaf0e702ded53700abc06fce7266dec88fbe66b8745fade4216c`.
English, Russian and Ukrainian controls use only macOS synthetic voices and
non-private marker phrases.

## Deployed Cloudflare evidence — 2026-09-06 UTC

The harness was deployed only to account
`27940cd0d92bb3f03943a5378ccf68d3`, profile `trigo-cloud-dev`, Worker
`trigo-dev-api`. Alchemy updated only the Worker; retained R2, D1 and Workflow
declarations were no-ops. The protected #29 R2/D1 fixture was read successfully
after deployment.

The paid-attempt ledger was reserved before every bounded set. The first set made
exactly three non-retried binding calls, one 18-second fixture for each of `en`,
`ru` and `uk`. All three returned HTTP 502 from the probe because the Workers AI
binding raised the same provider error before producing a transcript. A separate
one-request English diagnostic retained the exact private failure at
`acceptance/issue-13/two-source-en/en/provider-error.json`:

```text
AiError 5006: Error: required properties at '/audio' are 'body,contentType'
```

The private failure artifact SHA-256 was
`e01a2ebc1e8e5879efdc00da5dfa514b205a287d6f0ecdc9b42dc201da53d6f4`.
The request contained the documented `audio.body` and `audio.contentType`
properties plus explicit language, channels, multichannel, diarization,
punctuation and smart-format options. This exact error is independently reported
in the still-open Cloudflare
[workerd issue #5082](https://github.com/cloudflare/workerd/issues/5082). The
current first-party adapter also uses the same base64 binding shape, while its
credentialed REST path bypasses the JSON interface and sends raw bytes.

One final, non-retried format-only request sent the English stereo WAVE as raw
binary to Cloudflare's documented `/ai/run/@cf/deepgram/nova-3` REST endpoint.
Cloudflare rejected it before inference with HTTP 401 / code 10000 because the
existing account-scoped deployment token intentionally has no Workers AI API
permission. No broader credential was created or stored in the Worker.

Cloudflare currently publishes regular Nova-3 pricing as USD 0.0052 / 472.73
neurons per input audio minute and a free allocation of 10,000 neurons per day.
The maximum list price for the original 54-second set would be USD 0.00468 if all
failed calls were fully metered. The restricted billing API is not readable by
the scoped token, so the Goal ledger explicitly records a conservative EUR 0.02
safety booking rather than claiming an observed invoice delta; all reservations
were released afterward.

Authoritative references:

- [Nova-3 model and unit pricing](https://developers.cloudflare.com/workers-ai/models/nova-3/)
- [Workers AI pricing and free allocation](https://developers.cloudflare.com/workers-ai/platform/pricing/)
- [Workers binding](https://developers.cloudflare.com/workers-ai/configuration/bindings/)
- [Workers AI REST API](https://developers.cloudflare.com/api/resources/ai/methods/run/)
- [Asynchronous Batch API](https://developers.cloudflare.com/workers-ai/features/batch-api/)
- [Cloudflare binary REST implementation](https://github.com/cloudflare/ai/blob/main/packages/workers-ai-provider/src/utils.ts)
- [Cloudflare Nova-3 binding implementation](https://github.com/cloudflare/ai/blob/main/packages/workers-ai-provider/src/workersai-transcription-model.ts)

## Checkpoint result

No live response contradicted the selected WAVE/channel profile: the binding
failed at its documented multipart-like input contract before inspecting the
media, and REST failed at API authorization before inference. Under the
capture-build correction in #10, that upstream transport failure does not block
the independently validated writer format, so #15 may consume the selected
profile.

The full #13 issue remains open. Hosted media acceptance, successful timing and
channel evidence, English/Russian/Ukrainian availability, one-/three-hour request
behavior, latency, Batch/result recovery, uncertain-submission handling and an
observed billing unit are unresolved. No external Deepgram request, private audio,
personal deployment, provider switch, silent truncation or track merge occurred.
