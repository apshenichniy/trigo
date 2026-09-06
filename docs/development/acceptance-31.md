# Issue #31 acceptance record

This record covers issue #31 under the approved parent #12 implementation plan.
It separates deterministic connection-model evidence from the owner-authorized
live dev pairing. Personal deployment, archive switching and call recording remain
outside this issue.

## Deterministic implementation evidence

- The SwiftUI screen provides an HTTPS server URL, a secure owner-token field,
  Connect/Validate and retry actions, actionable connection status, the durable
  archive identity and local-recording eligibility.
- `ServerConnection` keeps the durable archive binding separate from current
  connection health. Network, authentication, compatibility and missing-Keychain
  failures block server operations without removing an established binding or
  local-recording eligibility.
- Candidate settings are authenticated and validated against the shared status
  schema, deployment stage and saved archive ID before persistence. A different
  archive is rejected; a same-archive URL/token replacement is accepted.
- Connection metadata uses a mode-`0600` temporary file, synchronizes it and
  atomically renames it only after all throwable preparation succeeds. The token
  is stored as a generic password in Keychain and never enters metadata.
- The metadata/Keychain commit protocol records a pending candidate before the
  credential write, commits the metadata pointer before retiring the prior token,
  and retains cleanup checkpoints across failures and relaunches. Corrupt stage,
  archive or credential-account relationships fail closed.
- Personal, development and development-worktree namespaces have distinct
  Application Support roots, preferences suites and Keychain services.
- The deterministic native suite covers first binding, relaunch, same-archive
  replacement, rejected candidates, write/delete interruption, same-process and
  relaunch recovery, offline and missing/failed credential reads, invalid HTTPS
  origins, shared-schema decoding, real temporary Keychain persistence, atomic
  metadata permissions and namespace isolation. It has 20 deterministic tests and
  one opt-in live test that is skipped until an explicit handoff path is present.

The reviewed final tree must pass:

```sh
mise exec -- swift test --package-path apps/macos
mise exec -- bun run check:macos
mise exec -- bun run check
```

## Owner-authorized live dev evidence

The owner authorized pairing only the installed development app namespace with the
existing isolated dev deployment. The acceptance used production HTTPS,
`FileConnectionMetadataStore` and `KeychainCredentialStore` adapters; it did not
use fake stores. No personal app, personal cloud, call or ASR operation ran.

- Before pairing, the installed worktree namespace had no connection metadata.
  The active generation-4 owner handoff from #30 was read from its private
  mode-`0600` regular file directly into the acceptance process and was never
  printed. The harness rejected symlinks, unsafe permissions, oversized or
  unexpected structures, target/generation mismatches and invalid token, timestamp
  or UUID shapes before using the credential.
- Authenticated status at
  `https://trigo-dev-api.alexander-pshenichniy-279.workers.dev` returned stage
  `dev` and archive ID `2c257f10-a493-4a35-8f8d-71ea825661de`. The first
  connection bound that identity and remained locally recording-eligible. This
  exact authenticated stage/archive read was a non-mutating preflight before the
  first metadata or Keychain write.
- Reconnecting with the same live server and token exercised the replacement
  transaction. A deliberately invalid token then returned the expected
  unauthorized result while preserving the committed binding and local-recording
  eligibility. A newly constructed production connection restored and
  re-authenticated the same binding from persisted metadata and Keychain.
- Persisted metadata contained one committed dev binding, no pending candidate and
  no retired credential accounts. The file mode was `0600`; a matching generic
  password existed in the worktree-specific Keychain service. Neither the token nor
  the Keychain account identifier appeared in routine output or repository files.
- `~/Applications/Trigo Dev.app` was rebuilt, installed and launched with worktree
  namespace `5202838aa424`. The personal app and personal namespace were untouched.

The opt-in live command is enabled only by an explicit handoff path and then
requires every selector below. The handoff path is operator-owned and must remain
outside the repository:

```sh
TRIGO_LIVE_HANDOFF_PATH=/private/operator/handoff.json \
TRIGO_LIVE_SERVER_URL=https://trigo-dev-api.example.workers.dev \
TRIGO_LIVE_ARCHIVE_ID=00000000-0000-4000-8000-000000000000 \
TRIGO_LIVE_WORKTREE_ID=worktree-id \
TRIGO_LIVE_ACCOUNT_ID=00000000000000000000000000000000 \
TRIGO_LIVE_DATABASE_NAME=trigo-dev-catalog \
TRIGO_LIVE_DEPLOYMENT_IDENTITY=trigo-dev-api:0000000000000000 \
TRIGO_LIVE_EXPECTED_GENERATION=1 \
  mise exec -- swift test --package-path apps/macos \
    --filter LiveConnectionAcceptanceTests
```

## Current acceptance state

- Repository implementation, deterministic tests and native build: passed.
- Independent Standards and Spec reviews: no findings on the final reviewed range.
- Actual dev HTTPS, Keychain, metadata, same-archive replacement, rejected-token
  preservation and relaunch restoration: passed.
- Personal deployment, archive migration/switching and recording controls: out of
  scope.
