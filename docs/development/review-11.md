# Independent implementation review — #11

Base: initial documentation commit `14a6542473eb250156df9e4785b7087352228832`.
Two independent reviewers inspected the foundation; the implementation agent then
fixed the findings and reran relevant checks. No owner decision or product-contract
change was needed.

## Standards

No documented-standard breach was found. Two judgment-call maintenance findings
were resolved:

1. The native wrapper duplicated the lock inventory/snapshot and omitted missing
   locks. Build/run/archive now use `snapshotLocks`; dependency update is explicit.
2. Doctor repeated Xcode/XcodeGen checks already performed by the shared toolchain
   boundary. Native expectations/execution now live in `toolchain.ts`.

Result: two maintenance findings addressed; no blocking standards issue.

## Spec

Two P2 findings were reproduced and resolved:

1. A dummy HTTP server on the smoke port could produce a false successful runtime
   result. Smoke now allocates a fresh port, refuses occupied requested ports and
   checks its per-launch UUID before sending writes. The reviewer reran the dummy
   server reproduction: it exits nonzero with `Local port unavailable`.
2. Aggregate validation allowed speaker/turn UUIDs to be reused across retained
   revisions. Both languages now enforce cross-revision uniqueness. Two invalid
   shared fixtures and a valid fresh-transcription fixture cover the boundary.

The reviewer rechecked these fixes and found no remaining concrete blocker. The
agent's installed-app inspection additionally caught an omitted Info.plist worktree
key; explicit generated plists and build-time identity assertions cover that gap.

Result: two specification findings addressed; no remaining specification blocker
identified by review. Runtime/CI acceptance is recorded separately.
