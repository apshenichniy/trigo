# Development setup

## Supported toolchain

The implementation gate for #11 ran on macOS with Xcode 26.6 (17F113), Swift 6.3.3,
and bundled `swift format` 6.3.0. The application deployment floor is macOS 15.
Xcode must be installed separately; select it with `DEVELOPER_DIR` or `xcode-select`.
Install [mise 2026.9.1](https://github.com/jdx/mise/releases/tag/v2026.9.1), add its
binary to PATH, and activate mise in your shell. Then, from this checkout:

```sh
mise trust
mise install
mise exec -- bun install --frozen-lockfile
mise exec -- bun run doctor
mise exec -- bun run check
```

Git is a prerequisite. Package setup can access registries; subsequent
ordinary development/checks require no cloud credentials or real ASR. Native
Swift dependencies are fetched automatically from tracked resolutions on the
first build. A clean clone needs network access for that dependency fetch.
Use `mise exec --` in a shell without mise activation.

| Tool/package                                       | Exact version           |
| -------------------------------------------------- | ----------------------- |
| mise bootstrap                                     | 2026.9.1                |
| Bun / Node                                         | 1.3.13 / 24.14.1        |
| XcodeGen (macOS only)                              | 2.46.0                  |
| Effect, platform-node, platform-bun, effect/vitest | 4.0.0-rc.112            |
| Effect TSGO / Oxlint TSGO bridge                   | 0.41.0 / 7.0.2001       |
| Alchemy                                            | 2.0.0-beta.76           |
| Vitest / Vite / TypeScript                         | 4.1.11 / 8.0.7 / 7.0.2  |
| Workers pool / Wrangler                            | 0.22.0 / 4.124.0        |
| Workers pool workerd                               | 1.20260815.1            |
| Alchemy runtime workerd                            | 1.20260704.1            |
| Oxlint / Oxfmt                                     | 1.81.0 / 0.66.0         |
| Ajv / ajv-formats / json-schema-to-typescript      | 8.20.0 / 3.0.1 / 16.0.0 |
| Swift JSON Schema                                  | 0.13.1                  |

All other direct dependencies are exact in package manifests; transitive versions
are in `bun.lock` and the three Swift resolution files. Effect's platform packages
are required by the Alchemy CLI/runtime, not by the Worker. Vitest 5 is outside the
accepted peer range. The two workerd versions are deliberately independent.

## Effect development tooling

The repository pins the Effect Language Service through `@effect/tsgo`. The root
`prepare` script patches the workspace TypeScript 7 and Oxlint installations after
every package install. `tsconfig.json` enables language-service completions,
quick info and refactors; Effect diagnostics come from the type-aware Oxlint
`effecttsgo` plugin so that they are not reported twice. The ordinary `lint` and
`check` commands therefore include Effect-specific diagnostics.

`lint` denies warnings. Effect-owned production modules must therefore address
the recommended diagnostics rather than accumulating advisory output. The
tracked Oxlint overrides are intentionally narrow: repository orchestration
scripts may use Node/Bun platform APIs, the shared contracts package retains its
cross-runtime Promise API, and external Workers/Vitest harnesses retain their
native asynchronous interfaces. Do not broaden these overrides to application
logic; add a boundary-specific exception only when adopting an Effect API would
change the platform contract or introduce an inappropriate runtime dependency.

VS Code-based editors use the workspace TypeScript-Go installation through the
tracked `.vscode/settings.json`. Install the TypeScript 7 editor extension and
confirm that the workspace version is active. The optional Effect VS Code
extension adds debugger views, but it does not contain the language service and
is not required for repository checks.

The repo-scoped Effect skill lives at `.agents/skills/effect` and was imported
from `kitlangton/skills` commit `22c35cb7fd29f931789253fc3c8eb142f2863a8a`.
Codex discovers it from the repository root; no user-level installation is
required.

## Vendored Effect reference

`repos/effect` is a read-only squash subtree of Effect tag
`effect@4.0.0-rc.112` (`2600f62f4532026928454dcea8d1c48557b3f942`). It
matches the runtime packages pinned by this repository. Agents should read its
`LLMS.md`, implementation, tests and examples when documentation or installed
declarations are insufficient, but application code must continue importing
normal package dependencies.

Update the subtree only as part of the same reviewed change that updates the
Effect package pins:

```sh
git subtree pull --prefix=repos/effect \
  https://github.com/Effect-TS/effect.git effect@<version> --squash
```

Do not track Effect `main` independently: source newer than the installed package
can teach agents APIs that the application cannot compile. Editor search, file
watching and auto-imports exclude `repos/`, and repository formatting ignores both
vendored source and imported agent skills.

## Command interface

All commands use `bun run <command>` and propagate errors.

| Command                                                                              | Behavior                                                                             |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `doctor`                                                                             | Read-only selected tools and local-target diagnostics                                |
| `format` / `format:check`                                                            | Apply/check Oxfmt and bundled Swift formatting                                       |
| `lint`                                                                               | Oxlint and strict Swift formatting checks                                            |
| `typecheck`                                                                          | Strict TypeScript and locked native Swift compilation                                |
| `test`                                                                               | Node/Effect, Workers, shared Swift fixtures, native logic, Alchemy local smoke       |
| `build`                                                                              | Local Worker bundle and both app variants                                            |
| `check`                                                                              | Complete macOS gate: format, lint, types, generation, tests and builds               |
| `check:server`                                                                       | Portable Linux/macOS TS/contracts/Workers checks and bundle                          |
| `check:macos`                                                                        | Native style/conformance/tests, both apps and Alchemy local smoke                    |
| `contracts:generate` / `contracts:check`                                             | Explicit regeneration / temporary regeneration and comparison                        |
| `dev`                                                                                | Loopback Alchemy Worker, worktree-local R2 and fake ASR                              |
| `test:local`                                                                         | Disposable Alchemy composition and R2 readback                                       |
| `macos:build --variant dev`                                                          | Locked build (`personal` also supported)                                             |
| `macos:run --variant dev`                                                            | Build, install and open stable development app                                       |
| `macos:archive --variant dev`                                                        | Reproducible unsigned archive unless a signing team is selected                      |
| `macos:dependencies`                                                                 | Explicit Swift dependency update and app lock refresh                                |
| `cloud:preflight --stage dev`                                                        | Read-only validation of the stage configuration and dedicated Alchemy profile        |
| `cloud:bootstrap --stage dev`                                                        | Explicit-profile Cloudflare remote-state bootstrap; see [cloud operations](cloud.md) |
| `cloud:deploy --stage dev`                                                           | Deploy isolated dev R2, D1, Workflow, AI binding and Worker                          |
| `cloud:owner:init --stage dev --handoff <absolute-path>`                             | Initialize or exactly replay archive identity and the first owner verifier           |
| `cloud:owner:rotate --stage dev --handoff <absolute-path> --expected-generation <n>` | Atomically replace the owner verifier through a private handoff                      |
| `cloud:owner:revoke --stage dev --handoff <absolute-path> --expected-generation <n>` | Atomically revoke the owner verifier; the handoff contains no token                  |
| `test:cloud --stage dev`                                                             | Read-only infrastructure checks, fixture seed/verify and owner-status modes          |
| `test:asr --stage dev`                                                               | Nonzero placeholder; #13 owns paid provider probes                                   |

The full check fails on Linux rather than silently skipping macOS. Verification
may create ignored build outputs/caches; it must not rewrite tracked sources or
locks. CI runs both jobs on every PR and `main` change. Required merge checks must
be configured separately in repository rules; a green workflow does not prove
that branch protection exists. Merge/deployment require the owner's instruction.
Cloud commands are never part of `doctor`, `check`, `dev`, or offline CI; their
credentials, recovery procedure and acceptance sequence are documented separately
in [Cloud operations](cloud.md).

## Local runtime

`dev` uses the closed composition in `infra/local.ts`, restricted to a Worker and
R2. It accepts no arbitrary resources or cloud stage. The launcher passes an
environment allowlist and deliberately invalid account/token values because the
Alchemy local providers still require auth-shaped configuration. These values
provide no account access. The launcher selects a reserved `trigo-local-<worktree>`
profile and `CI=1` so a fresh machine needs no interactive login. Alchemy may create
local profile metadata (`method: env`) in `~/.alchemy/profiles.json`; no token is
stored there. Reserve the `trigo-local-` prefix for this harness, never operator
credentials. Default/operator profiles are not selected. No AI binding or remote
state store is created.

State lives under `.local/<hash-of-real-worktree-path>/.alchemy`; tests use a
fresh temporary directory. `TRIGO_LOCAL_PORT` selects a port (default 19371; smoke
uses a fresh available port). Both bind only to 127.0.0.1 and fail on collisions. A per-launch nonce verifies that
smoke requests reach the runtime created by that test. On macOS the launcher
also denies external network access for the entire child process tree using the
OS sandbox. Workers pool tests independently deny outbound service requests.
The Linux composition retains the resource/credential restrictions; the macOS
smoke is the evidence for Alchemy execution under an OS-enforced network denial.

```sh
bun run dev
curl http://127.0.0.1:19371/__local/health
curl -X POST http://127.0.0.1:19371/__local/transcriptions/no-speech
curl http://127.0.0.1:19371/__local/transcriptions/no-speech
```

These fixture routes are local harness operations, not an authenticated product
API. `/v1` endpoint behavior belongs to its owning implementation issue. Do not
publish the local Worker as a production API. Supported local composition changes
must include a smoke test under external-network denial; unsupported resources
must fail, never opt into Alchemy's remote fallback.

## Native variants and signing

| Variant     | Bundle ID / shared scheme                        | Install path                   |
| ----------- | ------------------------------------------------ | ------------------------------ |
| Personal    | `io.github.apshenichniy.trigo` / `Trigo`         | `~/Applications/Trigo.app`     |
| Development | `io.github.apshenichniy.trigo.dev` / `Trigo Dev` | `~/Applications/Trigo Dev.app` |

`AppNamespace` defines `Archive`, `Journal` and `connection.json` under
`~/Library/Application Support/<namespace>/`. Preferences use the namespace as
suite name; Keychain uses `<namespace>.connection-token`. Personal uses its bundle
ID; development appends the build's worktree identifier. Test namespaces are
UUID-based disposable locations. Actual archive persistence, token storage and
connection setup belong to #14/#12. The shell requests no capture permissions.

Set `TRIGO_SIGNING_TEAM` to an existing Apple Development team for regular installed
capture development; the corresponding certificate must exist in Keychain.
Without it, `macos:run` uses ad-hoc signing and stable installation paths. macOS
may request permissions again after a rebuild: stable path and bundle ID alone do
not establish TCC continuity. Ordinary builds, tests and CI need no owner signing
credentials. Public Developer ID signing, notarization, Amore/Sparkle and release
publication remain #4. Archives live under `.local/archives/`.

## Generation and dependency updates

Edit `project.yml`, never the generated Xcode project. Run the wrapper once before
opening the generated project in Xcode: it embeds the worktree namespace for
normal Xcode debugging as well as terminal builds. Every build/archive restores
`apps/macos/Locks/Package.resolved` into the generated project's shared SwiftPM
location, including cache hits. Xcode uses locked resolution with package updates
disabled. Swift CLI builds separately use the contracts/native package locks.
With an entirely local top-level package Xcode 26.6 may not emit its own nested
resolution on an explicit resolve; dependency update then seeds the canonical app
lock from the native package's resolved graph. All three locks are tracked and
must agree on pins. Builds fail if the canonical lock is missing or changes.

Update JS tools/packages only in an explicit reviewed dependency change: edit exact
pins, `bun install`, and run the full gate. `macos:dependencies` is the explicit
Swift update operation; it is not run by checks. After editing schemas run
`contracts:generate`, review artifacts, and run shared conformance. Immutable
fixture bytes are excluded from formatting because changing whitespace changes
their checksums. Update the references intentionally when changing a fixture.
