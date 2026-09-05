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
- Shared conformance has 43 valid/invalid cases with identical Swift/TS results;
  Node suite has 56 tests, Workers suite four, Swift contracts two aggregate tests
  (including all fixtures), native logic one. Later changes must refresh counts.
- Both `Trigo` and `Trigo Dev` build without owner signing credentials. Native
  tests establish separate archive, journal, connection, preferences and Keychain
  namespaces, including worktree separation for development.
- Stored-byte tests use the published SHA-256 `abc` vector, distinct whitespace,
  malformed JSON/UTF-8, missing references and rejected checksum mismatches.
- Unavailable cloud/provider commands return nonzero and identify #12/#13.
  `dev --stage personal` is rejected before starting a process.

## Review and CI corrections

Independent Standards review found two maintenance duplications in native tool/lock
checks; both were consolidated. Spec review found a smoke-port ownership hole and
missing cross-revision turn/speaker uniqueness. Both now have regression coverage
and passed the reviewer recheck. Installed-bundle inspection found that Xcode omitted
a custom Info key; explicit generated plists and post-build identity checks correct it.

The first GitHub run exposed an undeclared `rg` prerequisite on macOS and a Workers
cold-start timeout on Linux. Wrappers now use Git's file inventory; the Worker starts
in a bounded setup hook before persistence assertions. These are recorded failures,
not completed CI acceptance. The next macOS run exposed missing profile metadata
on a fresh runner: the launcher now selects a dedicated local profile and explicitly
uses noninteractive environment credentials containing only invalid local values.

## Delivery verification

- A fresh worktree at `97b128734` completed mise selection, frozen Bun install,
  full macOS check, and cache-hit build after deliberate nested-lock removal.
  The clean worktree then repeated frozen install/full check at `a184361e0`,
  including first-time creation of its dedicated noninteractive local profile.
  `git diff --exit-code` and all wrapper lock snapshots were unchanged.
- Both variants were installed and opened at their documented paths. Actual
  bundle IDs are `io.github.apshenichniy.trigo` and
  `io.github.apshenichniy.trigo.dev`; the development bundle contains worktree ID
  `5c8904ac791e`. Both pass `codesign --verify --deep --strict` with ad-hoc signing.
- `macos:archive --variant dev` completed and its bundle identity checks passed.
  The shared scheme and locked archive are suitable foundations for later release
  tooling, not evidence of public signing/distribution or capture permissions.
- Both independent review findings sets were addressed; see [review report](review-11.md).
- The exact final CI results and run links are maintained on [PR #25](https://github.com/apshenichniy/trigo/pull/25).
  Previous failed runs and their concrete corrections are retained above. Local
  checks are not substituted for actual Linux/macOS CI execution.
- Main branch protection was configured and read back: required contexts
  `Server checks` and `macOS checks`, strict/up-to-date checks, enforcement for
  administrators, no force pushes or deletion. Initial remote `main` contains only
  the pre-existing documentation commit; implementation remains on the PR branch.

No cloud provisioning, deployment, paid ASR, capture, permission-continuity test,
public distribution or merge has been performed. Issue #11 remains open for the
owner's closure workflow. The foundation is not the complete application epic.
