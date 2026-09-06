# Issue #13 capture-profile review record

Reviewed implementation range:
`15a02df43dc23dab2d8192cdee8e012f9c5e9611` through the final #40 head.

This review covers the narrowed capture-profile handoff authorized by the latest
owner correction in #10. It does not treat the unresolved hosted Nova-3
acceptance as completed.

## Standards

The first pass found five issues:

1. The live CLI parsed HTTP JSON through manual reflective access and could
   accept an incomplete HTTP 200 body as evidence.
2. The canonical command table still described `test:asr` as a nonzero
   placeholder after it became a live, potentially billable probe.
3. The Nova normalization input and selected media profile used unconstrained
   scalar IDs, timestamps, dimensions and indices at Effect/domain boundaries.
4. The CLI error used explicit-`undefined` optionality for an absent `cause` key.
5. Swift represented the closed profile vocabulary as interchangeable strings.

The follow-up decodes status-specific success and shared error envelopes at the
HTTP boundary, documents the explicit ledger and no-retry procedure, decodes the
normalization input through branded and constrained schemas, uses
`Schema.DateTimeUtcFromString`, models an absent cause with `Schema.optionalKey`,
and gives Swift closed vocabulary enum types plus exact selected-profile checks.

## Spec

The first pass found two contract defects:

1. The published valid audio manifest claimed the selected WAVE profile while
   retaining the old three-byte `application/octet-stream` object metadata.
2. Aggregate validation proved only that channel track IDs existed; it did not
   prove channel 0 mapped to the microphone track and channel 1 to the
   application track. The normalizer trusted the same unchecked mapping.

The follow-up publishes metadata for a canonical one-second stereo WAVE object,
checks it against deterministically reconstructed bytes, fixes all affected
cross-reference hashes, constrains media profile IDs and object content type in
the generated contract, and enforces channel-to-role provenance in both
TypeScript and Swift aggregate validation. The normalizer now receives a
validated two-role track set and rejects a swapped channel map; focused
regressions cover both boundaries.

## Verification

- `mise exec -- bun run check`
- TypeScript unit tests — 128 passed
- Worker tests — 17 passed
- Swift contract tests — 5 passed
- Native Swift tests — 21 passed, with the opt-in live pairing test skipped
- dev and personal macOS builds plus the network-denied local smoke passed

The final full-range two-axis re-review is recorded in the #13 checkpoint
handoff.
