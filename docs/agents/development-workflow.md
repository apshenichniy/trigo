# Development workflow

The approved [development tooling and repository workflow](https://github.com/apshenichniy/trigo/issues/9#issuecomment-5552500745)
defines the tool choices, command interface, environments and acceptance evidence.
The [local verification amendment](https://github.com/apshenichniy/trigo/issues/85)
supersedes its automatic CI and hook rules during active development.
Read it before changing build, test, workspace or deployment configuration.
Its commands are implementation requirements until the foundation and
infrastructure tasks provide them; a decision's closure does not mean they exist.

## Before implementation

Read the ticket and comments, its canonical specification, domain documentation,
native dependencies and relevant current code. Proceed when the ticket is open,
ready, unblocked and unclaimed; assign it before starting work. Preserve unrelated
changes and use a scoped branch, with an isolated worktree for parallel work.

Assess whether a substantial owner decision remains: for example, UI interaction,
flow, error behavior or an acceptance condition. Internal implementation choices
remain with the agent when the agreed contract determines observable behavior.

## Optional refinement

The owner may request focused grilling before implementation. The agent must also
raise a substantial unresolved owner decision it discovers. Discuss the open
questions in the context of the same ticket, using grilling and domain-modeling.
Record agreed details and update acceptance criteria before implementation.

Use `needs-info` while a concrete owner decision prevents autonomous implementation;
list the unresolved questions. Restore `ready-for-agent` after agreement. Keep
native implementation dependencies separate from specification readiness. Possible
benefit from refinement alone is not a reason to demote every ticket.

Create a separate Wayfinder decision when the question crosses implementation
boundaries or changes the approved product contract. Generated implementation
tickets do not need to repeat the incoming-request triage process.

The local Matt skills fork's `plan-ticket` is an optional review of the technical
implementation approach after behavior is agreed. When used, its approved
`## Implementation Plan` comment is part of the handoff. A refinement or planning
session ends with recorded agreement; implementation starts on a separate owner
instruction. A sufficiently specified ticket can proceed directly to implementation.

## Implementation and handoff

Implement the agreed scope, run the relevant project checks and prepare a
reviewable PR with acceptance evidence. Distinguish local/CI verification from
deployed-provider and human-assisted checks. Keep human execution requirements
visible through `ready-for-human` where appropriate.

Merge and deployment require the owner's applicable explicit instruction. Install
the repository pre-push hook with `bun run hooks:install` (also installed by normal
package setup). Commit the stable candidate, run `bun run verify:push`, then push
and include its source/tree and result in the PR. A matching successful receipt
is reused by the hook. Keep the worktree clean during verification.

Before merging, fetch current main and incorporate it into the PR candidate if
needed. Verify that integration locally, then confirm that main has not moved
and the proposed merge tree matches the verified tree. Reconcile and verify again
if either changed; unchanged trees may reuse matching evidence.

Automatic GitHub Actions are paused during active development. Full Actions checks
remain an explicit manual operation; do not start a paid runner merely to repeat
matching local evidence. Main requires a pull request, while the local hook supplies
the development check boundary. It is not a server-enforced attestation. Report
actual failures and keep installed, GUI and hosted acceptance distinct.

## Verification loop

During implementation, run the affected quick checks and a focused reproducer.
For a timing or concurrency failure, first establish the failing boundary with a
small diagnostic test. Expand to contention/resource suites after the focused
test passes. Each repeated expensive run must answer a remaining hypothesis;
retain the first failure and its source identity in the evidence.

Use one warm integration checkout and one coordinated heavy-check executor for
an implementation candidate. Workers run focused checks in their own worktrees
and hand off the tested source state. Build directories, DerivedData and mutable
local state belong to their checkout. Recheck affected code after integration;
reuse completed evidence only while its inputs and integration context match.

Commit the implementation and tracked acceptance documentation before the final
local verification. Put subsequent receipt paths, source/tree, timings and outcomes
in the PR body and ignored local evidence. For an explicitly requested Actions run,
include its URL and results too. Evidence updates complete the handoff without a
new source commit. A source change requires the affected checks again; an
unchanged successful candidate needs no ceremonial rerun. Quick results identify
their scope and never substitute for the full acceptance gate.

See [verification commands and CI selection](../development/verification.md)
when choosing a suite, interpreting timings or changing required checks.

## Development and deployment targets

Ordinary local dev/check commands use local Workers/storage and fake ASR. Explicit
cloud operations select `dev` or `personal`; the personal archive and its desktop
app data/credentials remain separate from development data. Bootstrap and remote
state access follow the approved tooling resolution.

Coordinate one deployment writer per stack/stage, including other agents and
operators. Shared remote state does not imply a deployment lock. Complete an
admitted deployment before starting another writer for the same target.
