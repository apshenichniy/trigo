# Cloud infrastructure acceptance — issue #29

Implementation scope: [issue #29](https://github.com/apshenichniy/trigo/issues/29)
and the [owner-approved parent plan](https://github.com/apshenichniy/trigo/issues/12#issuecomment-5553492321).

## Local evidence (2026-09-05)

- Stable `dev` and `personal` stage/profile/resource mappings are covered by unit
  tests. The cloud wrapper rejects a missing stage, missing/invalid configuration,
  profile mismatch, unsafe API URL, unsupported deploy arguments, personal fixture
  use and a first personal deployment before issue #32.
- The cloud Worker pool tests prove that infrastructure diagnostics do not call R2,
  D1, Workflow or Workers AI, and that `/v1/*` remains unavailable for issue #30.
- The dev-only verifier has injected-boundary tests for deployment inspection,
  private R2 checks, exact R2/D1 seed/readback and child-process failure handling.
- The separate Alchemy cloud entrypoint bundles the cloud Worker and provisions
  private retained R2, retained D1, a Workflow binding, Workers AI binding and an
  isolated Worker. Existing offline local composition and its checks remain
  separate.
- `doctor` is read-only and reports that cloud commands need an explicit stage and
  configuration. It does not initialize Alchemy cloud state or recover a state
  credential.

## Owner-authorized live evidence (2026-09-05)

The non-destructive dev sequence ran against Cloudflare account
`27940cd0d92bb3f03943a5378ccf68d3` with the dedicated `trigo-cloud-dev` environment
profile. Every command obtained the API token from macOS Keychain only in its
process environment; no token or state credential was printed or copied into the
repository.

- Selected versions were Bun 1.3.13, Node v24.14.1, Alchemy 2.0.0-beta.76 and
  Wrangler 4.124.0. The project preflight and Wrangler account check both exited
  zero before the first mutation.
- Bootstrap found the expected account-wide `alchemy-state-store` Worker, adopted
  it without `--force`, and created the local state credential cache. It did not
  redeploy or replace the state Worker.
- The first `dev` deployment planned and created exactly four declarations: the
  `trigo-dev-api` Worker, `trigo-dev-archive` R2 bucket, `trigo-dev-catalog` D1
  database (`ad0438e9-6540-4a46-82b8-d74ca1db4b3d`), and
  `trigo-dev-archive-workflow` Workflow. Its Worker origin is
  `https://trigo-dev-api.alexander-pshenichniy-279.workers.dev`.
- Read-only inspection reported deployment identity
  `trigo-dev-api:e2e8f715929a689b`, disabled R2 development URL, zero R2 custom
  domains, and configured R2, D1 and Workflow bindings. The Workers AI binding was
  present but inference was not invoked.
- UUIDv4 `763b983c-96a3-4f4e-9991-56333557d314` was written only to dev R2 object
  `acceptance/issue-29/763b983c-96a3-4f4e-9991-56333557d314.json` and the dev D1
  fixture table. A repeat deployment reported `no change` for all four declarations,
  after which both stores returned that exact UUID.
- A fresh clone at commit `dee1c39b532b733a3b5919c99f5e1ad8a5e2ade0` installed
  from the tracked lockfile and passed the project preflight. With the existing
  local state credential moved aside and confirmed absent, bootstrap again adopted
  the same state Worker and re-derived the credential. Deployment from the fresh
  clone reported `no change` for every declaration, and the same UUID was verified
  from R2 and D1. The stale credential backup was deleted without being read, and
  the temporary clone was moved to Trash.
- No live cloud command failed or requested destructive recovery. The task cost
  ledger remained EUR 0 actual and EUR 0 reserved; no paid ASR or other provider
  probe ran. Cloudflare dashboard billing was not independently queried.

## Remaining owner-gated live evidence

The isolated disposable-account interrupted-bootstrap experiment remains unrun.
It deliberately interrupts and replays cloud mutation and therefore still requires
the separately approved destructive boundary established by the parent plan. Its
fail-closed local seam and assertions are implemented in
`scripts/cloud-bootstrap-interruption.ts`; they do not call Cloudflare or expose a
destructive action through the project wrapper. The approved free-tier disposable
account is `Trigo Recovery Disposable`
(`3fd3cd769d5d372e6757d0ec208a74f2`). Execution still waits for its dedicated
account-restricted credential and sole-writer handoff.

The exact operator commands and recovery boundaries are in
[Cloud operations](cloud.md). Do not mark issue #29 accepted, deploy personal,
merge, or start issue #30 until the remaining experiment and live evidence review
are owner-approved.
