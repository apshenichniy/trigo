# Verified uploads and hosted profile integration

This integrates the tested upload implementation from PR #75 (`773f916f6`) with
main `fc207b621`, which contains the hosted-master proof from PR #76 and the
desktop shell from PR #74. It is the prerequisite candidate for the first-use
scope in issue #10 and delivery task #24.

The only textual conflict was the shared structural fixture list. Both additions
are retained: upload request/receipt cases and the selected master-stream
transcript profile. The combined list contains 149 unique cases. Re-running
`bun run contracts:generate` confirms that the combined Effect definitions emit
the checked-in JSON/Swift artifacts without additional changes.

The server composition retains authenticated product upload routes and the
separate dev-only hosted probes. `storedMaster` remains the production trust
boundary for ASR and playback: the verified receipt, exact retained audio-manifest
bytes and private server-resolved master key travel together. A stored master
does not imply a transcript, local import or canonical replica confirmation.

The relevant existing acceptance records remain scoped to their recorded inputs:
[upload acceptance](acceptance-17.md) and
[hosted-master acceptance](acceptance-13-hosted-master.md). This merge performs
no hosted request, cloud deployment or installed capture. The hosted profile and
its one-/three-hour evidence are retained without rerunning inference.

Combined server verification passed 407 unit tests and 64 Workers-runtime tests
in 44.869 seconds. Full native verification uses `bun run check:macos`, including
the shared fixtures, all native suites, both app variants and the actual local
Worker upload/receipt recovery path. Final run identities, outcomes and timings
belong in PR #75 with the required CI result; historical component evidence does
not replace that integration gate.

The full integrated macOS check passed in 760.369 seconds, including both Debug
app variants and local Worker/native receipt recovery. Integration review then
found that a failed initial archive recovery prevented the application upload
owner from starting after a successful local recovery retry. The new regression
test first failed on `2d9071613` with only that test added: the recovered call had
no durable upload operation after three seconds. Starting the upload owner after
successful recovery fixes this without reconnecting or relaunching. All six
focused recovery tests pass; the fixture reports server operations unavailable
and performs no external request. The final candidate's affected native checks
and full required CI results are recorded in the PR.

Downstream first-use work remains #18, #19, #20, #73, #45, #58 and #72. Export,
manual re-transcription and Delete Call remain deferred in #21/#22. Owner-operated
Meet/Telegram acceptance follows the runnable handoff in #23.
