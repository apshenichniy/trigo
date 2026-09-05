## Documentation language

Write all agent documentation in English, including agent instructions,
domain docs, ADRs, issue descriptions, specs, and planning documents.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues. Before working with tickets,
read `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels. Before triaging issues,
read `docs/agents/triage-labels.md`.

### Development workflow

Before refining or implementing a ticket, preparing a PR, or deploying,
read `docs/agents/development-workflow.md`.

### Effect development

Use the repository skill at `.agents/skills/effect` when writing Effect code.
Before editing Effect code, also read `repos/effect/LLMS.md` and inspect the
vendored source for idiomatic APIs and tests. Treat `repos/effect` as read-only
reference material: do not edit it or import application code from it. The
vendored revision must match the Effect version pinned in this repository.

### Domain docs

Use a single-context layout. Before exploring the codebase,
read `docs/agents/domain.md`.
