# SQLite archive and durable work (#52)

This implements the local repository slice of
[#48](https://github.com/apshenichniy/trigo/issues/48) and
[#52](https://github.com/apshenichniy/trigo/issues/52). A namespace contains one
`archive.sqlite3`. `LocalRepository` owns canonical call values, exact published
exchange bytes and hashes, retained evidence, revision-scoped speaker names,
durable operations, capture sessions and verified media progress. Routine call,
turn, lifecycle and operation queries read typed SQL columns. JSON decoding and
validation occur at exchange publication/import boundaries.

The former `LocalArchive`, `LocalLifecycleStore` and `OperationJournal` file
implementations are removed. Capture preparation and finalization no longer
coordinate `capture-session.json`, `capture-finalization.json`, `call.json`,
lifecycle files or journal files. The transitional legacy media writer retains
its external-media checkpoint until #53 replaces it. Its small atomic file
helper is scoped to that external media path.

## Authoritative transactions

The repository's observable lifecycle contract still presents six dimensions.
The generated call document owns capture state; SQLite stores the five
independently mutable processing axes in `lifecycle` and joins capture from the
current canonical call. Attempting to change capture through a lifecycle update
fails explicitly.

| Boundary                | One committed result                                                                                                                                        |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Capture admission       | Allocated call, track, audio-manifest and master identities; source/session context; initial canonical call and lifecycle; optional caller-associated work. |
| Verified media progress | One issued media certificate, its new source intervals and the current confirmed cursor. Previously committed intervals are not rewritten.                  |
| Capture finalization    | Final canonical call, immutable audio reference, final master witness when supplied, lifecycle capture projection and optional caller-associated work.      |
| Revision import         | Retained immutable revision, visible typed turns, new canonical revision reference/active revision, imported lifecycle axis and caller-associated work.     |

Validation, hashing, serialization and large immutable preparation happen before
the small publication transaction. Preparation rows are content-addressed and
unreachable through canonical calls, evidence, turn queries and pending work
until publication. A process death may retain unused preparation. Compare-and-swap
against the observed call hash prevents an import from overwriting a concurrent
snapshot. Every previously published call version retains its exact bytes;
replaying that exact historical version succeeds without rolling current state
back. Same-identity/different-byte revisions, audio and operations fail.

Revision import validates the incoming document once. It then checks the new
typed speaker/turn tracks, interval bounds and audio reference against the call,
and compares definition IDs against paged retained SQL projections. Retained
evidence identities and original byte hashes are still verified. Import does not
decode and structurally validate every earlier revision again. Speaker-name
updates similarly mutate the typed snapshot and encode its new publication,
without re-entering the archive import path.

Caller-associated work has a semantic receipt for its admission/finalization or
revision import. Retrying a committed semantic operation checks the original
operation identity, kind and payload hash. Acknowledged operations keep identity
tombstones. An uncertain running operation remains replayable with its original
identity and payload; side effects execute after intent commit and outside SQL.
This does not assert exactly-once network execution or introduce an automatic
upload/ASR/replica pipeline.

`BEGIN IMMEDIATE` and `COMMIT` define the transaction boundary. A failed COMMIT
rolls back if SQLite still reports an active transaction. A rollback failure
poisons the connection until reopen. A post-COMMIT interruption represents an
uncertain caller outcome and never attempts to undo committed work.

## External media and #53 handoff

`commitMediaProgress` consumes #51's `MediaMasterCommit` only after the external
writer has synchronized media and index bytes. It validates identity, sequence,
frame/byte continuity, source coverage and the integrity chain. The repository
cursor is passed back to #51 reopen; a verified later certificate can then be
reconciled under the same identities. Physical file length cannot advance SQL
progress, and an external write failure leaves the old confirmed cursor intact.

`CaptureArchiveSession` allocates the stable master UUID before I/O and exposes
`mediaMasterIdentity`. `finalizeCapture(callSnapshot:audioManifest:verifiedMaster:
associatedWork:)` is the selected-profile integration seam. A zero-frame finalized
master has the genuine 68-byte header and no invented progress commit. Nonzero
finalization checks the selected profile, master identity, exact hash and byte
length against the audio object. The production exchange profile/writer switch
belongs to #53; #52 does not claim the legacy WAVE profile can describe a CAF
master.

The transitional WAVE writer can allocate a new WAV object ID when recovering
the same active PCM file. `legacy_capture_seals` retains its first validated
sealed result and caller-associated work as unpublished immutable preparation,
before the joint canonical transaction. Recovery reuses that exact result after
an uncertain finalize. This is an external-effect receipt, not another writable
capture lifecycle. **#53 should remove this table and its legacy receipt methods
when production capture uses the preallocated stable master identity.** The
legacy media writer/checkpoint/helper can then be removed together. Stop intent
and a known interruption cause remain repository-owned operational facts across
the external seal boundary. Session dates use Foundation's native reference
epoch so current-time allocations survive a lossless SQL round trip.

## Scheduling and store admission

One shared connection and priority scheduler own each archive namespace in the
process. Waiting capture work precedes background access. Each SQL unit releases
the connection before suspending or doing validation, document hashing,
credentials, network or media I/O. Background preparation writes at most 128
rows or 256 KiB of bound values per transaction; document bytes use 256 KiB
chunks. Typed reads page at 128 rows, with SQL text cells limited to 4,096 UTF-8
bytes. Larger strings use immutable UTF-8 chunks and resolve after the reader
is released; the reserved marker prefix is escaped using the same mechanism.
An individual media checkpoint has at most #51's 2,000 new source intervals.

SQLite uses rollback-journal `DELETE`, `synchronous=EXTRA`, `fullfsync=ON`, foreign
keys and `trusted_schema=OFF`; required settings are checked. This avoids relying
on the system library's version-dependent WAL reset/checkpoint behavior. See
[SQLite durability pragmas](https://sqlite.org/pragma.html#pragma_synchronous),
[SQLite transactions](https://sqlite.org/lang_transaction.html) and
[SQLite WAL notes](https://sqlite.org/wal.html). A 250 ms busy timeout bounds
unsupported external-writer contention. The existing app-instance lease and
Keychain ownership remain unchanged.

The archive ID, canonical namespace path, application ID, schema version, exact
schema definitions, integrity and foreign keys are checked before an existing
store becomes writable. Root, parent, database and sidecar symlinks, database
hardlinks, foreign identities, unknown schemas and corrupt stores fail explicitly.
Known operating-system `/var`, `/tmp` and `/etc` aliases are admitted only after
checking their exact targets; POSIX canonical paths satisfy SQLite `NOFOLLOW`.

A hot rollback journal cannot be recovered through SQLite's read-only handle.
The repository first copies the database and journal into a private temporary
directory, recovers and validates the copy, then verifies unchanged source file
fingerprints before opening the accepted original for recovery. An unfamiliar or
corrupt source is never recovered merely to inspect it. The foreign-hot-journal
test compares both original files byte-for-byte after rejection.

An existing nonempty legacy file archive is rejected without deletion or
migration. The explicit test cutover fixture creates a separate fresh test
namespace and verifies the legacy bytes remain intact. No automatic reset path
or personal-resource cutover is introduced.

## Local evidence

All inputs are synthetic and all stores are UUID-scoped temporary test archives.
The interruption matrix includes thrown hooks immediately before/after COMMIT
and real child-process SIGKILL for admission, progress, finalization and revision
import. Before-COMMIT children dirty and spill more than 2 MiB of existing pages,
producing genuine hot journals rather than an in-memory-only transaction. Reopen
proves rollback, retained UUIDs and joint canonical/lifecycle/work outcomes.
After-COMMIT children reopen the complete result. Tests also cover actual
COMMIT-BUSY and SQLITE_FULL failures followed by reuse of the same connection.

The broad SQL/recovery run passed all 95 non-contention cases, including the
baseline recording/recovery behaviors. Hot journals measured 2,130,488–2,155,112
bytes in that run. The initial contention fixture reached its safety cap because
it submitted 10,800 capture commits continuously without input pacing. It did
not fail a commit-window assertion. The corrected fixture retains all inputs and
background work, with one second of synthetic capture input every 20 ms (50x
real time), allowing background processing between arrivals.

The final implementation's full native suite passed **135 tests**, including
all nine typed-reference rejection cases, both full CAF 1h/3h proofs, the existing
one-hour common-clock fixture, the three-hour 180-object legacy writer and all
unchanged process-termination fixtures. The one-hour drift remains **0.0 ms**.
Failed typed imports leave the canonical version, lifecycle and document count
unchanged, with neither incoming turns nor caller work visible.

The contention test imports three revisions containing **12,000 turns** and
**11,111,043 input bytes**, including a **2,880,000-byte** individual turn, performs
**24** typed reads of those oversized turns plus list projections, and updates,
retries and acknowledges caller work. Every capture commit has the maximum
**2,000** source-state intervals and includes real #51 media/index synchronization
followed by a durable SQL transaction. The final full-suite run measured:

| Measurement                                          |                    Result |
| ---------------------------------------------------- | ------------------------: |
| Concurrent capture commits                           |                     2,845 |
| Capture counts around each complete background phase | 0 → 1,000 → 1,930 → 2,845 |
| Maximum media + index + SQL service                  |               81.08125 ms |
| 95th percentile service                              |              18.823209 ms |
| Maximum one-second input + service                   |            1,081.08125 ms |
| Contention test duration                             |                 126.290 s |

Every commit asserts **one second of input + complete service ≤ two seconds**.
Each background phase also asserts advancing capture, and all three finish.
This is the repository's accelerated synthetic concurrency proof; #53 still
owns production input scheduling and end-to-end lateness. The earlier focused
paced baseline, before replacing historical JSON revalidation, completed 5,677
commits in 233.270 s with a 123.8295 ms maximum service time. The final numbers
above include the other native tests running concurrently and are not isolated
resource measurements. Neither run shortened the 1h/3h fixtures or the large
import/read inputs.

The required server gate passed formatting, lint, TypeScript, generated-contract
determinism, **262 unit tests**, **17 Workers tests**, and both Worker bundle
builds. The native gate passed Swift formatting, **8 contract tests**, the full
**135 native tests**, both **Trigo Dev and Trigo Debug app builds** with signing
disabled, and the isolated **local Worker/R2/fake-ASR smoke with external network
denied**. Native test-host time was 126.291 s and the test command phase took
127.788 s. The two app-build phases took 25.761 s and 5.116 s; smoke took 5.785 s.
Dependency locks, generated contracts, toolchain pins and vendored Effect source
remain unchanged.

Raw logs are under `/tmp/trigo-epic-48/`: `52-check-server.log`,
`52-check-macos.log` and `52-check-macos.jsonl`, `52-sql-focused-fourth.log`, and
the pre-optimization baseline `52-paced-contention.log`. The short read-only
stack diagnostic is `52-paced-sample.txt`; it identified schema reference/Regex
construction during exchange validation, while capture continued SQL work. No
validator bypass, dependency upgrade or schema-library fork was introduced.

```sh
mise install
mise exec -- bun install --frozen-lockfile
mise exec -- bun run macos:setup
mise exec -- bun run check:server
TRIGO_TIMINGS_FILE=/tmp/trigo-epic-48/52-check-macos.jsonl mise exec -- bun run check:macos
```

The new repository fixtures request no device access, TCC, Keychain, personal
archive, installed app, hosted ASR or cloud credentials. The pre-existing full
native suite includes a Keychain adapter test that creates, reads and deletes a
synthetic token under a UUID-scoped `io.github.apshenichniy.trigo.tests` service;
it does not target installed-app credentials. Local SQLite/process-termination
evidence does not replace production capture integration, installed-device
acceptance, hardware power-loss testing or provider compatibility gates.

## Integrated source

The completed worker commit is `b811b0c7dd7b8d4bc948b7d56d1c48065890108f`.
It was integrated as `64e729f724e6900d9e03123020dccb35c803e747`; both have the
exact tree `4499dd3f20bdc65728b8365bd69e2e62a0ed5439`. The scoped integration
changed the same 35 files and passed `git diff --check`, with no conflicts or
source changes after the worker's successful gates.

Both jobs passed in [integrated CI run 34068481006](https://github.com/apshenichniy/trigo/actions/runs/34068481006)
on `4024dc2e5907399bf193c295fb10e42df2eabeb8`. The earlier run stopped on a
parent-authored acceptance-table formatting error; the follow-up changed only
that Markdown formatting. The [server job](https://github.com/apshenichniy/trigo/actions/runs/34068481006/job/101581398477)
passed all 262 unit and 17 Workers tests. The [macOS job](https://github.com/apshenichniy/trigo/actions/runs/34068481006/job/101581398578)
passed all eight contract and 135 native tests, both Debug app builds, the
network-denied local smoke, nested-lock restoration and clean-tree checks.

On that runner the full native test host took 85.874 s. The complete macOS check
step took 251 s, including native compilation; app builds took 37.848 s and
11.977 s, and local smoke took 6.836 s. The full one-hour source-relative drift
was again 0.0 ms. The contention fixture completed all three imports, 12,000
turns, 11,111,043 input bytes and 24 oversized typed reads while committing 388
maximum-density media batches. Maximum complete service was 474.773708 ms,
95th percentile was 44.564875 ms, and maximum one-second input plus service was
1,474.773708 ms, within the two-second bound. These are observed runner results,
separate from the local measurements above.

The integrated raw evidence is `/tmp/trigo-epic-48/52-ci-fixed-jobs.json`,
`52-ci-fixed-server.log`, `52-ci-fixed-macos.log` and `52-ci-fixed-watch.log`.
