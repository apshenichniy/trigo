# Transcription service acceptance

This records the local acceptance scope for issue
[#18](https://github.com/apshenichniy/trigo/issues/18). The final candidate SHA,
required CI run, native checks and authorized hosted results belong in the PR
handoff. The [service contract](transcription-service.md) describes deployment,
recovery and the prepared operator probe.

## Local evidence — 2026-09-08

`bun run check:server` passed in 55.578 seconds: repository formatting, TypeScript
lint/types, generated contract checks, 430 unit tests, 91 Worker tests and both
Worker bundles. The shared structural corpus includes the new request, operation
and result-reference documents and rejection cases. The Worker tests use isolated
D1/R2 and fake provider responses.

The suites cover admission races, an original-plus-one attempt ceiling, raw and
artifact acknowledgement loss, immutable publication replay, owner/call/attempt
fences, empty results, actionable provider errors, side-effect-free polling and
real local Workflow execution/restart. The 64,000-word fixture exercises two
multi-megabyte provider results without putting text into Workflow/D1 state. The
virtual three-hour fixture exercises two-hour-plus-one-hour range extraction and
reuses a successful interval during replacement; its repeated speaker labels
remain distinct across provider submissions/channels.

Review of `81337ec7d` found two recovery defects. Focused tests failed before the
fixes and passed afterwards: restarting with an admitted replacement now resolves
the latest D1 attempt, and changed retained audio-manifest bytes prevent provider
execution. The final full server run includes both regressions. Runtime diagnostics
from explicitly disconnected streams and Workflow restart are retained in the
test output; the associated fault tests pass.

## Hosted evidence boundary

The existing Dev status endpoint was read successfully with its current operator
credential. Two local synthetic 60-second masters were prepared through the
operator command, with immutable commands and maximum two attempts per call:

| Language | Call ID                                | Operation ID                           |
| -------- | -------------------------------------- | -------------------------------------- |
| English  | `0dda6040-33d9-4fcd-9684-0f832b8c641c` | `b3f4a565-85b8-4a37-86da-0026a5d4b690` |
| Russian  | `d81deb7e-40e9-4969-8395-aecc4018765f` | `76d7d6ea-2d02-4b28-8a7c-e28556f1bdd4` |

Preparation does not upload or invoke ASR. A hosted pass requires authorization
for this candidate's Dev deployment and these request identities. It must retain
the verified master receipt, available operation, exact revision/provenance bytes
and accounting in the private fixture evidence directory. No hosted #18 pass is
claimed by the local results above. The full-master provider profile evidence
remains in [#13's accepted profile](asr-submission-profile.md); #24 owns the final
integrated duration, latency, desktop import/replica and playback acceptance.
