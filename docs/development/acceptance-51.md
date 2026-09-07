# Recoverable single-master proof (#51)

This proof implements the media slice of [#48](https://github.com/apshenichniy/trigo/issues/48).
It uses generated, non-private input in UUID-scoped temporary directories. The
production capture adapter, production selected exchange profile, SQLite archive,
cloud resources and installed app are unchanged. #52 consumes the durable boundary;
#53 integrates the writer/profile with capture. Hosted Nova-3 compatibility remains
#13, and upload/ASR/synchronization and receipt-driven cleanup remain #10.

## Selected candidate and comparison

The selected proof profile is `caf-lpcm-s16le-16000-stereo-v1`: 16 kHz signed 16-bit little-endian
interleaved LPCM, channel 0 microphone, channel 1 selected application. One
`master.caf` contains every call frame. `master.index` is incremental metadata and
integrity evidence, not another audio object. Master/call/track identities are
allocated before creation and retained on reopen and repeated finalization.

The bounded comparison first writes identical LPCM samples to WAVE and CAF and
independently decodes and seeks with `AVAudioFile`. Both preserve the samples.
WAVE changes its RIFF/data size fields at bytes 4–7 and 40–43 on finalization. Its
three-hour PCM payload fits the 32-bit limit, but upload would require withholding
or replacing the first transport part. CAF removes that extra mutable-prefix
protocol, so the remaining proofs use CAF. No compressed alternative was needed
to satisfy the contract; codec-specific recovery/fragmentation was not introduced.

The CAF header is exactly 68 bytes. Its last `data` chunk has signed 64-bit size
`-1` throughout capture, reopen and finalization. No chunks follow that data chunk,
and no media byte is rewritten. Apple permits unknown length for the last data
chunk; its recommendation to fill in the final size is deliberately not adopted.
Native decode/seek, full-length extraction, recovery and reconstructed exact bytes
are tested with the unchanged sentinel, rather than inferring compatibility from
the specification alone. Other decoders/providers remain a separate compatibility
gate. See [Apple CAF specification](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html),
[Microsoft RIFF](https://learn.microsoft.com/en-us/windows/win32/xaudio2/resource-interchange-file-format--riff-)
and [Microsoft WAVE final-size handling](https://learn.microsoft.com/en-us/windows/win32/medfound/tutorial--decoding-audio).

## Typed durability interface

The implementation is in `apps/macos/Native/RecoverableMediaMaster.swift` and
`MediaMasterFormat.swift`, with binary layout in `MediaMasterIndex.swift` and
bounded filesystem reads/writes in `MediaMasterIO.swift`.

| Value/operation                                                 | Meaning and consumer obligation                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `MediaMasterIdentity`                                           | Stable master, call, microphone-track and application-track UUIDs. The repository supplies them; reopen requires the expected identity. The byte digest is not a replacement for those identities.                                                                                                                                                           |
| `append(interleaved:microphoneIntervals:applicationIntervals:)` | At most 16,000 stereo frames (one second), integral milliseconds, and complete contiguous source-state spans for both channels. Non-recorded contributions are zeroed before the first disk write, PCM digest or upload representation. Invalid/missing metadata fails before mutation.                                                                      |
| `MediaMasterCursor`                                             | Identity, confirmed frame count, stable byte extent, commit count and index-chain SHA-256. `stableBytes = 68 + frames * 4`; this arithmetic alone cannot certify durability.                                                                                                                                                                                 |
| `MediaMasterCommit`                                             | The new certificate, start frame, PCM SHA-256 and only that append's source intervals. The repository may insert this small increment and update progress in one semantic transaction. No previous interval list is supplied or rewritten.                                                                                                                   |
| `init(reopening:expectedIdentity:confirmed:)`                   | Bounded verification of the index and referenced audio. A supplied repository cursor must match an actual verified prefix before recovery may return or trim anything. Reopen can recover a later verified but unacknowledged append; the repository then reconciles progress under the same identities. Opening is explicit and does not restart recording. |
| `finish()` / `FinalizedMediaMaster`                             | Append and sync one final index record containing the whole CAF SHA-256. Return the same cursor, digest, size and duration on repeat calls and reopen. No media/header rewrite. Media completion does not mean upload/transcription completion or grant cleanup permission.                                                                                  |
| `readStableBytes(in:)`                                          | Only ranges within the confirmed prefix, including the immutable header; each request is nonempty and at most 8 MiB. A larger physical file length cannot expose an uncommitted tail.                                                                                                                                                                        |
| `forEachCommit(intersecting:_:)`                                | Incrementally scan intersecting integrity/source records without retaining a whole call's metadata. Callers process/persist each callback.                                                                                                                                                                                                                   |
| `extract(frames:to:intervals:)`                                 | Post-call, millisecond-aligned frame interval. Stream 64,000-byte PCM blocks into one transient CAF and stream clipped call-relative source metadata. Return master identity/hash, start/end frame, exact output hash/size, channel map and `identity-stereo-pcm-frame-slice-v1` transform/profile.                                                          |

The synchronous single-owner append order is **write PCM → synchronize media →
append integrity record → synchronize index → return certificate → caller commits
SQLite progress**. Initial media/index headers and their directory entry are also
synchronized before returning. SQLite cannot include the preceding external writes
in its transaction. Any append/finalization I/O failure closes that writer to new
appends; its in-memory certificate remains the last successfully returned one.
Reopen verifies durable bytes before returning a replacement certificate. A failed
acknowledgement after index sync is explicitly tested: the caller sees the old
certificate, then reopen discovers the same identity with the additional verified
commit. Consumers must preserve this uncertain-outcome distinction.

The caller must deliver bounded blocks and serialize append/control/repository
operations. This proof guarantees the loss window for its one-second append
boundary; it does not turn an arbitrarily delayed caller or unbounded upstream
queue into a real-time capture guarantee. #52 owns bounded repository transactions
under background work; #53 owns the production capture integration and scheduler.

## Binary index and recovery

The index has a 128-byte immutable header: `TRGIDX01`, four raw 16-byte UUIDs,
24 reserved zero bytes, then SHA-256 of the preceding 96 bytes. The version fixes
the profile/channel interpretation. Every following record is 2,120 bytes:

| Offset      | Content                                                                                                                                                           |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0–7         | `AUDIO001` or `FINAL001`                                                                                                                                          |
| 8–15, 16–23 | Big-endian cumulative frame and stable byte cursors                                                                                                               |
| 24–55       | This append's PCM SHA-256, or the final whole-master SHA-256                                                                                                      |
| 56–87       | Previous audio-record/header SHA-256                                                                                                                              |
| 88–2087     | At most 1,000 interleaved microphone/application state bytes each; recorded=1, muted=2, unavailable=3; unused positions zero. Final records have all-zero states. |
| 2088–2119   | SHA-256 of the preceding 2,088 bytes                                                                                                                              |

This fixed worst-case encoding handles a state change every millisecond without
growing a checkpoint or keeping call-long arrays. Each commit writes exactly
2,120 index bytes, independent of elapsed call length; audio is at most 64,000
bytes. The index is about 3.31% of PCM size with one-second appends. Shorter appends
are supported and have the same fixed record cost. Consumers can index their typed
rows in SQLite without changing the external media certificate.

Recovery validates the header/identity, record checksum/chain, frame/byte
continuity, source-state coverage and every committed PCM hash. It scans one
record and at most one second of audio at a time. Only after successful witness
verification does it synchronize truncation to the verified media/index prefix.
It retains the same UUIDs and never synthesizes recorded duration from wall time.

A partial final index record and any unindexed PCM tail are discarded. A
full-sized final index record with a damaged checksum is discardable only when a
supplied repository witness has already matched, the damaged record is beyond
that witness, no later record follows, and the extra PCM is at most one append.
Without that witness, or at/below it, or for nonterminal damage, recovery reports
an explicit corruption error. A valid committed record whose PCM is corrupt or
truncated also reports a corruption error without silently rewriting evidence.
Arbitrary old committed corruption is outside the two-second uncommitted-loss
guarantee; tests keep these outcomes distinct.

The fault matrix includes real SIGKILL before/after media sync, before/after index
sync and before/after finalization sync; real POSIX short-write retries; a 12,345-byte
partial PCM write; partial index tails of 0/1/31/2,119 bytes; complete-sized damaged
uncommitted index tails; truncated/corrupted unindexed PCM; partial finalization;
wrong identities; rolled-back repository witnesses; and protected/nonterminal
committed damage. Before index publication, three seconds of input recover two
seconds with at most 64,000 discarded PCM bytes. A fully verified third record
recovers all three seconds. Missing time is absent from recovered duration/source
metadata, rather than marked as recorded speech.

## Upload and interval evidence

The local multipart sink uses fixed 8 MiB non-final parts, satisfying R2's minimum
5 MiB and equal-size rules, at most 10,000 parts, and the application's maximum
8 MiB request. The final part may be shorter. A 265-second generated master uploads
two full parts during capture, survives reopen/finalization with identical bytes,
and completes with a third shorter part. Bounded local reconstruction has the
same SHA-256 and native frame count as the master. Invalid undersized non-final
parts, oversized reads and invalid part numbers fail. See [Cloudflare R2 upload
constraints](https://developers.cloudflare.com/r2/objects/upload-objects/).

Transport part numbers/receipts are never used as master digests, track identities
or ASR intervals. The 1h/3h master lengths imply 28/83 fixed-size parts, far below
the part-count limit. This is local compatibility evidence; it sends no R2 request.

Extraction tests cover 0–2,051 ms, 999–2,104 ms and 130,999–264,997 ms, including
leading silence, muted/unavailable source intervals and integrity/transport
boundaries. Full 1h/3h extractions additionally prove that working memory does not
scale with requested interval length. All samples are independently decoded and
compared with source-specific generated markers. Full-call extraction yields the
same CAF hash because header, channels and PCM bytes are unchanged. Partial
intervals get their own output digest and retain the original whole-master digest
and call-relative frame range. ASR consumers add the retained start-frame offset
to input-relative timestamps; one master implies neither one provider submission
nor continuous diarization.

## Measurements and checks

Measured on 2026-09-07, macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Apple M1 Pro, 16 GiB RAM, arm64,
Release configuration. These are local synthetic throughput measurements; the
fixtures advance the full simulated call duration without waiting in real time.
Each measured long run uses an isolated test filter, preserving every frame and
source-state transition. Full native gates also retain the existing one-hour
common-clock, three-hour legacy-writer and 25-iteration SIGKILL fixtures unchanged.

| Measurement                                                 |         One hour |      Three hours |
| ----------------------------------------------------------- | ---------------: | ---------------: |
| Frames, all independently decoded and compared              |       57,600,000 |      172,800,000 |
| Master bytes                                                |      230,400,068 |      691,200,068 |
| Index bytes, including final record                         |        7,634,248 |       22,898,248 |
| Persisted source intervals, transitions every 10 ms         |          452,689 |        1,358,089 |
| Append + media/index sync                                   |          1.254 s |          3.295 s |
| Independent full native decode + sample comparison          |          0.243 s |          0.728 s |
| Reopen, independent hash and metadata scan                  |          0.572 s |          1.699 s |
| Full interval extraction + independent output hash          |          0.481 s |          1.531 s |
| Complete command elapsed, including Swift driver            |           4.06 s |           7.88 s |
| External command peak RSS, including driver/host accounting | 85,868,544 bytes | 63,930,368 bytes |
| Actual proof-process peak RSS through all phases            | 43,384,832 bytes | 43,368,448 bytes |
| Proof-process physical footprint after extraction           | 23,478,920 bytes | 23,478,944 bytes |

The separate full one-hour 44.1 kHz microphone / 48 kHz application common-clock
fixture measured **0.0 ms** worst source-relative marker drift, below the approved
200 ms limit. Its test took 5.612 s; the whole command took 6.23 s with 63,913,984
bytes external peak RSS. Signed source markers prove channel identity separately
from the simultaneous timing pulses.

The initial diagnostic failed the bounded-resource bar: the one-hour combined
fault/resource run reached 558,219,264 bytes at reopen/index and 1,044,234,240 bytes
after extraction. Native decode had not increased the preceding 145,014,784-byte
peak in that concurrent diagnostic. This did not support a decoder/file-mapping
explanation. The corrected implementation drains Foundation read-bridge
autoreleases at each bounded read, uses native hex encoding, scopes standalone
range-reader temporaries, and reuses one extraction reader. Isolated final runs
now stay at essentially identical RSS/physical footprint for 1h and 3h, including
full extraction and metadata scans. In-test `getrusage`/Mach VM measurements
separate this evidence from the Swift driver's larger external peak. Peak RSS is
reported rather than substituting physical footprint for it.

The active one-second writer stores no previous audio/interval arrays. Reopen
reads at most 64,000 PCM bytes plus one 2,120-byte index record; source callbacks
contain at most 2,000 intervals. Extraction uses a single reader and 64,000-byte
blocks. Upload ranges are bounded separately at 8 MiB. Larger call duration
increases disk/index work linearly, while those working sets stay fixed. A
worst-case one-second fixture also changes both source states every millisecond
and verifies the same fixed index size and silence before persistence.

Raw logs for this run: `51-one-hour-verified.log`, `51-three-hour-verified.log`,
`51-drift-verified.log`, `51-fault-transport-verified.log`, and resource diagnostics
`51-resources-faults.log` / `51-*-bounded-swift.log`, all under
`/tmp/trigo-epic-48/`. An optional direct test-helper launch failed because it did
not inherit SwiftPM's Testing.framework search environment; it is not a passing
measurement. The supported reproduction below uses SwiftPM normally.

```sh
mise install
mise exec -- bun install --frozen-lockfile
mise exec -- bun run macos:setup
mise exec -- swift build --package-path apps/macos --cache-path .local/SwiftPMCache \
  --force-resolved-versions --skip-update --configuration release --build-tests \
  -Xswiftc -enable-testing

# Run each filter separately; the external time output and in-test phase metrics
# deliberately report different process scopes.
for proof in mediaMasterOneHourFrequentIntervals mediaMasterThreeHourFrequentIntervals mediaMasterOneHourCommonClockDrift; do
  /usr/bin/time -l mise exec -- swift test --package-path apps/macos \
    --cache-path .local/SwiftPMCache --force-resolved-versions --skip-update \
    --configuration release --skip-build --filter "$proof"
done
mise exec -- swift test --package-path apps/macos --cache-path .local/SwiftPMCache \
  --force-resolved-versions --skip-update --configuration release --skip-build \
  --filter mediaMaster --skip 'mediaMasterOneHour|mediaMasterThreeHour'

TRIGO_TIMINGS_FILE=/tmp/trigo-epic-48/51-check-macos.jsonl mise exec -- bun run check:macos
mise exec -- bun run check:server
```

Final required gates passed on the implementation source:

- Pinned mise setup, frozen Bun installation and locked macOS dependency setup
  passed (`51-mise.log`, `51-install.log`, `51-setup.log`).
- `check:server` passed formatting, lint, TypeScript, deterministic generated
  contracts, **262 unit tests**, **17 Workers tests**, and both local/cloud Worker
  bundle builds (`51-check-server.log`).
- `check:macos` passed Swift formatting, **8 contract tests**, **114 native tests**,
  both **Trigo Dev and Trigo Debug app builds** with signing disabled, and the
  isolated local Worker/R2/fake-ASR smoke with external network denied
  (`51-check-macos-final.log`, phase times in `51-check-macos-final.jsonl`). Native
  tests took 16.533 s in the test host / 17.866 s for the command phase; both app
  build phases took 22.811 s and 4.752 s. The original one-hour common-clock,
  three-hour 180-object and 25-iteration SIGKILL fixtures remain unchanged.
- The final isolated fault/format/transport set passed **15 tests** (0.273 s),
  including six real SIGKILL boundaries and the protected full-sized corrupt
  index-tail cases. Resource filters were rerun against the final built tests.
- Dependency locks, generated contracts, toolchain pins, vendored Effect source
  and production capture/profile files remain unchanged. The first native gate
  caught an inferred-array type error in a newly added invalid-input test; an
  explicit fixture type fixed it, and the complete required native gate then
  passed. The failed attempt remains in `51-check-macos.log`.

The new media fixtures access no device, TCC, Keychain, real app/call, personal
archive, provider or cloud credential. The required full native suite also runs
the pre-existing Keychain adapter test with a synthetic token and a UUID-scoped
`io.github.apshenichniy.trigo.tests` service, separate from installed-app items.
This establishes process-termination and filesystem fault behavior locally; it
does not claim installed-app, physical-device, power-loss hardware, live R2 or
hosted ASR acceptance.

## Integrated CI evidence

Worker commit `e5619db00ec473726d73c0cd76141b5a2db43ea0` was integrated as
`301438d9534fa8ddfa3b7b59e9eca90525f93552`; their complete trees are identical
(`406e3f30595c87bd3187765595fa08523bc44f2f`). The following coordinator commit
changed only the epic evidence table. Both jobs passed at integrated source
`2b15a5de79d59a887bc4cd4b147d389b38a57dd1` in
[Actions run 34064605149](https://github.com/apshenichniy/trigo/actions/runs/34064605149).

The [Linux job](https://github.com/apshenichniy/trigo/actions/runs/34064605149/job/101571051295)
passed the server gates. The
[macOS job](https://github.com/apshenichniy/trigo/actions/runs/34064605149/job/101571051400)
passed eight contract and 114 native tests, both Debug app builds, the isolated
network-denied smoke and lock/output drift checks. Its native suite took 28.402 s;
the full job took 203 s including setup/cache work. Full one-/three-hour proofs
retained 57,600,000 / 172,800,000 frames and the same fixture SHA-256 values; the
one-hour common-clock proof again measured 0.0 ms drift. These runner results
confirm the integrated source and do not replace the isolated local resource
measurements or later production/installed/provider acceptance.
