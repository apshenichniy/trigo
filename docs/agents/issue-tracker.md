# Issue tracker: GitHub

Issues and specs live in this repository's GitHub Issues.
Use the `gh` CLI from the repository; it resolves the repository
from the Git remote.

## Operations

- Create: `gh issue create --title "..." --body-file <file>`.
- Read: `gh issue view <number> --comments`; include labels when
  requesting structured output.
- List: `gh issue list --state open --json number,title,body,labels,comments`.
  Apply state and label filters as needed.
- Comment: `gh issue comment <number> --body-file <file>`.
- Label: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- Close: `gh issue close <number>`.

For multiline bodies, write the exact Markdown to a temporary file
and pass it with `--body-file`.

"Publish to the issue tracker" means create a GitHub issue.
"Fetch the relevant ticket" means read the issue and its comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares issue and PR numbers. When the type is unclear,
try `gh pr view <number>`, then fall back to `gh issue view <number>`.

## Wayfinding

- Keep the map in one issue labelled `wayfinder:map`, with Notes,
  Decisions-so-far, and Fog sections.
- Link child tickets as GitHub sub-issues. If unavailable, use a task
  list in the map and `Part of #<map>` in each child.
- Label children `wayfinder:<type>`, where type is research,
  prototype, grilling, or task.
- Record blockers using native GitHub issue dependencies. If unavailable,
  add `Blocked by: #<number>` lines to the child.
- Choose the first open, unassigned child in map order whose blockers
  are all closed.
- Claim with `gh issue edit <number> --add-assignee @me`.
- Resolve by commenting with the answer, closing the child, and adding
  a short finding and link to the map's Decisions-so-far.
