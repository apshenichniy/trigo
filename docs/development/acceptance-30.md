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

## Live dev evidence requiring owner authorization

No Cloudflare mutation or deployed credential probe was run while preparing this
implementation record. Issue #30 remains open until the owner authorizes and the
operator records sanitized evidence for this exact sequence:

1. Deploy the reviewed #30 tree to the existing isolated dev target.
2. Create a new private handoff path and run `cloud:owner:init`; retain only the
   non-secret archive ID, generation and operation ID in this record.
3. Run `test:cloud --stage dev --owner-handoff <absolute-path>` and record the
   returned `StatusResponse` without the handoff or token.
4. Replay initialization with the exact same handoff and prove that the archive ID,
   generation and operation ID are unchanged.
5. Run two replacements from the same expected generation and prove that exactly
   one commits. Verify the old token is rejected and the winner authenticates.
6. Simulate a lost acknowledgement by retaining the handoff, rerunning the exact
   command and proving the same operation result is returned. Do not create a new
   handoff for this check.
7. Revoke the winner, prove its token is rejected, then perform an
   operator-authorized replacement from the revoked generation and prove the new
   token authenticates.
8. Repeat deployment and verify that the archive ID, active credential and the #29
   private R2/D1 fixture remain unchanged.
9. From a fresh checkout, recover the existing cloud deployment as documented,
   deploy the same reviewed tree, and repeat both fixture and authenticated-status
   verification. The archive ID and active credential must still be unchanged.
10. Inspect sanitized request/diagnostic evidence and confirm that no token or
    signed object URL appears in URLs, logs, fixtures or routine output.

The operator must follow [Cloud operations](cloud.md), preserve the original
handoff across uncertain results, and keep every plaintext token out of this file,
GitHub comments and screenshots. Record exact reviewed/deployed commit IDs and UTC
timestamps when live evidence is added.

## Current acceptance state

- Repository implementation and deterministic tests: implemented; final review
  and full-tree gates pending.
- Deployed dev behavior, repeat deployment and fresh checkout: pending explicit
  owner-authorized execution.
- Personal deployment: out of scope and blocked by issue #32.
- Issue closure and #31 start: pending completion and owner acceptance of the live
  dev evidence above.
