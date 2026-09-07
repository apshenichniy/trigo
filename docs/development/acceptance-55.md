# Issue #55: capture readiness and app-owned credentials

## Scope and diagnosis

Implemented from accepted integration `4564e3f4643ad94a724bb512a14c56d784025192`
on `codex/epic-48-issue-55`. This document covers [#55](https://github.com/apshenichniy/trigo/issues/55)
and section 5 of [#48](https://github.com/apshenichniy/trigo/issues/48).

During the original #55 worker checks, the reported dialog's requester and
category had not been captured. That work launched no installed app, automated
no OS consent, and read or modified no regular or personal credential. No Keychain
backend migration, capture-API replacement, weakened access policy or global
reset was attempted.

The later #57 owner screenshot identifies a **Trigo Dev direct screen/system-audio
access consent/reminder**, with **Allow** and **Open System Settings** buttons.
The owner recognized it as the reported recurring window and clarified that they
were checking source activation, without intending to record Telegram. They
reported closing the window; **no Allow action is confirmed**. This establishes
the observed dialog category, not Keychain access. The screenshot and clarification
are retained in `/tmp/trigo-epic-48/57-owner-screen-picker-consent.json`.

Both later diagnostic observations (`57-diagnostic-observation-01.json` and
`57-diagnostic-observation-02.json`) report no system dialog. The first did not
start capture; the second recorded a short controlled capture lifecycle. These
observations do not establish repeated prompt cadence or the cause of the earlier
recurrence. The installed `capture_queue_overflow` remains unresolved and
owner-deferred in [#60](https://github.com/apshenichniy/trigo/issues/60).
The [later installed #57 evidence](acceptance-57.md) records performed controlled
capture/recovery and unchanged relaunch/validation separately, including each
unperformed physical boundary.

The original diagnosis used the `diagnosing-bugs` workflow. It did not establish
the cause of the owner's recurring dialog.
A separate red-capable loop establishes the confirmed Start/readiness defect:

```sh
mise exec -- swift test --package-path apps/macos \
  --cache-path .local/SwiftPMCache --force-resolved-versions --skip-update \
  --configuration release --filter permissionDenialNever
```

Before the change, both permission-denied cases observed one request from Start
instead of zero (`55-readiness-red.log`, two failures, 0.004 s). This tests the
permission-action boundary; it does **not** reproduce the reported system dialog.
The installed procedure below covers the remaining observation boundaries.

## Delivered behavior

- Capture readiness appears in the connection window and recording controls.
  Screen/system-audio and microphone have separate explicit enable/Settings
  actions. Application readiness code makes explicit authorization requests only
  through Enable actions; Start refreshes and explains missing access. Invoking
  ScreenCaptureKit may independently display macOS-controlled consent/reminder UI
  even when CoreGraphics preflight reports granted access. This is not a promise
  of prompt-free capture.
  Setup selects no source. Existing application selection/pinning remains intact.
- Readiness refreshes on app activation, wake, input-device connection/disconnection,
  view appearance, manual refresh and Start. Microphone not-determined, authorized,
  denied, restricted and unknown states remain distinct from device absence and
  effective recording mute. Device absence does not falsely revoke authorization.
  During capture, screen access loss interrupts with Settings guidance; microphone
  access loss retires only that input, keeps application audio and suppresses native
  microphone restart attempts until OS authorization is present again.
- CoreGraphics provides only a Boolean screen preflight. False is presented as
  access required, without claiming whether permission was never granted, denied
  or revoked. Session request history only sends another setup attempt to Settings;
  it is not persisted or treated as OS authorization truth.
- Missing Keychain items, interaction-required, denied, cancelled, unreadable data
  and other access errors have separate actionable messages. An interaction error
  can be consistent with a locked keychain, but does not prove that exact cause.
  Restored archive binding remains eligible for offline recording.
- Reads/deletes still select generic-password **service and account**. The installed
  app creates its own file-based Keychain items under the existing OS access policy.
  An unchanged URL/token is checked against the exact committed item only after
  remote same-archive validation and interrupted-write recovery; equal credentials
  produce no candidate or metadata write. Changed credentials and known unreadable
  bytes use the pending/committed/retired transaction. Access failures never imply
  permission to replace a credential. Failed repair/commit retains rollback safety.
- The opt-in live cloud connection test now uses temporary file metadata, namespace
  admission and injected in-memory credentials. It cannot own the installed app's
  Keychain item. The native adapter test uses a random synthetic service and two
  random accounts, exercises exact account selection and awaits cleanup.
- ASR probes require `--handoff` for the selected dev deployment. They do not query
  app Keychain services. The existing handoff reader now opens an owned, bounded,
  mode-0600 regular file with no symlink following and validates the deployment
  target. Existing cloud/paid-probe authorization remains mandatory.
- Normal installs require `TRIGO_SIGNING_TEAM`. `--ad-hoc` is an explicit mode with
  no promised rebuild/permission continuity; ordinary CI builds remain unsigned.
  `macos:install` prepares an installation without launching it. Signed updates
  verify the signature and preserve the designated requirement, bundle identity
  and path. The destination must be quit; another worktree requires an explicit
  `--replace-worktree` selection. Staging/backup remnants fail closed for review.
- Local bridge installs use `~/Applications/Trigo Local Dev <worktree>.app`, separate
  from the ordinary Dev/personal paths. The same Dev bundle ID/signature still
  shares macOS permission identity with ordinary Dev. A data namespace is not OS
  permission isolation. First pairing, retained binding, ScreenCaptureKit, pinned
  application capture, recovery and long-call/resource checks remain required.

Apple's [signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[macOS Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
and [AVFoundation authorization API](<https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)>)
explain these boundaries. API documentation and signature inspection do not prove
installed consent or credential continuity.

## Reversible preparation and check evidence

All run artifacts are under `/tmp/trigo-epic-48/55-*`.

Both final gates passed against staged tree
`4f86b95cb3f8c67bd6c6d7e4148a959dcf62117b`; only acceptance/setup documentation
changed afterward. The final commit's `apps`, `scripts`, `packages` and `infra` subtrees
must match that tested tree. `55-final-source.json` records final commit/tree
identity after commit; `55-preparation.json` binds the retained signed bundle to
the same tested source and its exact code subtrees.

| Check           | Final evidence                                                                                                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `check:server`  | `55-check-server-final.log`: exit 0; format, lint, types, generation, 311 unit tests (1.94 s), 36 Workers tests (20.18 s), local/cloud bundles                                             |
| `check:macos`   | `55-check-macos-final.log`: exit 0; 9 Swift contract tests, 169 native tests, both app variants and actual sandboxed native/local smoke                                                    |
| Native suite    | 376.447 s runner / 378.364 s command phase; 29 focused tests also passed in 0.603 s, including invalid-data repair and failed-commit rollback                                              |
| Builds/smoke    | Dev 11.847 s, personal 5.977 s, complete local smoke 19.082 s; actual URLSession pairing/restore 0.103 s                                                                                   |
| Contention      | 344 repository / 346 production commits; 3 imports, 12,000 turns and 24 typed large reads each; worst input-plus-commit 1178.553 / 1166.988 ms under the unchanged 2000 ms limit           |
| Media/resources | Full one-/three-hour fixtures, 0.0 ms reported source-relative drift, peak test-helper RSS 162,922,496 bytes; no shortened duration, cadence, fault coverage or relaxed resource assertion |
| Tooling         | 18 focused signing/handoff/helper tests passed; strict types/lint pass; controlled HTML fixture's script syntax checked without starting audio                                             |

The native runner duration is longer than the incoming #54 measurement of
352.156 s; this is the actual observed #55 result, not a replay of the earlier
measurement or a performance claim. Both contention fixtures retain one source
second per wall-clock second.

After the unsigned gate builds, the final worker-source signed Debug build
succeeded in **8.511 s** using the existing
Apple Development team `9MQ6VUYFRX`. `codesign --verify --strict` passed for a copy
staged at `.local/acceptance-55/Trigo Local Dev 0ea5a05335b0.app`. The built bundle
contains the expected Dev ID, worktree ID, usage descriptions and Boolean local
ATS allowance. Its entitlement output contains `com.apple.security.get-task-allow`;
no data-protection Keychain entitlement/backend was introduced. This is a signed
build observation, not app-owned credential or TCC acceptance.

The initial 38.718 s signed preparation was superseded; its bundle is retained
separately as `initial-signed-snapshot.app` and is not the final candidate.
`55-preparation.json` identifies the final prepared bundle, intended installation
path, worktree, private bridge location and synthetic credential metadata path. `55-local-preparation.log` records the actual
offline composition starting at `http://127.0.0.1:19555`; the launcher was then
stopped deliberately. The generated bridge is disposable and belongs only to
worktree `0ea5a05335b0`. No app installed or paired against it during preparation.
The final #57 build must use its own fixed final source/worktree; this snapshot
cannot prove namespace continuity for another checkout.

The first full server checks stopped at new-test lint issues (async functions,
then direct JSON encoding); the focused type check exposed two parameter types and
a fixture profile literal. Original failed logs are retained. These are corrected
before the final gates and are not represented as successful runs.

## Installed acceptance procedure

Run this procedure on the final integrated #57 source, after reversible build and
fixture preparation. The owner handles OS dialogs and physical/device actions.
Do not repeat a consent round merely to accept this intermediate worker build.

1. Record the final commit/tree, real worktree path, macOS version, signing team,
   bundle ID, designated requirement, CDHash and intended installation path. Keep
   the same checkout, bridge file, signing identity and app path across the normal
   relaunch/rebuild sequence. Do not substitute another worker's bridge or namespace.
2. Start `bun run dev` in that checkout (select a free `TRIGO_LOCAL_PORT` before its
   first run if needed). Keep its generated private bridge and port unchanged.
   Export the existing `TRIGO_SIGNING_TEAM`, then use the printed `--local-config`
   path with `bun run macos:install --variant dev --local-config <path>`.
   This builds/installs without launching. Verify with `codesign --verify --strict`
   and `codesign -d --verbose=4 -r- <installed-app>`; record entitlements with
   `codesign -d --entitlements :- <installed-app>`. Preserve the ordinary apps.
3. Prepare the local [controlled audio fixture](fixtures/capture-readiness.html)
   in a dedicated Chrome window, with other Chrome audio stopped. Use headphones
   to avoid microphone bleed. The fixture creates only a quiet 440 Hz on/off tone
   for 90 seconds, requests no microphone access and performs no network requests.
   Do not start audio or capture until the owner is ready.
4. Launch the exact installed path with `open -n <installed-app> --args --local-config <path>`.
   Click **Connect** using the prefilled synthetic local token. The app itself now
   creates its item. Record any dialog's requester/application, category, exact
   visible wording, triggering action and chosen response, omitting secret values.
   Save only the synthetic namespace's non-secret `credentialAccount` reference and
   pending/retired state from `connection.json`; never inspect another app's item.
5. In **Capture readiness**, request each missing grant explicitly. Record first
   request/grant, denial/restriction and Settings return separately. If access was
   already granted, record that fact; do not reset TCC to manufacture a first grant.
   With missing access, attempt Start three times: no request action or call should
   be created. Restore allowed access in Settings, return, and refresh readiness.
6. Start the fixture audio, focus its Chrome window and press Control-Option-Command-R.
   Confirm the pinned application, elapsed time and independent microphone state.
   Speak a planned non-private marker; toggle only Trigo's microphone recording
   off/on while the application tone continues. Focus another application and then
   return to the fixture while its tone continues; confirm Trigo keeps the original
   pinned Chrome source and application audio across both focus changes.
   Observe controlled input removal/return where hardware permits, and separately
   close the selected application to
   observe source-exit recovery. Record the actions/times for retained media checks
   in #57. A microphone device failure is not an authorization failure.
7. Stop safely and quit through Trigo. Relaunch the **unchanged installed bundle**
   with the same bridge. Retry the saved connection. Confirm the same archive/item
   and whether any credential dialog appeared. Use **Validate and save** with the
   unchanged prefilled token; confirm the account reference does not change.
8. Quit; run the same signed installation command from the same checkout and path.
   Compare designated requirement, team and bundle ID; record the new CDHash if it
   changed. Relaunch, retry and compare the app-owned item again. A changed signing
   identity, path or worktree is a separate experiment, not a normal rebuild pass.
9. Test denial/revocation only through an explicit owner action for the selected Dev
   app, accounting for shared Dev TCC identity. Record screen access as required
   when preflight is false. For a naturally unavailable/locked Keychain or rejected
   credential request, record the actual status/message and retry behavior; do not
   infer a locked state from a button or error alone. Missing/unreadable/locked-error
   transaction paths have deterministic adapter coverage, which must not be relabeled
   as physical OS proof. Do not reset or lock the owner's whole Keychain as a fixture.
10. Quit the fixture app and stop its local server. Retain the disposable namespace
    and app-owned item until evidence review; do not remove arbitrary Keychain items,
    archive files or TCC entries. Record every unperformed scenario as pending.

| Observation                                                                        | Current evidence                                                                                                                                                                                                                                                                                                                                                                   |
| ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Owner-identified screen/audio dialog (previously recalled as Allow / Always Allow) | **Category observed in #57**: Trigo Dev direct screen/system-audio consent/reminder, with Allow / Open System Settings. Owner reported closing the window; no Allow action confirmed. Earlier recurrence cause and repeated prompt cadence remain unconfirmed.                                                                                                                     |
| App-owned credentials across unchanged launch/save/rebuild                         | **Performed in #57**: unchanged relaunch/save explicitly authenticated with no owner-observed system dialogs; final supported rebuild retained the account and the owner reported a successful requested check and granted permissions. The final reply did not separately quote status/dialog wording; see [installed evidence](acceptance-57.md#supported-clean-signed-rebuild). |
| First grant, denial and revocation on installed app                                | **Unperformed in #57**; observed grants and actual capture are separate from physical first-grant/denial/revocation. Injected adapters cover OS state/action boundaries.                                                                                                                                                                                                           |
| Locked/inaccessible credential on installed app                                    | **Pending where observable**; status classification is deterministic, no global lock/reset                                                                                                                                                                                                                                                                                         |
| Signed build, exact namespace and isolated local runtime                           | Original #55 preparation retained as history; [#57](acceptance-57.md#exact-candidate-and-environment) records final clean integrated source, signed install and stable isolated namespace/runtime.                                                                                                                                                                                 |
| Controlled capture/source/microphone observations                                  | [Performed in #57](acceptance-57.md#acceptance-results-and-limitations): controlled mic/focus/mute, process recovery and source exit. Physical unplug/reconnect is unavailable with built-in-only hardware; intermittent startup overflow remains owner-deferred.                                                                                                                  |
