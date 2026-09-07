# Development setup

For ownership and the current product boundary, start with the
[architecture map](architecture.md). Historical acceptance documents record the
source tested at that time; this setup describes the supported current path.

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
mise exec -- bun run macos:setup
mise exec -- bun run check
```

Git is a prerequisite. Package setup can access registries; subsequent
ordinary development/checks require no cloud credentials or real ASR. Native
Swift dependencies are fetched from tracked resolutions by `macos:setup`; run it
after a clean clone or a dependency/toolchain cache miss. It never updates the
locks. Subsequent native builds/tests need no network access; automatic version
updates remain disabled. A clean clone or missing dependency needs network access
for setup before checking. The local Worker smoke retains its OS-enforced external
network denial. Native local smoke execution uses that same outer denial profile;
its SwiftPM invocation disables only nested manifest sandboxing. Other SwiftPM
and Xcode commands retain their own sandbox behavior.
Use `mise exec --` in a shell without mise activation.

| Tool/package                                       | Exact version          |
| -------------------------------------------------- | ---------------------- |
| mise bootstrap                                     | 2026.9.1               |
| Bun / Node                                         | 1.3.13 / 24.14.1       |
| XcodeGen (macOS only)                              | 2.46.0                 |
| Effect, platform-node, platform-bun, effect/vitest | 4.0.0-rc.112           |
| Effect TSGO / Oxlint TSGO bridge                   | 0.41.0 / 7.0.2001      |
| Alchemy                                            | 2.0.0-beta.76          |
| Vitest / Vite / TypeScript                         | 4.1.11 / 8.0.7 / 7.0.2 |
| Workers pool / Wrangler                            | 0.22.0 / 4.124.0       |
| Workers pool workerd                               | 1.20260815.1           |
| Alchemy runtime workerd                            | 1.20260704.1           |
| Oxlint / Oxfmt                                     | 1.81.0 / 0.66.0        |
| Ajv / ajv-formats                                  | 8.20.0 / 3.0.1         |
| Swift JSON Schema                                  | 0.13.1                 |

All other direct dependencies are exact in package manifests; transitive versions
are in `bun.lock` and the three Swift resolution files. Effect's platform packages
are required by the Alchemy CLI/runtime, not by the Worker. Vitest 5 is outside the
accepted peer range. The two workerd versions are deliberately independent.

## Effect development tooling

See [code style](code-style.md) for TypeScript and Swift readability rules,
format-on-save setup, and the distinction between formatting and structural review.

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
watching, auto-imports and ordinary ripgrep searches exclude `repos/`. Inspect the
reference explicitly with `rg --no-ignore <pattern> repos/effect/<path>`; it remains
tracked and read-only. Repository formatting ignores both
vendored source and imported agent skills.

## Command interface

All commands use `bun run <command>` from the checkout root and propagate errors.
Root doctor/format/lint/typecheck/test/build/check commands take no arguments.
For quick checks, explicit native suites, timing interpretation and CI selection,
see [verification](verification.md).
Wrappers reject unknown options, duplicate selectors and missing values rather
than silently ignoring them. Use separate `--option value` arguments; options
are not forwarded to Xcode or Alchemy. Vitest component commands (`test:unit` and
`test:workers`) retain Vitest's own filtering options.

| Command                                                                              | Behavior                                                                             |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `doctor`                                                                             | Read-only selected tools and local-target diagnostics                                |
| `format` / `format:check`                                                            | Apply/check Oxfmt and bundled Swift formatting                                       |
| `lint`                                                                               | Oxlint and strict Swift formatting checks                                            |
| `typecheck`                                                                          | Strict TypeScript and locked native Swift compilation                                |
| `test`                                                                               | Node/Effect, Workers, shared Swift fixtures, native logic, Alchemy local smoke       |
| `build`                                                                              | Local and cloud Worker bundles and both app variants                                 |
| `check`                                                                              | Complete macOS gate: format, lint, types, generation, tests and builds               |
| `check:server`                                                                       | Portable Linux/macOS TS/contracts/Workers checks and bundle                          |
| `check:macos`                                                                        | Native style/conformance/tests, both apps and Alchemy local smoke                    |
| `contracts:generate` / `contracts:check`                                             | Explicit regeneration / in-memory generation and comparison                          |
| `dev`                                                                                | Shared product API, local D1/R2/workflow and fake ASR                                |
| `test:local`                                                                         | Disposable composition, authenticated API and persistent restart                     |
| `macos:build --variant dev`                                                          | Locked build (`personal` also supported)                                             |
| `macos:install --variant dev`                                                        | Build/install without launching; requires stable signing or explicit `--ad-hoc`      |
| `macos:run --variant dev`                                                            | Build, install and open stable development app                                       |
| `macos:archive --variant dev`                                                        | Reproducible unsigned archive unless a signing team is selected                      |
| `macos:setup`                                                                        | Resolve the pinned native dependency graphs and restore the generated project lock   |
| `macos:dependencies`                                                                 | Explicit Swift dependency update and app lock refresh                                |
| `cloud:preflight --stage dev`                                                        | Read-only validation of the stage configuration and dedicated Alchemy profile        |
| `cloud:bootstrap --stage dev`                                                        | Explicit-profile Cloudflare remote-state bootstrap; see [cloud operations](cloud.md) |
| `cloud:deploy --stage dev`                                                           | Deploy isolated dev R2, D1, Workflow, AI binding and Worker                          |
| `cloud:owner:init --stage dev --handoff <absolute-path>`                             | Initialize or exactly replay archive identity and the first owner verifier           |
| `cloud:owner:rotate --stage dev --handoff <absolute-path> --expected-generation <n>` | Atomically replace the owner verifier through a private handoff                      |
| `cloud:owner:revoke --stage dev --handoff <absolute-path> --expected-generation <n>` | Atomically revoke the owner verifier; the handoff contains no token                  |
| `test:cloud --stage dev`                                                             | Read-only infrastructure checks, fixture seed/verify and owner-status modes          |
| `test:asr --stage dev --handoff <absolute-path> [--language en\|ru\|uk]`             | Explicit live Nova-3 probe; controlled synthetic audio, no automatic retries         |

The full check fails on Linux rather than silently skipping macOS. Verification
may create ignored build outputs/caches; it must not rewrite tracked sources or
locks. CI starts on every PR and `main` change and selects the affected component
checks after the protected `All checks` migration described in
[verification](verification.md). Required merge checks must be configured
separately in repository rules; a green workflow does not prove that branch
protection exists. Merge/deployment require the owner's instruction.
Cloud commands are never part of `doctor`, `check`, `dev`, or offline CI; their
credentials, recovery procedure and acceptance sequence are documented separately
in [Cloud operations](cloud.md).

`test:asr` is a live, potentially billable acceptance command and is never part of
the default verification graph. It targets only the isolated dev stage, requires
a private dev owner handoff matching the selected deployment, and creates a fresh controlled synthetic
fixture for each selected language. Without `--language` it attempts `en`, `ru`,
and `uk` once each; the selector narrows the set to one language. Before running
it, reserve the bounded request set in the active Goal ledger and confirm that
actual plus reserved spend remains within the approved ceiling. Afterward, record
the conservative actual result and release unused reservation. The command never
retries automatically, and the deployed fixture marker rejects a sequential repeat.

## Clean test archive

Use a fresh worktree for the refactored development archive, then follow the local
runtime sequence below. Its generated bridge selects a fresh disposable local
namespace; `dev` preserves that namespace across restarts. Do not move an old
`Archive` directory or copy ordinary Dev/personal connection metadata into it.

The current repository stores `Archive/archive.sqlite3` at schema version 2, with
media under `Archive/<call-id>/media/`. An old file archive, older/unknown SQL
schema, foreign identity or corrupt store fails explicitly without resetting or
migrating it. A failed open is not permission to delete data. Keep the prior test
namespace intact and choose a new worktree/bridge instead. No private/personal
archive cutover is authorized by this development workflow.

## Local runtime

`dev` uses the closed composition in `infra/local.ts`: a loopback Worker, D1,
R2 and a local workflow. Local and cloud Workers delegate `/v1/` to the same
Effect HttpApi handler. The supported product endpoint is authenticated
`GET /v1/status`; upload, transcription and synchronization remain unavailable.
The local status keeps transcription `not_verified` and call operations
`unavailable`. Deterministic fake ASR is an adapter result, not provider readiness.

The launcher passes an environment allowlist and deliberately invalid
Cloudflare-shaped credentials required by Alchemy's local providers. It selects
a reserved `trigo-local-<worktree>` profile with `CI=1`; no interactive login,
operator profile, remote state, Workers AI binding or provider call is used.
Alchemy may create local profile metadata (`method: env`) in
`~/.alchemy/profiles.json`; it does not store a token there. Reserve the
`trigo-local-` prefix for this harness. Unsupported resources must fail instead
of opting into remote fallback.

State lives under `.local/<hash-of-real-worktree-path>/.alchemy`. A separate
mode-0600 `connection.json` in that directory holds a generated **local test**
owner token, the loopback origin, worktree ID and disposable namespace ID. Only
the token verifier reaches the Worker; the launcher does not print the token.
The configuration and local archive identity survive server restart. The same
file must keep the same port; choose a new disposable local namespace instead of
silently changing an existing binding. Tests create and remove their own
fresh temporary directory.

```sh
bun run dev
# In another terminal, select your existing Apple Development team:
export TRIGO_SIGNING_TEAM=YOURTEAMID
# Run the exact command printed by dev:
bun run macos:run --variant dev --local-config /absolute/path/printed/by/dev/connection.json
```

A local installation uses `~/Applications/Trigo Local Dev <worktree>.app`, leaving
ordinary `Trigo Dev.app` and `Trigo.app` in place. Its Dev bundle ID/signing requirement
still shares macOS permission identity with ordinary Dev; data isolation is not
OS permission isolation. The installed development app opens with the local URL/token prefilled. Click
**Connect** to authenticate and establish the first binding. It uses a namespace
ending in `.local.<UUID>`, separate from both the ordinary worktree Dev cloud
binding and personal data, preferences and Keychain service. Normal installed
credential storage still uses Keychain. Keep the local server running while
pairing; later unavailable/unauthorized status keeps the durable binding and
local recording eligibility.

The private bridge uses the shared Effect-authored `LocalDevelopmentBridge`
contract and its generated Swift model. Both readers reject unknown fields and
invalid namespace/token values before applying contextual file/worktree policy.
It is dev-only and accepts exactly its configured
`http://127.0.0.1:<port>` origin, with ports 1024–65535. It rejects other ports,
`localhost`, IPv6, other IP addresses, paths, credentials, queries and fragments.
The same rule applies before URLSession transport and when restoring metadata.
Ordinary Dev and personal connections remain HTTPS-only. The Dev app has the
Boolean [`NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
ATS setting; application policy limits the HTTP exception to that explicit
loopback bridge. Personal builds retain default ATS. Redirects are rejected.

`TRIGO_LOCAL_PORT` selects the server port (default 19371; tests select a fresh
available port). The runtime binds only to `127.0.0.1` and fails on collisions.
A per-launch run ID verifies the selected process. On macOS the launcher denies
external networking for both the entire Alchemy/workerd child process tree and
the optional native-client test execution. The launcher uses its parent check's
verified current-source build, or builds the locked native tests itself when run
independently, then runs them with
`--skip-build` inside the outer sandbox. That execution disables only SwiftPM's
nested manifest sandbox; the outer network-denial profile stays active. Workers
pool tests independently deny outbound requests. Linux keeps the explicit local
resource and credential restrictions; macOS supplies the OS-enforced network
denial evidence.

```sh
bun run test:local
bun run test:local --native-client  # macOS; included in check:macos and check
```

The smoke checks authenticated status, unauthorized and unavailable operations,
D1 identity, a real local workflow producing a canonical fake no-speech revision,
R2 exact-byte readback, and persistence of all three bindings after restart.
`--native-client` also checks actual URLSession pairing and file-metadata restore
against that Worker in a disposable namespace with an in-memory test credential
adapter. It never reads installed/personal credentials, opens an installed app,
or requests capture permissions. Installed signing, ATS and physical system
consent remain the separate owner-assisted acceptance gate.

`/__local/health` initializes/replays the isolated local owner identity and
reports the active run ID. `__local/probe` routes are gated infrastructure
acceptance helpers, not product transcription endpoints. The old
`/__local/transcriptions/*` fixture API is removed. Do not deploy the local Worker
as a production API.

## Native variants and signing

The native check runs every native suite in Release so long-call fixtures retain
their full duration at optimized speed. The separate Swift contract suite and
both app builds remain Debug. A current-source build precedes suite discovery;
the suite groups and parent check's native smoke reuse that validated build.
Resource proofs execute in separate processes. Standalone native smoke builds
current sources itself. See [verification](verification.md) for current selection,
reuse and cache behavior, and [issue #49 evidence](acceptance-49.md) for the earlier
cache baseline.

`macos:setup` restores the generated project lock and resolves the locked SwiftPM
and Xcode graphs. It is distinct from `macos:dependencies`, which intentionally
updates dependency versions. `bun scripts/macos.ts prepare` only generates the
project and restores its nested lock; it is also the cache-hit lock-repair probe.
Native checks print phase durations. Set `TRIGO_TIMINGS_FILE` to an ignored JSONL
file to retain them; GitHub Actions also includes them in the job summary.

| Variant     | Bundle ID / shared scheme                        | Install path                   |
| ----------- | ------------------------------------------------ | ------------------------------ |
| Personal    | `io.github.apshenichniy.trigo` / `Trigo`         | `~/Applications/Trigo.app`     |
| Development | `io.github.apshenichniy.trigo.dev` / `Trigo Dev` | `~/Applications/Trigo Dev.app` |

`AppNamespace` places `Archive` and `connection.json` under
`~/Library/Application Support/<namespace>/`. Its reserved `Journal` path is no
longer the operation store: archive metadata, lifecycle and durable work all live
in `Archive/archive.sqlite3`. Preferences use the namespace as
suite name; Keychain uses `<namespace>.connection-token`. Personal uses its bundle
ID; development appends the build's worktree identifier. Test namespaces are
UUID-based disposable locations. Checks and builds request no capture permissions.

The app's ordinary Archive connection screen accepts an HTTPS origin and owner token.
The explicit local bridge above has its own bounded origin policy. A
successful authenticated status check establishes the archive binding before local
recording becomes eligible. `connection.json` stores only the canonical server
origin, archive ID, stage and an opaque Keychain account reference; the token is a
generic password in the namespace-specific Keychain service. URL/token replacement
is allowed only when status reports the already-bound archive. Later network,
authentication or compatibility failures preserve the binding and local-recording
eligibility while blocking server operations. Use **Retry saved connection** to
validate the persisted Keychain credential without re-entering it.

Interrupted metadata/Keychain transactions are recovered on launch and before a
new candidate is attempted. An unchanged URL/token, validated against the same
archive, reuses its exact committed item. Genuine changes and known unreadable-token
repair use the existing pending/committed/retired transaction. Access-denied,
interaction-required and unknown read errors preserve the item and provide a retry
action. Missing credentials remain distinct from inaccessible credentials.
Do not edit `connection.json`, copy a token between namespaces or use a personal
handoff with the development app. The live cloud protocol test now uses disposable
file metadata and an in-memory credential adapter; it cannot create regular app-owned
Keychain items. Historical [Issue #31 evidence](acceptance-31.md) describes its earlier
helper. Current ownership and installed acceptance are in [Issue #55](acceptance-55.md).

Operator ASR probes require an explicit private dev handoff:
`bun run test:asr --stage dev --handoff /absolute/path/to/dev-owner-handoff.json`.
The handoff must match the configured dev account/database/deployment. No service-only
or other app Keychain lookup is used. The existing explicit paid-probe authorization,
budget and generation controls still apply.

Set `TRIGO_SIGNING_TEAM` to an existing Apple Development team for regular installed
capture development; the corresponding certificate must exist in Keychain.
Without it, `macos:run` and `macos:install` fail with an actionable message.
For a disposable ad-hoc installation, unset `TRIGO_SIGNING_TEAM` and pass `--ad-hoc`
explicitly. macOS may request permissions again after a rebuild: stable path and
bundle ID alone do not establish TCC or Keychain continuity. The installer verifies
the signature, requires the destination app to be quit, and refuses another bundle
identity or changed designated requirement on a normal signed update. Switching a
shared ordinary Dev installation between worktrees requires `--replace-worktree`;
it changes the selected development namespace and does not migrate any data.
A failed or interrupted installation retains staging/backup paths for review.
`--replace-worktree` applies only to `macos:install`/`macos:run`; `--local-config`
applies only to dev build/install/run; `--ad-hoc` applies only to build/archive/
install/run. `--variant dev|personal` is accepted by all native actions.
Ordinary builds, tests and CI need no owner signing credentials. Public Developer ID signing, notarization, Amore/Sparkle and release
publication remain #4. Archives live under `.local/archives/`.

Use **Capture readiness** in the connection window or recording panel before a call.
Enable screen/system-audio and microphone access separately. Application readiness
code makes explicit authorization requests only through Enable actions; Start and
lifecycle refreshes check readiness. Invoking ScreenCaptureKit may independently
display macOS-controlled consent/reminder UI even when CoreGraphics preflight
reports granted access. Return from Settings or click **Refresh readiness** after
changing access. Microphone denial/restriction,
input-device absence and effective recording mute are separate states. Screen
preflight false means access is required; it does not identify denial versus revocation.
The supported capture adapter remains ScreenCaptureKit. See the controlled
[installed acceptance procedure](acceptance-55.md#installed-acceptance-procedure) for
observations that require the owner's Mac. The later [owner observation](acceptance-55.md#scope-and-diagnosis)
identifies Trigo Dev direct screen/system-audio consent/reminder UI, with **Allow**
and **Open System Settings** buttons. No Allow action is confirmed; repeated prompt
cadence and the cause of the earlier recurrence remain unconfirmed. The
[installed #57 record](acceptance-57.md) distinguishes performed unchanged
relaunch/validation and supported signed rebuild evidence, using the same worktree,
bridge, app path and signing identity. A local CLI smoke or mocked permission test
does not establish OS or app-owned Keychain continuity. Physical permission
revocation and microphone unplug/reconnect were not exercised; the owner had only
the built-in microphone. Intermittent installed startup overflow remains an
unresolved, owner-deferred [follow-up](https://github.com/apshenichniy/trigo/issues/60).

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
