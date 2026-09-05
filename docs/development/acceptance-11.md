# Foundation acceptance — issue #11

Implementation scope: [approved plan](https://github.com/apshenichniy/trigo/issues/11#issuecomment-5552590631),
[epic](https://github.com/apshenichniy/trigo/issues/10) and
[tooling resolution](https://github.com/apshenichniy/trigo/issues/9#issuecomment-5552500745).

## Local evidence (2026-09-05)

- Compatibility gate installed the exact package matrix and compiled strict TS,
  Node/Effect tests, Swift JSON Schema 0.13.1, XcodeGen and an Xcode application.
- Worker pool 0.22.0 executed Effect and local R2 under denied outbound requests.
  Alchemy 2.0.0-beta.76 separately ran under Bun with local R2, fake ASR and the
  macOS OS sandbox denying external network access. Its auth-shaped local inputs
  were explicitly invalid, not owner credentials. Effect platform-node/platform-bun
  4.0.0-rc.112 were required additions discovered by the runtime gate.
- `bun run check` passed on Xcode 26.6 (17F113), Swift 6.3.3 / formatter 6.3.0,
  Bun 1.3.13, Node 24.14.1 and XcodeGen 2.46.0.
- Shared conformance has 40 valid/invalid cases with identical Swift/TS results;
  Node suite has 52 tests, Workers suite four, Swift contracts two aggregate tests
  (including all fixtures), native logic one. Later changes must refresh counts.
- Both `Trigo` and `Trigo Dev` build without owner signing credentials. Native
  tests establish separate archive, journal, connection, preferences and Keychain
  namespaces, including worktree separation for development.
- Stored-byte tests use the published SHA-256 `abc` vector, distinct whitespace,
  malformed JSON/UTF-8, missing references and rejected checksum mismatches.
- Unavailable cloud/provider commands return nonzero and identify #12/#13.
  `dev --stage personal` is rejected before starting a process.

## Delivery verification

Fresh-checkout, generator-cache restoration, archive/install and actual GitHub CI
results are recorded at PR handoff. Local success alone does not establish CI or
branch-protection success. No cloud provisioning, deployment, paid ASR, capture,
permission-continuity test, public distribution or merge has been performed.

At initial inspection the remote repository had no branches and no rulesets. Its
local initial documentation commit is the intended PR base. Required checks must
be verified separately from workflow execution. Issue #11 stays open until its
complete acceptance is established; no completion is inferred from this document.
