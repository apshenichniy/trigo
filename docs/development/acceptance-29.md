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

## Owner-authorized live evidence still required

No Cloudflare bootstrap, deployment, paid request or remote fixture write was run
while preparing the implementation. Complete these steps only after explicit owner
authorization and record command exit status, nonsensitive output, the fixture UUID
and exact tool versions:

1. First dev bootstrap and clean dev deployment.
2. Read-only infrastructure inspection proving private R2 and all required binding
   shapes without Workers AI inference.
3. Seed one dev-only R2/D1 fixture, repeat deployment, and verify the same fixture.
4. From a fresh checkout or machine with no copied local state credential, replay
   bootstrap, repeat the dev deployment, and verify the same fixture.
5. In an isolated disposable account/target, interrupt bootstrap, confirm safe
   replay, and confirm unrelated local/remote state is unchanged.
6. Demonstrate lost-local-cache recovery by re-deriving access to the existing
   state Worker. Do not simulate complete remote state or encryption-key loss; that
   belongs to issue #32.

The exact operator commands and recovery boundaries are in
[Cloud operations](cloud.md). Do not mark issue #29 accepted, deploy personal,
merge, or start issue #30 until the live evidence and review checkpoints are
owner-approved.
