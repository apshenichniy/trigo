# Signed installed capture acceptance

This is the reusable #72 procedure consumed by #24. A prepared procedure is not
a performed observation. Agents own every tool-supported preparation, app action
and collection step. Record an unavoidable OS authentication or physical-input
requirement at the exact boundary where it appears; do not replace routine app
interaction with an owner-operated checklist. Final Meet/Telegram use stays #23.

## Admit the candidate and environment

Use one coordinated executor in an unlocked GUI session. First pass
`bun run test:ui --suite shell` to establish that the native runner can control
the shared UI. Record the actual runner/Accessibility authorization result; that
does not establish Input Monitoring, Screen Recording or microphone permission
for the installed app.

Start `bun run dev` from the integration checkout and keep its local fake-ASR
server alive. Use its printed connection configuration and the existing signing
team with the normal installer:

```sh
bun run macos:install --variant dev --local-config /absolute/printed/connection.json
```

Use the returned stable `Trigo Local Dev <worktree>.app` path. Do not copy an
unsigned bundle over it, change its designated requirement, or replace a running
app. The installer checks the team, bundle, worktree and replacement identity;
see [setup](setup.md) for signing prerequisites. Record source commit/tree and
dirty fingerprint, build receipt, executable hash, full bundle hash, app path,
bundle/worktree ID, `codesign --verify --deep --strict` result and designated
requirement. Record only the local archive/namespace identity and configuration
file hash, never the token. Confirm the namespace is the explicit local Dev
namespace before admitting a call.

Launch that path with its same configuration. Connect using the prepared local
configuration, read readiness and inspect only the app's own permission controls.
Before starting capture, record the observed screen/system-audio and microphone
grants, actual input device, GUI automation authorization and Input Monitoring
state. For the #58 gesture, read its actual registration/diagnostic state. Record
any OS-owned dialog and requester; if it needs owner authentication, keep the
dependent observation pending. Do not reset ordinary Dev or Personal permissions.
Separate Dev data namespaces still share the Dev permission identity.

## Controlled signals and interactions

Open [capture-readiness.html](fixtures/capture-readiness.html) in a dedicated
Chrome session. Establish the owned process/PID and stop unrelated audio in that
session. The fixture creates alternating one-second 440 Hz application tone and
silence and requests no network or microphone access. Record its hash and the
admitted window/PID before Start.

Arrange an independent microphone stimulus before recording. Prefer a provisioned
audio test device/route with a distinct known signal. Record routing, device and
signal identity. If acoustic playback into the built-in microphone is the only
available route, disclose that application/microphone isolation is limited. If no
controlled positive microphone stimulus exists, finish application-audio checks
and leave positive physical microphone evidence pending; a zero microphone track
cannot satisfy it. Do not record unrelated speech to obtain a positive signal.

Perform the following with timestamps and observed state, using only controlled
app/source windows:

1. Focus the controlled source, use the accepted double **left Control** gesture
   when #58 is present, and verify the pinned application and call identity.
   Synthetic key delivery proves dispatch only; record physical key observation
   separately when supplied. Repeated Start reveals the same recording.
2. Observe positive application and microphone input, then mute Trigo's microphone
   for at least five seconds and unmute it. Record acknowledged state transitions.
   Change focus to the controlled focus app; the original source must remain
   pinned and the panel must preserve focus. The calling app's mute is independent.
3. After capture admission, pause only the owned local test server to retain the
   pending master for inspection. Finish from the panel. Confirm safe finalization,
   a saved call and hidden panel; collect the selected call, then resume that same
   local server/namespace and observe upload recovery. Record the intentional
   offline interval. If cleanup has already happened, report that fact and use the
   retained server receipt/media acceptance; do not treat a missing file as proof
   of the local samples. This collector never downloads or restores audio.
4. For a separate controlled call, collect a fast active cursor, terminate only
   the verified test app process, and record actual kill time. Relaunch the same
   signed path/configuration. Verify no recording restarts, the retained prefix
   is preserved and the same call finalizes as interrupted. The app performs
   recovery; the collector only observes it.
5. In another controlled call, close only the established owned source process
   and verify source-exit finalization. Do not terminate ordinary Chrome when
   process isolation cannot be established. Physical input-device removal is a
   distinct optional observation when the hardware supports it.
6. Quit normally, reopen the identical bundle/configuration and validate the saved
   connection. Repeat the supported signed install at the same path after Quit.
   Record actual readiness/consent behavior and compare namespace/signing/build
   identity. Existing grants are valid; absence of a prompt proves only this run.

## Selected-call evidence

The read-only collector admits one to twenty explicit call IDs and their expected
source PIDs, with at most ten minutes per call. It checks the archive identity,
bounded SQLite snapshot, retained document hashes, CAF header, every confirmed
index/PCM record, source states and final manifest mapping. It releases the SQL
snapshot before reading audio. It exports numeric channel/state energy and hashes,
never audio samples, transcript text or credentials. Suppressed and unavailable
samples must be exactly zero. Numeric energy alone does not prove the physical
source or distinguish acoustic bleed.

Create an ignored admission file after observing each controlled call ID. Fill
every placeholder; `expectedApplicationProcessId` is a JSON integer:

```text
{
  "synthetic": true,
  "namespacePath": "<absolute-canonical-local-Dev-namespace>",
  "archiveId": "<archive-uuid>",
  "sourceCommit": "<candidate-commit>",
  "controlledCalls": [
    {"callId": "<controlled-call-uuid>", "expectedApplicationProcessId": 12345}
  ]
}
```

```sh
python3 scripts/installed-capture-evidence.py --manifest /absolute/admission.json \
  --label before-interruption --cursor-only --output /absolute/before.json
python3 scripts/installed-capture-evidence.py --manifest /absolute/admission.json \
  --label recovered --previous /absolute/before.json --output /absolute/after.json
python3 scripts/installed-capture-evidence.py --manifest /absolute/core-admission.json \
  --label core-measured --require-measured-mute --output /absolute/core-measured.json
```

Output must be new and outside the observed namespace. `--cursor-only` checks the
confirmed byte prefix/index but omits energy/suppression checks; a later full
observation is required for those claims. A failed read, missing local master,
source mismatch or unsupported schema fails explicitly. Keep the failure and
candidate identity. Run the collector's disposable self-check with
`python3 scripts/installed-capture-evidence-test.py`; its fabricated files validate
the collector and cannot establish installed app behavior.

`--require-measured-mute` additionally requires positive recorded samples on both
channels, at least five seconds of acknowledged microphone mute, and nonzero
application samples during that mute. An ordinary integrity pass alone does not
satisfy the positive-signal acceptance. The controlled core-call admission should
contain only calls that performed this sequence; interruption/source-exit calls
use separate admissions and the appropriate integrity/prefix checks.

The #24 evidence record links the performed UI/installed results, source and
artifact hashes, call/PID admissions, actual command statuses and remaining
physical/OS observations. Hosted ASR and cloud deployment retain their own exact
authorization and paid-execution evidence; this local procedure does not admit
either action.
