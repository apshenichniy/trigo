# Shared v1 contracts

`schema/v1.schema.json` is the structural source of truth (JSON Schema 2020-12).
TypeScript declarations/standalone validators and Swift resources are generated
from it. `schema/routes.v1.json` maps the approved HTTP surface to shared schemas
and owning feature issues; it does not claim those endpoints are implemented.

`schemaVersion` selects compatible structure. `documentVersion` is a positive,
monotonic mutable-manifest version (the synchronization layer enforces progression).
`revisionId` identifies an immutable transcript; `operationId` identifies a command.
They are never substitutes for each other. Reusing an operation ID with different
content is a conflict enforced by the later durable command layer.

`validateStructure` checks closed v1 shapes, required nulls, canonical UUIDs,
UTC timestamps and safe integer constraints. `validateDocument` additionally checks
within-document semantics. `validateArchive` requires the bytes for all referenced
audio manifests and published revisions, checks SHA-256 before parsing each one,
and validates call/track/speaker provenance, bounds, retained names and coverage.
A structurally valid manifest is not a validated aggregate. Missing references
fail; no consumer should replace a valid archive with rejected input.

Use `readStoredDocument` (TS) / `ValidatedDocument` (Swift) at byte boundaries.
Retain original UTF-8 bytes for immutable publication. Parsing and lossless field
round-tripping do not promise identical JSON formatting. Object-media bytes are
validated by the later media finalization adapter; this package validates their
identity/size/hash descriptors and logical mappings, not codec/decoding internals.
The selected #13 media profile is the checked
`schema/media-profile.v1.json` artifact. It fixes two interleaved logical sources
in independently decodable 60-second WAVE objects: microphone on channel 0 and
application audio on channel 1. TypeScript and Swift consumers load the same
generated resource, including the exact upload, playback, ASR assembly, timing,
and speaker-scope rules.

Both languages run `fixtures/cases.json` with the same outcomes and failure
categories: `structure`, `semantics`, `reference`, `checksum`. Valid no-speech and
Unicode/unknown-speaker fixtures preserve retained revisions and names. Tests at
the byte boundary cover exact SHA-256 and different whitespace. API error retry
classes are `never`, `after_correction` and `retryable`; feature issues supply
stable specific codes and endpoint payloads through this shared contract.
