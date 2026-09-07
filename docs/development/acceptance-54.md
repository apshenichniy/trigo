# Shared local/cloud product API acceptance (#54)

## Scope and source identity

This slice implements [issue #54](https://github.com/apshenichniy/trigo/issues/54)
on accepted integration base `7db0f90ff4ed86d90218fe8c249693d55c4c2f88`.
It shares the supported authenticated status API between local and cloud, adds
supported offline D1/R2/workflow composition, and supplies an explicitly isolated
native loopback pairing bridge. Production upload, ASR orchestration, sync and
transcript UI remain later product work.

The final source snapshot is staged tree
`0eabbcb6eb2e39b027755f51b071011da825a479`. It includes the shared generated
bridge contract, strict native contract validation, and the corrected sandboxed
native runner. Required complete checks for this snapshot are recorded below.
Only acceptance/setup documentation is updated after these source checks.

`/tmp/trigo-epic-48/54-final-source.json` records this snapshot and the earlier
successful snapshots separately. Final runtime subtrees:

| Directory  | Tested tree                                |
| ---------- | ------------------------------------------ |
| `apps`     | `ea70f98bc9f7e70f02a0e4e03d054d4323784c9e` |
| `scripts`  | `f086151e82d02c0231f702d4cea30a0812380f11` |
| `infra`    | `619f2d2bb940bd5bd0d3a845a5a08e37764f064a` |
| `packages` | `cdeb2fdb4004ad1712c463a439465bc84e117e9f` |

All logs below are retained under `/tmp/trigo-epic-48/` with a `54-` prefix.
This evidence is local; the coordinator owns subsequent integrated CI and the
single epic PR. No cloud deployment, provider request, installed-app launch,
personal credential access or OS-permission interaction was performed here.

## Implemented boundaries

`apps/server/src/product-api.ts` defines the Effect HttpApi status endpoint using
the existing Effect-authored `StatusResponse` and `ErrorEnvelope` contracts.
`product-handler.ts` owns authentication, supported status behavior and the
unavailable-operation response for both Worker entrypoints. Each request owns
and disposes its handler layer, so captured owner context and Worker bindings
cannot escape to another request or stage.

Authentication retains the exact existing `Bearer trigo_v1_<64 lowercase hex>`
grammar, the D1 verifier/generation checks and authentication before unavailable
operation disclosure. The status readiness values and existing notices remain
unchanged. It does not invoke R2, workflow or AI while reporting status.

`http-errors.ts` shares the existing owner/probe error mapping and handles the
two distinct pinned Effect `4.0.0-rc.112` transport paths: schema failures become
defects, while unsupported content types return a direct 415 response. Requests
receive `request_invalid` (400) or `unsupported_content_type` (415), both
`after_correction`; response encoding errors receive `response_invalid` (500),
`retryable`. The envelope keeps schema version 1 and a fresh UUIDv4 request ID.
Interruptions remain interruptions. The narrow body/raw-byte test routes are
fixtures of this actual middleware, not additional shipped product endpoints.

The offline graph contains only supported Alchemy Worker, D1, R2 and workflow
providers, local state and fake ASR. No Workers AI binding or remote fallback is
present. The existing cloud dev probe and offline adapter share a canonical
`TranscriptRevision` result interface. The live adapter still uses the existing
Nova-3 normalizer; the fake result is deterministic no-speech with supplied
immutable context and `asr.adapter = fake`. The fake adapter does not establish
hosted speech-recognition readiness. Existing probe upload/storage/hash paths
remain binary and retain their raw bytes.

The local launcher generates a private local-only owner handoff and reuses its
namespace/token across server restarts. D1 holds the verifier and archive
identity. Health/bootstrap and workflow probes are explicit local infrastructure
helpers; the former fixture-only transcription API is removed. See
[the local command and pairing procedure](setup.md#local-runtime).

The CLI-to-native `LocalDevelopmentBridge` exchange is authored once in Effect,
then generates the shared JSON Schema and Swift model. Both file readers enter
through the shared strict validator; handwritten Codable parsing is not the
boundary. The common 16-case corpus covers valid configurations, UUID version
and variant restrictions, excess/missing fields, format version, token grammar
and structural origin restrictions. It runs against Effect, emitted JSON Schema,
generated Swift, and both actual private-file readers. Contextual filesystem,
current-worktree and exact-port rules remain in the launcher/native adapter.

The native bridge requires a private owned configuration file, a matching build
worktree, a distinct `.local.<UUID>` namespace, and exactly its configured
`http://127.0.0.1:<port>` origin. The URLSession adapter and metadata decoder use
the same policy as connection admission. Ordinary Dev/personal connections keep
HTTPS, and redirects are rejected. The Dev build contains a Boolean
`NSAllowsLocalNetworking` ATS setting; the personal build retains default ATS.
The app prefills the explicit local handoff, then requires **Connect** before
recording eligibility. Normal app credentials retain the existing Keychain
pending/committed/retired transaction protocol.

## Behavior evidence

| Evidence                                                  | Result and log                                                                                                                                                                                                                                                                              |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared local/cloud route/auth/error matrix in workerd     | 23 focused cases in `54-worker-focused2.log`; all are included in the final 36-test Worker gate. This covers bearer grammar, rotation/revocation, unavailable operations, D1 failures, request IDs, concurrent context isolation, HttpApi parsing/415/500 and exact raw bytes.              |
| Canonical fake adapter and private configuration          | Final `54-check-server-final.log` includes deterministic canonical fake-ASR output and private-file/environment isolation. `54-bridge-unit2.log` passes 156 focused tests: the existing structural corpus plus the 16 new bridge cases and file-reader cases.                               |
| Cross-language bridge contract                            | The same 16 bridge cases run through Effect, emitted JSON Schema, generated Swift, and both actual file readers. `54-check-server-final.log` and `54-check-macos-final.log` pass accepted configurations and rejected non-v4 UUIDs, unknown/missing fields, invalid tokens and origins.     |
| Native loopback transport and persistence                 | All seven `LocalDevelopmentTests` passed in the final native gate: exact origin, namespace separation, strict shared bridge/private files, actual URLSession failure classification, redirects and persistent recording eligibility while offline.                                          |
| Actual native client against selected Alchemy composition | Final `54-check-macos-final.log` records sandboxed URLSession first pairing, unauthorized rejection, unavailable operations, metadata restore and isolated namespace; the focused test passed in 0.101 s. Credential adapter is disposable/in-memory and metadata uses the real file store. |
| Actual offline infrastructure and restart                 | The same final gate passed local D1 identity, actual workflow storage of the canonical fake revision in R2, byte-identical readback and D1/workflow state after restart. Alchemy/workerd and native test execution ran under the outbound-network sandbox; the external probe was denied.   |

## Required complete checks

- `mise exec -- bun run check:server`: passed on the final source snapshot,
  `54-check-server-final.log`. Formatting, lint, TypeScript, deterministic
  generation, 304 unit tests, 36 Workers tests, and local/cloud bundles passed.
  Existing cloud account/stage/state protections and binary/probe tests remain
  included.
- `TRIGO_TIMINGS_FILE=/tmp/trigo-epic-48/54-check-macos-final-timings.jsonl mise exec -- bun run check:macos`:
  passed on the final source snapshot, `54-check-macos-final.log`. Nine Swift
  contract tests and 161 native tests passed. The native test run took 352.156 s
  (353.922 s including the command wrapper), longer than the earlier snapshot;
  this is the final run's measured duration. Both app builds and actual
  dev-Boolean/personal-default ATS plist checks passed.
- Unchanged repository/production contention completed 319/321 commits at the
  existing one-source-second-per-wall-second cadence, all three imports,
  12,000 turns and 24 reads. Maximum input-plus-commit latency was
  1194.406/1217.283 ms against the unchanged 2000 ms limit. No shortened fixtures,
  relaxed thresholds or added suite serialization were used.
- The same complete macOS gate ran the corrected sandboxed local/native smoke.
  Its current-source `swift build --build-tests` check was incremental (3.40 s),
  followed by `--skip-build` execution under `offline.sb`. First pairing,
  restore, authentication, D1/R2/workflow and persistent restart passed; the
  complete smoke phase took 16.941 s. The earlier whole-gate snapshot placed
  only Alchemy/workerd under this profile; it is retained as earlier evidence.
- Documentation-only updates after the runtime gates passed final repository
  formatting (`54-format-complete-final.log`) and preserve the exact runtime
  subtrees above.

## Diagnostics retained

The final sandboxed runner initially failed at SwiftPM manifest evaluation:
`54-local-native-final.log` records `sandbox_apply: Operation not permitted`
from trying to nest SwiftPM's manifest sandbox inside the outer macOS sandbox.
The runner now passes per-invocation `--disable-sandbox` to SwiftPM while keeping
`offline.sb` active around the entire subprocess. No app/OS permission or global
sandbox configuration changed. A subsequent attempt to match flags within
`swift test` still rebuilt the test product. The final runner first executes the
same locked `swift build --build-tests -Xswiftc -enable-testing` command as the
main native gate, then runs the native test with `--skip-build` under the outer
sandbox. Current sources are checked before execution. The final gate timing
records whether that build was incremental; earlier cache reuse was not proven.

Root review also found that the first bridge used an independently handwritten
Swift structure/validator. The final contract correction replaced that duplicate
with the Effect-generated model and common strict validator. The first focused
bridge test (`54-bridge-unit.log`) caught a root-script workspace import; the
relative contracts import fixed it, and `54-bridge-unit2.log` passed 156 tests.

Early diagnostics were corrected before final checks; they are not acceptance
passes. `54-local-first.log` failed before runtime startup because the root
script used a workspace package import unavailable from that location; it now
uses the existing relative contracts boundary. `54-worker-focused1.log` failed
because a malformed-row test fixture violated D1's 36-character constraint before
reaching authentication; the fixture now uses 36 invalid UUID characters and
exercises the intended decoding failure. `54-native-focused1.log` exposed an
incorrect reference to an existing connection error enum member; the corrected
client uses `invalidServerURL`. Early type/lint logs record the replaced old
fixture interface and the corresponding compile/style corrections. No long-call
fixture duration, concurrency, durability threshold, retry policy or product
acceptance condition was relaxed.

## Outstanding installed acceptance

This evidence does not establish installed signing, actual ATS enforcement in
the signed app, physical capture permissions or repeated Keychain/TCC-dialog
behavior. Those remain owner-assisted [issue #57](https://github.com/apshenichniy/trigo/issues/57),
following the separately owned readiness/credential work in #55. The controlled
URLSession tests use real transport and file metadata, with disposable
credentials; they do not replace that installed gate. Cloud deployment and
hosted ASR acceptance remain their existing product/deployment gates.
