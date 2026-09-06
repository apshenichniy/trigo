# Issue #30 acceptance record

This record covers issue #30 under the approved parent #12 implementation plan.
It separates deterministic repository evidence from cloud mutations and
fresh-checkout observations that require explicit owner authorization.

## Deterministic implementation evidence

- The shared `StatusResponse` contract has valid and invalid fixtures consumed by
  both TypeScript and Swift conformance tests. It includes schema/API versions,
  archive identity, deployment stage, readiness and actionable errors.
- The D1 migration owns a singleton archive identity, the current owner verifier
  and generation, and an idempotency ledger. Only lowercase SHA-256 verifiers are
  persisted; plaintext Trigo tokens are absent from the database and D1 operation
  batch.
- Workers/D1 integration tests cover exact initialization replay, mismatched replay
  rejection, one winner under concurrent rotation, revoke replay, replacement
  after revocation, current-token authentication, immediate rejection of replaced
  and revoked tokens, and deny-by-default owner routes.
- The operator boundary creates an exclusive mode-`0600` handoff, reuses it after
  an uncertain result, binds replay to the selected account/database/deployment
  identity, rejects mismatched or unsafe handoffs, and sends the shared
  parameterized operation plan through the Cloudflare D1 API. Its routine output
  contains only non-secret identifiers and state.
- Authenticated status reads the current primary through the D1 binding for every
  request. The prepared-statement cache contains statements, not authorization
  results. Persisted rows are runtime-decoded before they become owner context, and
  transient D1 failures produce a retryable storage error rather than an incorrect
  initialization instruction. Status does not invoke R2, Workflow or Workers AI.
- Ordinary `check`, `check:server`, tests and builds remain offline. No cloud
  mutation is part of CI.

The relevant local gates must be rerun on the reviewed final tree and recorded in
the issue/PR evidence:

```sh
mise exec -- bun run contracts:check
mise exec -- bun run check:server
mise exec -- bun run check:macos
```

## Owner-authorized live dev evidence (2026-09-05 UTC)

The owner authorized the exact isolated-dev sequence against Cloudflare account
`27940cd0d92bb3f03943a5378ccf68d3`, profile `trigo-cloud-dev`, Worker
`trigo-dev-api` and stage `dev`. Every command loaded the existing account-scoped
operator token from macOS Keychain only into its process environment. No personal,
disposable-account or ASR action ran.

- The deployed and fresh-checkout commit was
  `178f272887f2dc21a673c75ab0722f6b9676d5aa`. Selected versions were Bun 1.3.13,
  Node v24.14.1, Alchemy 2.0.0-beta.76 and Wrangler 4.124.0. Preflight and the
  Wrangler account-authentication check passed before mutation.
- The first deployment began at `2026-09-05T22:25:38Z`. It updated only the API
  Worker and catalog declaration to install issue #30; the retained R2 archive and
  Workflow were no-ops. The catalog remained D1 database
  `ad0438e9-6540-4a46-82b8-d74ca1db4b3d`.
- Live inspection reported deployment identity
  `trigo-dev-api:e2e8f715929a689b`, private R2 with zero custom domains, configured
  R2/D1/Workflow bindings and a present-but-not-verified Workers AI binding. The
  preserved #29 fixture `763b983c-96a3-4f4e-9991-56333557d314` was read from both
  R2 and D1 immediately after deployment.
- Initialization created stable archive ID
  `2c257f10-a493-4a35-8f8d-71ea825661de`, generation 1 and operation
  `34b75b9d-b588-4caf-83d2-89f7fa0f73d0`. Authenticated status matched the shared
  contract and truthfully reported archive/authentication ready, transcription not
  verified and call operations unavailable. Exact replay returned the same archive,
  generation and operation IDs.
- Two rotations ran concurrently from expected generation 1. Exactly one committed:
  generation 2, operation `caf3a228-0cae-44e6-a333-71e2ee70ec2a`; the other
  returned the expected generation/content conflict. The initialization token then
  returned HTTP 401, while the winner authenticated. Replaying the winner as the
  lost-acknowledgement recovery returned the identical operation result.
- Revocation produced generation 3 and operation
  `13ebaaab-0599-4eb5-8703-00b2b50e2a69`; the revoked token immediately returned
  HTTP 401. Operator-authorized recovery produced active generation 4 and operation
  `65aa1158-b36f-46f3-8e25-6606edcbc903`; authenticated status again returned the
  same archive ID.
- Missing, malformed and independently generated wrong credentials each returned
  HTTP 401 / `owner_unauthorized`. An unauthenticated product operation also
  returned 401; the same unimplemented operation with the active credential
  returned HTTP 501 / `operation_unavailable`.
- The repeat deployment reported all four declarations as no-ops. Both the active
  credential and #29 fixture then passed verification with the unchanged archive
  ID. A separate fresh clone installed the frozen dependency graph, checked out the
  exact deployed commit, passed preflight and began its deployment at
  `2026-09-05T22:29:41Z`; all four declarations were again no-ops. It independently
  re-verified the same R2/D1 fixture and authenticated status/archive ID.
- Sanitized routine output contained only target/resource names, non-secret IDs,
  generations and readiness. No plaintext Trigo token, operator token or signed
  object URL appeared in URLs, logs, fixtures, this record or GitHub evidence.
  Obsolete credential handoffs were permanently deleted and the fresh checkout was
  moved to Trash. One active mode-`0600` handoff remains outside the repository for
  the separately owned #31 Keychain connection flow.

## Current acceptance state

- Repository implementation and deterministic tests: implemented; final review
  and full-tree gates passed. Independent Standards and Spec reviews reported zero
  findings on the reviewed implementation range.
- Deployed dev behavior, complete credential lifecycle, repeat deployment and
  fresh-checkout deployment: passed on the isolated dev target.
- Personal deployment: out of scope and blocked by issue #32.
- Issue closure and #31 start: pending owner acceptance of the live dev evidence
  above.
