# Development workflow

The approved [development tooling and repository workflow](https://github.com/apshenichniy/trigo/issues/9#issuecomment-5552500745)
defines the tool choices, command interface, environments and acceptance evidence.
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

Merge and deployment require the owner's explicit instruction. Required CI gates
merging; mandatory Git hooks are not part of the initial workflow. Report concrete
blockers rather than weakening the approved contract or presenting skipped work
as verified.

## Development and deployment targets

Ordinary local dev/check commands use local Workers/storage and fake ASR. Explicit
cloud operations select `dev` or `personal`; the personal archive and its desktop
app data/credentials remain separate from development data. Bootstrap and remote
state access follow the approved tooling resolution.

Coordinate one deployment writer per stack/stage, including other agents and
operators. Shared remote state does not imply a deployment lock. Complete an
admitted deployment before starting another writer for the same target.
