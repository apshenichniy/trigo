# Issue 50 acceptance: Effect contracts and typed Swift boundaries

Scope: [issue #50](https://github.com/apshenichniy/trigo/issues/50), under
[the accepted recording architecture specification](https://github.com/apshenichniy/trigo/issues/48).
Implementation started from integrated #49 commit `2ccbe7906` in an isolated
worktree. This evidence concerns local contract/native/server behavior; the
coordinator owns integrated CI and the epic PR.

## Authoring and consumers

- `packages/contracts/src/document-schema.ts` now authors all six exchange
  documents with Effect `Struct`, arrays, unions, records, and explicit scalar
  checks. Exported TypeScript interfaces derive directly from their schemas.
  Exchange UUIDs and canonical UUID-v4 identities retain separate constraints;
  UUID-v4/hash definitions are also reused by server identity/provider adapters.
  Media identity, MIME type, and source-role constraints reuse the existing
  `MediaProfile`/`MediaSourceRole` definitions without changing the selected media
  format or provider capability.
- Strict TypeScript decoding uses `onExcessProperty: "error"`. Schema emission
  produces draft 2020-12, and a bounded compiler emits public Swift models with
  explicit required-key decoding and nullable encoding. UUID/date values remain
  strings; generated models do not normalize them through Foundation UUID/Date.
  The intentionally open `effectiveOptions` dictionary accepts only JSON scalars,
  represented as `JSONScalar` in Swift; arrays/objects remain invalid values.
- `Contract.decode`/`decodeArchive` return `StoredDocument<Model>` containing a
  typed value and the original bytes. Native archive publication/evolution,
  revision annotations, capture creation/finalization, recovery, and status
  decoding consume these models. Ordinary native document paths no longer use
  `JSONSerialization`/`[String: Any]`. The OS window adapter still uses its actual
  platform dictionary boundary. Test fixture mutation helpers stay in tests.
- Cross-document reference, timeline, provenance, and hash validation remain
  separate. The native generic JSON Schema validator is cached and retained:
  plain Codable is explicitly not claimed to enforce the full structural
  contract. Required nullable keys encode JSON null, and new publications pass
  validation through `Contract.encode` before publication.
- Production AJV standalone validators and generated TypeScript declarations
  were removed after parity passed. AJV remains a test-only verifier of emitted
  JSON Schema. `json-schema-to-typescript` and its unused dependency subtree were
  removed. Bun hoisted the already locked `lodash@4.17.21` used by Chevrotain after
  removing the generator's `lodash@4.18.1`; surviving consumers retain their
  versions. Other direct pins, Swift resolution files, and `repos/effect` are
  unchanged.

## Shared parity and immutable evidence

Both language suites run 117 structural fixtures from
`packages/contracts/fixtures/structure-cases.json`, plus the existing 49-case
semantic/reference/checksum corpus. Cases cover closed nested objects, missing
versus null keys, safe integer extrema/fractions/overflow/booleans, finite provider
numbers, calendar dates/leap seconds/fractional precision, UUID versions/casing,
keyed annotations, reference/hash failures, and invalid media profile identities.
Every valid fixture also passes typed Swift re-encoding and field equality.

Before retiring the original production validators, all 117 structural cases were
run against them and matched the expected outcomes. The current TypeScript tests
run the same corpus against Effect and emitted-schema AJV validation. Native tests
run it through cached schema validation and generated typed decoding.

An added red probe confirmed an existing cross-engine difference:
`2026-09-06T00:00:00.١Z` passed the native `\d` regex and failed JavaScript validation.
The Effect authoring pattern now uses explicit `[0-9]`, preserving the original
JavaScript contract and rejecting that value in both languages. Trailing LF in
UUID/hash/timestamp scalars is rejected in both and retained in the corpus.

Typed byte tests preserve original buffers and SHA-256 independently of edited or
re-encoded values. The native archive test
`typedTranscriptExportKeepsOriginalIdentityAndRejectsReencodedBytes` demonstrates
that equivalent re-encoded transcript fields still produce different bytes: exact
original bytes remain idempotent, the re-encoding conflicts under the existing
revision identity, and retained evidence/hash remains unchanged. Existing tests
also cover retained revisions, speaker-name edits, identity conflicts, corrupted
references, and interrupted publication/recovery.

## Deterministic generation and capability gates

Two successive `bun run contracts:generate` executions produced identical bytes.
A subsequent `bun run contracts:check` preserved both contents and mtimes of every
output; the check path computes artifacts in memory and performs no writes.
Generation uses portable Bun/Node and the pinned Oxfmt library, with no Swift
executable dependency. Linux execution remains pending the coordinator's integration CI.

Generated output SHA-256:

| Output                                    | SHA-256                                                            |
| ----------------------------------------- | ------------------------------------------------------------------ |
| JSON Schema and identical native resource | `b838f84411d8cd007e2a8d465927fa3d6d61da935525bdf40c492aef54175377` |
| Generated Swift documents                 | `3f62887c6924c14effb2692ea78be875ff8fafc51a3a88a1555cf06dadf19585` |
| Unchanged selected media-profile resource | `c6c5fdce7960df874d6587819acfa228d34bafa776f0980b93cac954f7a8cf6b` |

Generation verifies installed, pinned, and vendored Effect version equality
(`4.0.0-rc.112`, reference tag commit
`2600f62f4532026928454dcea8d1c48557b3f942`). The reference remains read-only. Tests
prove explicit failures for opaque declarations, wire transformations, checks
without JSON Schema representations, unsupported Swift keywords/formats/unions,
and unresolved references. New capabilities require compiler support and parity
fixtures instead of silently falling back to an untyped model.

## Local gates

Run on the repository's pinned mise toolchain and Xcode baseline:

- `mise exec -- bun run macos:setup`: locked SwiftPM/Xcode dependencies resolved.
- `bun install --frozen-lockfile`: passed after the scoped dependency removal;
  no further resolution changes.
- `mise exec -- bun run check:server`: formatting, lint with warnings denied,
  TypeScript, generation check, 262 unit tests, 17 Worker tests, and both local and
  cloud bundles passed.
- `mise exec -- bun run check:macos`: Swift formatting, 8 contract tests (including
  both full shared corpora), 96 Release native tests, both Debug app variants,
  and local Worker/R2/fake-ASR smoke passed. The smoke denied external network
  access. The final command preserved all tracked locks.
- Final warm native timings: contract build/tests `3.460 / 2.421 s`, native Release
  build/tests `1.649 / 19.694 s`, Trigo Dev/Trigo Debug builds `4.400 / 2.655 s`,
  local smoke `3.675 s`. Native tests reported one-hour source-relative drift
  `0.0 ms`; the three-hour writer fixture and all failure/recovery coverage remain
  intact. Timing includes normal local contention and is not a runner promise.
- `git diff --check`: passed.

An earlier exploratory native gate passed its tests, builds, and smoke but correctly
rejected a concurrent deliberate lockfile cleanup at its final lock check. The
stable-lock rerun above is the acceptance result.

No SQLite persistence, media-container change, installed-app/permission exercise,
cloud deployment, issue closure, or merge is part of this slice. Installed behavior
remains the explicit #57 acceptance obligation; this ticket's local evidence does
not claim to prove physical TCC or Keychain interactions.
