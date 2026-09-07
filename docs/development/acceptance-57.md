# Issue #57: installed recording foundation acceptance

## Status and evidence boundary

**Installed acceptance delivered with disclosed limitations.** Controlled
Chrome/microphone on/off/on, Finder focus changes, normal Stop, process interruption
and recovery, source exit, ordinary Quit/relaunch and unchanged connection
validation were performed. The final supported clean signed rebuild retained its
identity and account; the owner reported the requested post-rebuild check succeeded
and permissions were granted. Selected-call inspection verified each admitted
master and its SQLite evidence. All current automated gates passed.

The owner directed the work to proceed with the intermittent startup
`capture_queue_overflow` unresolved and deferred in
[#60](https://github.com/apshenichniy/trigo/issues/60). That issue remains open and
does not block the owner-approved epic delivery; neither failed attempt becomes
a pass. Physical microphone unplug/reconnect is unavailable with the owner's
built-in-only hardware. The result boundaries below remain part of
[#57](https://github.com/apshenichniy/trigo/issues/57).

This is the human-assisted installed check for
[#48](https://github.com/apshenichniy/trigo/issues/48). The owner performs physical
input, native app actions and OS-consent responses. The coordinator prepares the
signed app and isolated offline composition, controls the dedicated non-private
fixture and collects evidence only for explicitly admitted controlled call IDs
and source PIDs. Other calls in that namespace remain metadata-only.
Deterministic tests and an unperformed procedure do not establish installed
capture, permission or credential behavior.

Run artifacts are retained under `/tmp/trigo-epic-48/57-*`. The current protocol
is `57-protocol.md`; collector and synthetic checks are `57-collect.py`,
`57-collect-test.py` and `57-collector-selection-tests.log`. No personal archive, private
call, cloud credential, inference request, global TCC reset or global Keychain
operation is part of this acceptance.

## Exact candidate and environment

The core, process-recovery, source-exit and normal-relaunch observations used the
clean installed source below. The final integrated source restores the entire
previously gated tree after removing temporary diagnostics. Its native production
subtree is identical to that installed source. The older complete installed tree
differs from the gated/final integrated tree and is recorded separately.

| Identity                                      | Recorded value                                                      |
| --------------------------------------------- | ------------------------------------------------------------------- |
| Core/recovery installed source commit         | `e2b01d846d6bdb4e804280da2238b8a47ce3dc7a`                          |
| Core/recovery installed source tree           | `e4d383f78bc80bc9139ee2ed64dcc2030b96e696`                          |
| Published/gated commit                        | `9b852477fd19273014febf026b34b1630cc1b041`                          |
| Published/gated tree                          | `9f05d894d4d60fdcc34e04438fa25f13669a7ee3`                          |
| Final integrated clean commit                 | `64086c8952150082172fb65ac1de507d404aab87`                          |
| Final integrated clean tree                   | `9f05d894d4d60fdcc34e04438fa25f13669a7ee3`                          |
| Equal installed/gated native subtree          | `916ba1f510e62c91c85f31490d1df245a15f385c`                          |
| Checkout                                      | `/Users/apshenichniy/.codex/worktrees/trigo-epic-48/integration`    |
| Worktree ID                                   | `6aa93832ccaf`                                                      |
| Installed app                                 | `/Users/apshenichniy/Applications/Trigo Local Dev 6aa93832ccaf.app` |
| Build                                         | Debug; Apple Development signed; diagnostics absent                 |
| Bundle/team                                   | `io.github.apshenichniy.trigo.dev` / `9MQ6VUYFRX`                   |
| Core/recovery installed CDHash                | `766283d965b53d4c3ca3b95147e7ede17dde1b7f`                          |
| Core/recovery executable SHA-256              | `93826af901831099f1c00cec27825c24f00146bdf7af14b58b24d568eec5f994`  |
| Core/recovery `Trigo Dev.debug.dylib` SHA-256 | `ca74aaf6e7c5dac1042595441b421ac3e1f6c1b919b93f2b7d22319fb4e83ad5`  |
| Core/recovery `__preview.dylib` SHA-256       | `0f0c38c6128d6a39969a1468d0c6b33cf423d7db8c25b9be86f308c794de2364`  |
| macOS/architecture                            | 26.6.2, build `25G83`; arm64                                        |
| Toolchain                                     | Xcode 26.6 (`17F113`); Apple Swift 6.3.3                            |
| Local server                                  | `http://127.0.0.1:19371`; canonical local composition, fake ASR     |
| Initial local runtime ID                      | `fa33e2b3-5fbf-43be-add0-fd6597320cf7`                              |
| Synthetic namespace/archive ID                | `f887d4da-1d1e-4a96-86dd-0fa7a874fc0c`                              |
| Fixture SHA-256                               | `ed03f09dae200284ee7c31263564d010b4a0e6f4d70a7d61e795e57c0e47de96`  |

`57-clean-installed-build.json` records the clean installed candidate;
`57-final-published-source.json` records its production-source relationship to
the passing gates. `57-host-source.json`, `57-environment.json` and
`57-installed-build.json` retain the earlier preparation identities and exact
bridge/namespace paths. The full namespace is
`io.github.apshenichniy.trigo.dev.6aa93832ccaf.local.f887d4da-1d1e-4a96-86dd-0fa7a874fc0c`.
The bridge is the same checkout's `.local/6aa93832ccaf/connection.json`, mode 0600.
Its credential value is not present in these evidence records.

The clean candidate's strict/deep signature verification passed at
`2026-09-07T15:23:32.471433Z`. It matched the built candidate, retained the bridge
file metadata and committed account reference, and was launched through the same
LaunchServices path/config without diagnostic environment settings. These
preparation facts are separate from the performed normal relaunch and the final
supported rebuild observation below.
The designated requirement retains
the Dev bundle identifier, Apple generic anchor, the existing Apple Development
leaf identity and developer-certificate requirement; its exact text is retained
in `57-clean-installed-build.json` for the later rebuild comparison. The initial
preparation bundle's `NSAllowsLocalNetworking: true` and
`com.apple.security.get-task-allow` observations remain in `57-installed-build.json`;
they are not substituted for a later bundle observation.

During initial preparation, the coordinator launched the installed app through LaunchServices with
the retained local configuration at `2026-09-07T13:12:06.280776Z`. Before Connect,
the synthetic namespace contained only `application.lock`; no connection
metadata or archive database existed. Native UI automation failed with
`Sky Computer Use native pipe closed before response`; the owner supplies the
native app actions and screenshots. No product failure is inferred from this
tooling limitation. `57-ui-preparation.md` records that boundary.

The [controlled HTML fixture](fixtures/capture-readiness.html) runs in a dedicated
headed Chrome profile/session. It generates alternating one-second 440 Hz tone
and silence for 90 seconds, with no microphone or network request. Its selected
application output and the physical microphone have separate recorded source
roles. The performed core run below records the actual source identity and media
intervals; individual physical action times and acoustic isolation were not
independently established.

## Performed connection and idle readiness

On the earlier installed source `2c6828ae15b3b88facfa2592dac1b3a709e95696`,
at `2026-09-07T13:23:57.707679Z`, the coordinator recorded the owner's report that
connection succeeded and the supplied screenshot. `57-connected.json` contains
the observation and allowlisted synthetic connection metadata.
`57-owner-connected.png` has SHA-256
`f14d4028754b66ba20bb12ef2375350e38c4a5f5432bd32aed53cd871db87fb4`.

The app persisted the matching local server URL, synthetic archive ID and `dev`
stage. Its committed app-owned credential account reference is
`ad0c2157-7c69-47ef-a4d2-16c78b52a2ce`; pending is null and the retired-account
list is empty. The observation reads metadata only, never the credential value
or a Keychain item. This is the first installed local connection observation;
the later clean-app authenticated status and unchanged relaunch/save observations
are recorded separately below.

The screenshot shows **Ready to record**, elapsed `00:00:00`, no selected
application, screen/system-audio access granted and microphone access granted.
Start is enabled and Stop is disabled. Microphone recording preference is on;
the idle app shows no active microphone device and neither source is recording.
That idle state does not demonstrate unavailable hardware or failed input capture.
The UI also reports server operations unavailable. The cause of that displayed
state was not established; the screenshot does not establish authenticated status.

At that observation the archive database was absent after Connect; capture
admission had not yet created it. That was not corruption. Later capture admission
created the repository inspected below. Whether an intervening initial Connect
dialog appeared was not reported separately. The subsequent owner screenshot
identifies the reported window as Trigo Dev direct screen/system-audio
consent/reminder UI, with Allow / Open System Settings. No Allow action is
confirmed, and the earlier recurrence cause and prompt cadence remain unconfirmed;
[the corrected #55 record](acceptance-55.md#scope-and-diagnosis) retains that evidence.

## Performed controlled core run

The owner replied that the run completed without problems and asked the coordinator
to inspect it. This reply covered the complete physical microphone on/off/on,
Finder focus-change and normal Stop procedure. The reply arrived at
`2026-09-07T17:38:32.379750Z`; `57-core-observation.json` was recorded at
`2026-09-07T17:39:36.784123Z`. Neither timestamp is an independently observed
physical action time. No problem was reported; absence of every intervening
OS dialog was not separately confirmed.

| Core identity/evidence        | Observed value                                                                                     |
| ----------------------------- | -------------------------------------------------------------------------------------------------- |
| Call                          | `d2d1a112-3a50-4516-9623-8a3a95afee9a`                                                             |
| Recorded source               | Google Chrome, `com.google.Chrome`, expected/observed PID `29687`, window `17067`                  |
| Microphone                    | `MacBook Pro Microphone`, `BuiltInMicrophoneDevice`                                                |
| Call start/end UTC            | `2026-09-07T17:37:19.007Z` / `2026-09-07T17:37:54.125Z`                                            |
| Final capture                 | `stopped`, no interruption reason; 35,118 ms                                                       |
| Master                        | `829c23dc-e03c-43e1-86f8-14523c72c249`                                                             |
| Microphone/application tracks | `a859f249-b844-47de-92b0-139823e4bb05` / `c7108834-198b-4055-887a-02560f2b6f29`                    |
| Audio manifest                | `916351fa-1ad3-4812-8d6e-919c035494d6`                                                             |
| Confirmed media               | 71 verified commits, 561,888 frames, 2,247,620 bytes                                               |
| Whole-master SHA-256          | `c8562d875058aa43ab010fdb381fecb769ed97edd275c648975a97f94fb97add`                                 |
| Final call snapshot           | Version 2, 1,656 bytes, SHA-256 `f2805d0121fb69488051f7eaa52411281f570a4b14e09a3b2edd82569e6cabb8` |
| Audio-manifest bytes          | 564 bytes, SHA-256 `1c4288300ed5228136fd2e81b5004a07f4b9bdaf68a1f7c07843b4a336840481`              |

The full selected-call collector passed at
`2026-09-07T17:38:20.145699Z`. `57-core-final.json` has SHA-256
`860599790845362fed261eab4d6082c40cb11f6cecaa505fb4648735a1f52791`.
Its 39.808 ms SQL snapshot was released before media inspection. The only media
files were one `master.caf` and its 152,768-byte `master.index`; the finalized
master had no unconfirmed tail. The immutable header, all 71 PCM/index records,
source-state bytes, retained document hashes and final manifest mapping passed.
The full audio object maps microphone to channel 0 and application to channel 1.
Final source intervals match the committed states exactly.

Call-relative source intervals are half-open milliseconds:

| Channel/state           | Observed intervals                                               |
| ----------------------- | ---------------------------------------------------------------- |
| Microphone recorded     | `[526, 11085)`, `[19950, 35106)`                                 |
| Microphone muted        | `[11094, 19949)`                                                 |
| Microphone unavailable  | `[0, 526)`, `[11085, 11094)`, `[19949, 19950)`, `[35106, 35118)` |
| Application recorded    | `[144, 35118)`                                                   |
| Application unavailable | `[0, 144)`                                                       |

All 141,680 muted microphone frames, covering 8.855 seconds, were exactly zero.
All 8,768 unavailable microphone frames and 2,304 unavailable application frames
were also zero. The recorded microphone portion contained 409,109 nonzero samples
over 411,440 frames. Application audio remained recorded continuously after its
144 ms startup interval, with the fixture's alternating tone pattern retained
through the owner-reported focus changes. The owner report supplies the physical
action provenance; numeric energy does not verify phrase content, acoustic
isolation or an exact Finder-focus interval. Physical device loss was not performed:
the recorded input was the built-in microphone.

SQLite retains normal stop intent, no media failure and no queued operations for
this call. Its other lifecycle dimensions remain upload `pending`, transcription
`waiting_for_audio`, import `not_available`, replica `pending` and deletion `active`.
The synthetic committed credential account reference remains unchanged, with no
pending or retired accounts; this metadata comparison does not establish a fresh
authenticated app-status UI action.

`57-core-active.json` was collected **after Stop** and already contains a finalized
cursor. The later full read preserves that complete 2,247,620-byte prefix with
zero additional frames. This is final reread stability, not active-cursor or
process-recovery evidence. Earlier metadata showed `recording` at `17:37:31 UTC`;
it does not supply an independently hashed active cursor.

The accidental Telegram activation call
`1b72f2e9-6a38-4ca9-b644-acbfc37baef5` and short diagnostic call
`2ca36072-f85a-4f5b-aac1-9cc9d095094a` were excluded from media inspection. Their
metadata-only inventory remains retained separately. The earlier installed
`capture_queue_overflow` cause remains unconfirmed; this successful controlled
run does not establish its cause.

## Performed process interruption and recovery

The coordinator recorded a second explicitly admitted Chrome call, saved a
cursor-only observation, sent `SIGKILL` only to verified installed Trigo PID
`37282`, and verified its exit. The same installed binary/path/config was
relaunched as PID `91615`. The collector did not perform recovery; the installed
app reconciled and finalized the retained call.

`57-interruption-observation.json` records the performed sequence and artifact
hashes. The final full report is `57-interruption-recovered.json`, SHA-256
`9367b829c60f8586ec91a06e2fa6d0001562dbbb70f249f84a1374fc41183375`.

| Interruption identity/evidence       | Observed value                                                                                     |
| ------------------------------------ | -------------------------------------------------------------------------------------------------- |
| Call                                 | `1e1fa46a-8351-46af-a59c-bb469e1dec5b`                                                             |
| Source                               | Chrome PID `29687`, window `17067`; MacBook Pro Microphone                                         |
| Call start / recovered media end UTC | `2026-09-07T17:41:11.816Z` / `2026-09-07T17:42:27.098Z`                                            |
| Master                               | `311ce46f-9197-493f-9c67-55b8d2d5136e`                                                             |
| Microphone/application tracks        | `3b99f8e1-1ec8-439a-b824-a21ca41e3e5b` / `1ee38889-219d-4974-af12-33776eb69ec0`                    |
| Audio manifest                       | `e31b9a06-9b91-4c8d-b966-c2699349ddf2`                                                             |
| Recovered capture                    | `interrupted`, `process_terminated`; 75,282 ms                                                     |
| Recovered master                     | 151 verified commits, 1,204,512 frames, 4,818,116 bytes                                            |
| Whole-master SHA-256                 | `906f74a7a0e5410fc3c3ee4833ed9ed24d1d2187db5c0c246330be9d97061c6b`                                 |
| Final call snapshot                  | Version 2, 1,315 bytes, SHA-256 `d454d4aafec6ab8bc7dc8ee3f738153d4d5952e99e38041d1bc7deccfab01ce0` |

The actual pre-kill observation at `17:41:44.846096 UTC` verified 65 commits,
516,512 frames and 2,066,116 bytes through 32.282 seconds of media. The kill was
sent at `17:42:27.427942 UTC`, about 75.612 seconds after the call's recorded
start. The earlier cursor was therefore a lower bound, not the final durable
endpoint. `57-interruption-kill.json` retains the before/after UTC and monotonic
times, exact executable/config identity and exit confirmation.

The post-kill observation at `17:42:27.588959 UTC`, before any app relaunch,
verified all 151 commits and 4,818,116 bytes. It preserved the earlier prefix and
included 688,000 additional fully confirmed frames. SQLite still reported
`recording`; the master was not finalized. After the installed relaunch, full
inspection found the same complete post-kill byte prefix, call/master/track
identities, final whole hash and source-state projection. Recovery added the
final index record and published `interrupted` / `process_terminated` without
changing the CAF bytes. The preceding core call and its final documents/media
remained unchanged. All unavailable-source samples were zero, the final master
had no unconfirmed tail, and the other five lifecycle dimensions remained pending
or active in their respective domains.

The actual kill time minus the recovered media endpoint is **329.942 ms**. This
is a same-host wall-clock comparison, not an exact count of missing microphone
samples or an inference from the stale pre-kill cursor. Deterministic two-second
fault-bound proofs remain separate from this installed observation.

The owner's reply arrived at `2026-09-07T17:44:55.358500Z`, explicitly reporting
the interrupted status and that recording did not resume. The coordinator
recorded it at `2026-09-07T17:45:05.525467Z`; neither is an independently observed
physical action time. No dialog was reported; its absence was not separately
stated. This establishes the performed recovery/no-auto-resume check.

## Performed source exit

The coordinator sent `SIGTERM` only to the verified dedicated Chrome PID `29687`
and isolated profile at `2026-09-07T17:47:05.998838Z`; process exit was confirmed at
`17:47:06.476174 UTC`. `57-source-exit-action.json` records the action and timing.
The installed recorder finalized the admitted call as `interrupted` /
`source_exited`. The owner supplied no separate exact source-loss UI text.

| Source-exit identity/evidence | Observed value                                                                                     |
| ----------------------------- | -------------------------------------------------------------------------------------------------- |
| Call                          | `b0abd371-88bb-4dcf-9cc9-4fa618d3bd81`                                                             |
| Source                        | Chrome PID `29687`, window `17067`; MacBook Pro Microphone                                         |
| Call start/end UTC            | `2026-09-07T17:45:11.770Z` / `2026-09-07T17:47:06.510Z`                                            |
| Final capture                 | `interrupted`, `source_exited`; 114,740 ms                                                         |
| Master                        | `d399d7bb-0ada-42e1-9f92-62de1e1b95be`                                                             |
| Microphone/application tracks | `38994eb6-df1c-4d20-8689-821ecd50c19a` / `2201364f-b1a4-43ec-9e2f-27f58421f899`                    |
| Audio manifest                | `079c1965-0294-44ca-ad85-99439eadd529`                                                             |
| Confirmed media               | 230 verified commits, 1,835,840 frames, 7,343,428 bytes                                            |
| Whole-master SHA-256          | `0b94153cd9851fee2dd7419e7e6e6e150324da83c7e23bb0fe1c84f55c3d0871`                                 |
| Final call snapshot           | Version 2, 1,390 bytes, SHA-256 `d6ffb41db19da806565bdcd054ff1eb03ad0fddffb21e2f9a8a39a0565d40958` |

`57-source-exit-final.json`, SHA-256
`2376c7c26c4b757ef119cf00368ea92dab8aaff7b8a6024f36358b0816bdfb59`,
passed full sample, index, SQLite, retained-document and final projection checks.
The 22.444 ms SQL snapshot closed before media inspection. All 4,096 unavailable
microphone frames and 1,328 unavailable application frames were zero. The final
master had no unconfirmed tail and preserved the pre-close 1,820,512-frame,
7,282,116-byte prefix, adding 15,328 fully confirmed frames. Both previously
admitted captures and their media remained unchanged. This is source-process
loss, separate from physical microphone loss.

## Performed normal Quit and unchanged connection validation

The owner reported ordinary Quit; the reply arrived at
`2026-09-07T17:52:45.286254Z`. The coordinator confirmed PID `91615` had exited and
relaunched the same bundle/config as PID `95753`, observed at
`17:52:45.503562 UTC`. `57-normal-quit-relaunch.json` records the sequence.
No capture was active, so this does not establish Quit-during-capture autostop.

After the requested **Retry saved connection** and **Validate and save** with
unchanged values, the owner reported **authenticated** and no system dialogs.
The reply arrived at `2026-09-07T17:55:55.547095Z`; the coordinator recorded
`57-normal-relaunch-authenticated.json` at `17:55:55.826269 UTC`. These are message
receipt and artifact times, not exact physical click times. This is performed
app-owned authentication evidence, independent of the earlier recording-panel
server-operations-unavailable text.

All three installed Mach-O hashes in the identity table remained identical. The
bridge retained inode `557186856`, size 248 and modification time
`1788786416058709707` ns. The committed archive/stage/account reference remained
equal; account `ad0c2157-7c69-47ef-a4d2-16c78b52a2ce` remained committed, pending
was null and retired accounts were empty. The collector read no Keychain
credential value. The owner gave no separate post-relaunch permission-state
readback; earlier grants and actual capture observations remain separate evidence.

## Supported clean signed rebuild

The coordinator completed the supported signed rebuild/install from integrated
`64086c8952150082172fb65ac1de507d404aab87`. Its full tree matches the previously
gated source and its Native tree matches the core/recovery/source-exit source.
`57-final-clean-installed-build.json` records LaunchServices relaunch as PID
`54313` and strict/deep signature verification at `2026-09-07T18:47:24.813753Z`.
The signed build took 13.035 s; the installation's incremental build took 7.529 s
(`57-final-clean-signed-build.log` and `57-final-clean-signed-install.log`).

| Rebuilt installed identity      | Observed value                                                     |
| ------------------------------- | ------------------------------------------------------------------ |
| CDHash                          | `f88d1ee01ab8722f164161c8909ce692395a749f`                         |
| Executable SHA-256              | `add691f4fed42597f4efa193483432d558f9180244d78df261f9c75c377c4fc3` |
| `Trigo Dev.debug.dylib` SHA-256 | `da1a37592fd25c416a6930d687c6fc6fced0df0fa87f5c1089925ff3f12bbd48` |
| `__preview.dylib` SHA-256       | `fae31d6be5b7dc777170dae816c8409b17e9eba16708f4868c27619603da1eb0` |

The built and installed candidates match. Bundle path, team and designated
requirement remain equal to the earlier clean installation; the exact requirement
is retained in both manifests. Bridge metadata and committed account
`ad0c2157-7c69-47ef-a4d2-16c78b52a2ce` are unchanged, pending is null and retired
accounts are empty. The local runtime retains the same run ID and fake ASR.
Diagnostics are absent from the final source and no diagnostic environment was
passed. The coordinator terminated only the idle diagnostic PID `37098` for
replacement; this is separate from the owner's earlier ordinary Quit observation.

After the requested **Retry saved connection**, unchanged **Validate and save**
and permission/status/dialog check, the owner reported that everything was OK and
permissions were **granted**. The reply arrived at `2026-09-07T18:50:37.807884Z`;
`57-final-clean-rebuild-observation.json` was recorded at `18:50:37.995286 UTC`.
Neither is an independently observed physical action time. The owner did not quote the exact connection-status
word or separately state dialog presence in this final reply. The earlier
17:55 reply explicitly reporting **authenticated** and no dialogs remains separate.

The final observation verified the same PID `54313`, all three rebuilt Mach-O
hashes, bridge metadata and committed account reference, with pending null and
retired accounts empty. There were no active captures or new calls. The installed
build manifest has SHA-256
`d85098ca8afa1b426792cd816c2f48851d5b1675f786226a32aa58c9370d9640`.
No new recording or media inspection was part of this final rebuild check.

## Owner-deferred startup failure and bounded diagnostics

The open follow-up [#60](https://github.com/apshenichniy/trigo/issues/60) retains
the intermittent installed `capture_queue_overflow`. The owner explicitly
directed the work to move on and address problems as they arise; that message
arrived at `2026-09-07T18:39:23.485274Z`. Investigation stopped with the cause
unresolved; the issue remains separate and nonblocking
for the owner-approved completion of #48.

The first excluded activation call `1b72f2e9-6a38-4ca9-b644-acbfc37baef5`
ended with that code after 2,470 ms. The owner was checking source activation and
did not intend to record Telegram. Its media was never admitted for inspection.
The separate clean-installed Chrome call `272ca0e5-17dc-4aa9-a369-56c62b055b19`
ran from `17:40:51.298` to `17:40:53.218 UTC`, ending after 1,920 ms with the same
code and four durable commits. This was before the successful interruption-test
retry and before the app kill/relaunch. It was not automatic post-relaunch capture.
The owner's reply at `17:49:50.406644 UTC` tentatively reported interruption and
said they started it again; `57-clean-installed-overflow-02.json` was recorded at
`17:49:50.643887 UTC`. Its media remains excluded and unread. No task-owned build
or test suite was running then; other machine activity was not measured.

A later signed diagnostic build used commit
`9fabc14c64ff874a2b265c69e40ed9315e2a6d86`, full tree
`c65ed7b491903fec190291676c9955c1f405c019`, Native tree
`8a19fdbdd1a6c6b358f98099630d95d37412d577`, Trigo PID `37098` and fresh owned
Chrome PID `32680`. It retained the same app path, team, designated requirement,
bridge, namespace and account. The previous clean PID `95753` was already absent
at replacement; its exit cause was not observed. That replacement is not ordinary
Quit evidence. `57-overflow-v2-installed-build.json` retains the diagnostic identity.

| Diagnostic attempt                                 | Metadata/owner observation                                                                                                                                                                             |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Warm-up `155c313c-e3c8-4759-93c7-c31b768b0825`     | 36,466 ms, normal Stop. The owner completed mic-off/on and Finder changes and reported no problems or OS dialogs; reply received at `18:35:30.771733 UTC`, artifact recorded at `18:35:53.791341 UTC`. |
| Second call `642c6a1b-7594-4715-a7e0-f00144cd6824` | 12,343 ms, normal Stop in the same Trigo process. The owner reported no recording interruption; reply received at `18:36:54.269263 UTC`, artifact recorded at `18:38:15.133561 UTC`.                   |

These metadata-only observations (`57-overflow-v2-warmup-observation.json` and
`57-overflow-v2-target-observation.json`) add no new core media proof. Exact
physical action times were not independently observed. The bounded raw trace
`57-capture-diagnosis-installed-v2-attempt2-01.jsonl` has SHA-256
`10314604d3c5d5aae6c7055b9ec50953e364cbd99b3fbccacd2fc040d574bbac`,
5,595 rows and 949,499 bytes. It selected attempt 2, skipped attempt 1, and stopped
at the ten-second cap with four dropped rows. Normal Stop was outside its scope.
Observed packets were 960 application frames and 512 microphone frames at 48 kHz;
maximum observed admission-to-consume time was 28.624 ms, master append 6.322 ms
and SQLite publication 10.726 ms. The lossy, capped trace does not support absence
or exact accounting conclusions and did not reproduce or explain either failure.
`57-overflow-v2-actual-trace-analysis.json` retains the bounded measurements.

Temporary diagnostics were removed; the final integrated whole tree is exactly
the previously gated tree. The separately repaired pending-native-Start clock
defect is not an established cause of either installed overflow. No speculative
capacity increase or automatic capture retry was introduced.

## Acceptance results and limitations

| Acceptance dimension                                        | Current evidence                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local authenticated connection                              | Initial Connect succeeded. Clean-app normal relaunch, Retry saved connection and unchanged Validate and save produced authenticated status with no owner-observed system dialogs.                                                                                                                                                      |
| Permission readiness                                        | Installed idle screenshot shows both grants; the owner also reported granted permissions after the final signed rebuild. First-grant and physical denial/revocation have not been observed in this run; deterministic adapter tests are separate.                                                                                      |
| Pinned application, physical microphone and effective mute  | Performed core procedure and full selected-call checks passed; individual action timestamps and acoustic isolation were not independently established.                                                                                                                                                                                 |
| Single stereo master, SQLite state and exact evidence bytes | Performed core call passed full header/PCM/index/document/final projection and zero-suppression checks.                                                                                                                                                                                                                                |
| Actual process interruption and installed recovery          | Performed SIGKILL/relaunch passed full post-kill prefix/identity recovery; owner explicitly confirmed no automatic capture restart. Timing limitations are recorded above.                                                                                                                                                             |
| Source exit                                                 | Performed source-process termination finalized the admitted master as interrupted/source_exited; full selected-call integrity and prior-prefix checks passed. Exact source-loss UI text was not supplied.                                                                                                                              |
| Physical microphone loss/reconnect                          | Unavailable and unperformed: the owner has only the built-in microphone. Effective mute and deterministic device-state tests do not establish physical unplug/reconnect.                                                                                                                                                               |
| Normal Quit                                                 | Performed owner Quit and unchanged relaunch while idle. Quit-during-capture autostop was not physically exercised.                                                                                                                                                                                                                     |
| Unchanged relaunch and unchanged connection save            | Performed authenticated status, no owner-observed system dialogs, equal three Mach-O hashes, bridge metadata and committed account reference. No separate permission-state readback.                                                                                                                                                   |
| Supported signed rebuild                                    | Performed same-path/config/team/designated-requirement comparison, matching built/installed candidate, same bridge/account reference and diagnostics-free launch. Owner reported the requested retry/unchanged-save check succeeded and permissions were granted; exact status wording and dialog presence were not separately quoted. |
| Owner-identified dialog                                     | Direct screen/system-audio consent/reminder category observed. No Allow confirmation; recurrence cause/cadence and individual dialog absence during the core run remain unconfirmed.                                                                                                                                                   |
| Intermittent startup overflow                               | Two failed installed observations remain unresolved and owner-deferred in [#60](https://github.com/apshenichniy/trigo/issues/60). Successful retries and bounded diagnostics do not establish a fix.                                                                                                                                   |
| Locked/inaccessible credential and physical denial          | Unperformed where no natural condition was observed. Deterministic error-state coverage is not a physical Keychain lock or permission revocation observation.                                                                                                                                                                          |

`57-device-availability-observation.json`, recorded at `18:10:15.213403 UTC`,
retains the owner's built-in-only hardware report. This is unavailable physical
coverage, not a failed or simulated unplug/reconnect check.

## Selected-call inspection boundary

The version-2 read-only collector requires a nonempty controlled-call/PID allowlist
within the explicit namespace, including in cursor-only mode. It rejects the
known accidental activation, missing/duplicate selections and mismatched source
PIDs before opening media. Unselected calls expose only bounded lifecycle
inventory, with no document or media reads. It opens SQLite with `mode=ro` and
`query_only`, and releases its bounded SQL
snapshot before streaming media and performs no recovery. It checks the immutable
CAF header, every confirmed PCM/index hash and source-state record, exact retained
document hashes, final whole-master identity/length/hash/channel map, and final
source intervals. Full observations check every suppressed/unavailable sample is
zero and retain descriptive per-second energy/440 Hz measurements. Cursor-only
observations defer those sample checks explicitly.

A prior version-2 observation retains the same selected IDs, expected PIDs,
recorded source identity, call/master/track identities and exact old
confirmed byte prefix. A pre-kill cursor is a lower bound; app recovery may include
later fully synchronized commits. The collector cannot establish an exact
wall-clock loss bound from an arbitrarily old pre-kill observation or infer
physical microphone provenance from numeric energy. Actual timed actions and
installed recovery supply those observations.

Seventeen disposable synthetic collector tests passed in 0.761 s. They exercise
conflicting PCM/index/SQL/projected evidence, suppressed nonzero samples, final
hash mismatch, later confirmed progress, retained unconfirmed tail, identity
loss, foreign/symlink rejection, empty/no-progress cases, credential redaction and
byte-identical inputs after collection. Mixed-namespace cases keep excluded
missing/unreadable media unopened, reject wrong PIDs before any media read,
preserve previous admission/progress and report explicit additions. This proves
the collector's tested behavior; installed evidence comes from the performed
selected-call reports above.

## Required checks and downstream contracts

The previously published source `9b852477fd19273014febf026b34b1630cc1b041` passed both local gates and
[CI run 34142151962](https://github.com/apshenichniy/trigo/actions/runs/34142151962).
Both CI jobs checked out `10f613f3db0cc37911d27da63cb33b1147fdcf15`; its whole tree
matched the published `9f05d894d4d60fdcc34e04438fa25f13669a7ee3` tree.
The final integrated clean commit `64086c8952150082172fb65ac1de507d404aab87`
restores that exact full tree after diagnostic cleanup. These are the performed
gates on equal source content, not a claim that CI ran again on the cleanup SHA.
`57-final-ci-evidence.json`, `57-final-local-gates-evidence.json` and
`57-final-published-source.json` retain source, job, phase and artifact hashes.

| Gate                 | Performed result                                                                                                                                                                                      |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local `check:server` | Passed, 30.26 s; 338 unit and 36 Workers tests                                                                                                                                                        |
| Local `check:macos`  | Passed, 316.63 s; 9 contract and 171 native tests; Swift Testing suite 177.408 s, native runner phase 179.821 s; both app builds and 18.210 s local/native smoke under external network denial        |
| CI Server            | Passed, 79 s; format/lint/types, deterministic generation, 338 unit and 36 Workers tests, both Worker bundles and clean checkout                                                                      |
| CI macOS             | Passed, 616 s; 9 contract and 171 native tests; Swift Testing suite 276.678 s, native runner phase 279.671 s; both Debug app builds, 24.612 s native/local smoke, lock restoration and clean checkout |
| Native caches        | SwiftPM and Xcode restore-key hits, followed by current-key saves; not exact-key hits or cold-cache runs                                                                                              |

The final isolated resource proof used sequential processes with the same gated
test binary, SHA-256 `3f4eef6b197584b85b91a7e82a5ae3604a7326a9c9a553f9c10d7bdf86830669`.
No other task-owned builds/tests ran during those measurements. The binary and
source stayed unchanged through both full-extraction proofs.

| Production fixture | Frames / master bytes     | Peak helper RSS through full extraction | Runner time |
| ------------------ | ------------------------- | --------------------------------------- | ----------- |
| One hour           | 57,600,000 / 230,400,068  | 54,460,416 B                            | 34.952 s    |
| Three hours        | 172,800,000 / 691,200,068 | 50,266,112 B                            | 111.767 s   |

Both peaks remain below the unchanged 83,886,080-byte budget.
`57-final-resource-proof.json` retains full fixture identities, exact master
hashes, source/snapshot sizes, test binary/helper hashes and original logs.
Deterministic long-call and corruption/fault proofs remain distinct from short
physical installed observations. [#56's earlier measurements](acceptance-56.md)
and [the #49 baseline](acceptance-49.md) retain their original workloads and cache
conditions; neither is relabeled as this expanded 171-test run. Historical
[#55 evidence](acceptance-55.md) retains the separate permission regression,
later observed dialog category and unconfirmed recurrence cause.

Downstream code consumes the [capture master interface](capture-master-interface.md)
and [current architecture](architecture.md). [#10](https://github.com/apshenichniy/trigo/issues/10)
retains production upload during capture, post-call ASR/synchronization, verified
server-receipt cleanup, transcript UI, compact measured recording feedback,
double-Left-Option/Input Monitoring and real-call acceptance.
[#13](https://github.com/apshenichniy/trigo/issues/13) retains hosted compatibility
of master-derived inputs independently of fake ASR and the historical WAVE probe.
[#32](https://github.com/apshenichniy/trigo/issues/32) retains the infrastructure
recovery rehearsal before first personal deployment.
