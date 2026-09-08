# Shared v1 contracts

`src/schema-registry.ts` gathers the structural sources of truth, including
`src/document-schema.ts` and `src/upload-schema.ts`. Their JSON-compatible Effect
Schema definitions derive TypeScript types and runtime decoding, the emitted
`schema/v1.schema.json` (draft 2020-12), and Swift `GeneratedDocuments.swift`.
`bun run contracts:generate` updates these artifacts; `contracts:check` compares
in memory without rewriting tracked files. Generation runs on Linux and macOS,
requires the installed/vendored Effect version to match the pin, and rejects
unsupported schema nodes, transformations, unrepresented checks, and Swift
capabilities. Generated types are outputs, never additional authoring sources. `schema/routes.v1.json` maps the approved HTTP surface to shared schemas
and owning feature issues; it does not claim those endpoints are implemented.

`schemaVersion` selects compatible structure. `documentVersion` is a positive,
monotonic mutable-manifest version (the local repository enforces progression;
the future synchronization layer must preserve it).
`revisionId` identifies an immutable transcript; `operationId` identifies a command.
They are never substitutes for each other. Reusing an operation ID with different
content is a conflict enforced by the local durable operation owner. Remote
execution and synchronization retain their separate downstream delivery gates.

`validateStructure` checks closed v1 shapes, required nulls, canonical UUIDs,
UTC timestamps and safe integer constraints. `validateDocument` additionally checks
within-document semantics. `validateArchive` requires the bytes for all referenced
audio manifests and published revisions, checks SHA-256 before parsing each one,
and validates call/track/speaker provenance, bounds, retained names and coverage.
A structurally valid manifest is not a validated aggregate. Missing references
fail; no consumer should replace a valid archive with rejected input.

Use `readStoredDocument` (TS) / `Contract.decode(Model.self, bytes:)` (Swift) at byte
boundaries. Swift returns `StoredDocument<Model>` with a typed `value`, original
`storedBytes`, and the SHA-256 of those original bytes. `Contract.decodeArchive`
adds reference/integrity validation for a typed call. Use `Contract.encode` only
to encode and validate a new publication. Swift nullable fields are required keys
and encode explicit null; UUIDs and timestamps remain strings without Foundation
UUID/date normalization. Closed-object validation remains in the cached native
JSON Schema validator; plain Codable does not enforce every exchange constraint.
Native archive/capture/recovery/status code consumes the generated models; dynamic
JSON stays inside the generic schema/semantic validator and real platform adapters.
Retain original UTF-8 bytes for immutable publication. Parsing and lossless field
round-tripping do not promise identical JSON formatting. Object-media bytes are
validated by the native media finalization adapter; this package validates their
identity/size/hash descriptors and logical mappings, not codec/decoding internals.
The permanent recording profile is `schema/capture-master-profile.v1.json`:
one recoverable stereo CAF master, microphone on channel 0 and application on
channel 1. Its integrity commits, upload byte ranges and ASR extraction intervals
are independent. Both languages load the same checked resource. The
[capture master interface](../../docs/development/capture-master-interface.md)
defines final identity, byte limits, extraction provenance and retention.

The upload commands register the original call, admit fixed master byte ranges,
and finalize the complete stored CAF. Finalization references the registration
and carries closed capture state, actual duration, exact AudioManifest bytes and
a lossless source-state map. The map encodes both source states for every integer
millisecond in two bits per source (`recorded=0`, `muted=1`, `unavailable=2`). Each
byte contains microphone/application in its low nibble for the even millisecond
and high nibble for the odd millisecond. Application mute, code 3 and nonzero
unused padding are invalid. Canonical base64 requires at most 7,200,000 characters
for three hours, independent of canonical interval fragmentation. The server
validates the map and includes its raw-byte SHA-256 in `VerifiedMasterReceipt`;
the canonical interval document remains local until the separate replica step.
The original finalization operation is retained for exact replay after later
metadata changes. A part receipt or ETag cannot authorize local media cleanup.

The independent `schema/media-profile.v1.json` WAVE profile remains the #13
provider-probe input, including its 60-second object and provider-assembly rules.
It is not the production capture file layout. Hosted acceptance of inputs derived
from the permanent master remains #13; neither profile alone establishes it.

Exchange UUIDs retain the broader lowercase format, while request and generated
identity schemas use canonical UUID v4. Both share definitions without conflating
their constraints. UTC timestamps use ASCII digits in both regex engines and
calendar checks; safe integer fields are bounded by JavaScript's maximum safe
integer. ASR `effectiveOptions` intentionally contains only JSON scalar values;
nested arbitrary JSON remains rejected. Provider decoding and aggregate semantics
are separate from structural authoring.

Both languages run `fixtures/structure-cases.json` through their strict boundaries;
Swift additionally encodes each accepted typed model and revalidates every field.
TypeScript also validates the corpus against the emitted JSON Schema using test-only
AJV. Both languages run `fixtures/cases.json` with the same outcomes and failure
categories: `structure`, `semantics`, `reference`, `checksum`. Valid no-speech and
Unicode/unknown-speaker fixtures preserve retained revisions and names. Tests at
the byte boundary cover exact SHA-256 and different whitespace. API error retry
classes are `never`, `after_correction` and `retryable`; feature issues supply
stable specific codes and endpoint payloads through this shared contract.
