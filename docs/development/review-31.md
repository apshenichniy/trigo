# Independent implementation review — #31

Reviewed implementation range:
`e1d3ce4d7384267164bbdbb8ae5af5471d8ce3ab..6b9ea77f2a8c5c84fe3bc2b7927d1ebdb7af333c`.

Two independent reviewers inspected the macOS archive-connection implementation.
The implementation agent fixed each finding, reran the focused tests and returned
the exact range for follow-up review.

## Standards

The first pass found five concrete persistence and recovery issues:

1. Failed Keychain cleanup could orphan a pending credential without a durable
   retry checkpoint, and a same-process retry could overwrite that checkpoint.
2. Persisted stage and credential-account relationships were not fully validated,
   so corrupt metadata could become eligible or make cleanup target an active token.
3. Empty-host and out-of-range-port HTTPS inputs could pass canonicalization.
4. Metadata permissions were changed after atomic replacement, leaving a throwable
   post-commit step and a transient permission boundary.
5. A blocked connection had no explicit retry using the saved Keychain credential.

Follow-up changes retain failed cleanup state, drain it before another candidate,
validate namespace and account invariants, reject malformed origins, prepare and
synchronize a mode-`0600` temporary file before atomic rename, and expose retry of
the saved connection. A final P2 found that a thrown Keychain read was presented as
a network outage; credential loading now has its own failure boundary and returns
before any request.

The final re-review reported no findings. The throwing-load regression verifies
the durable binding, local eligibility, actionable credential state and zero
network requests. All five initial findings remain resolved.

## Spec

The first pass found one P1 partial-failure gap: if candidate-token deletion failed
after a metadata commit failure, the orphan could be lost from durable recovery
state. The corrected transaction preserves the pending checkpoint until deletion
and metadata cleanup both succeed; relaunch and same-process regressions cover the
two recovery paths.

The final full-range re-review reported no findings. It confirmed durable
same-archive binding, fail-closed replacement, retryable Keychain/metadata recovery,
namespace isolation and local-recording eligibility independent of blocked server
operations.

## Live acceptance seam

The final test-only commit adds an opt-in live suite around the same production
HTTPS, metadata and Keychain adapters used by the app. Normal checks skip it unless
an explicit handoff path is present. Review found that the first version used
non-fatal post-mutation assertions and read the handoff without the operator
boundary's file protections. The corrected harness validates the regular,
non-symbolic, mode-`0600`, bounded file and the full rotate target before a
non-mutating authenticated stage/archive preflight. A follow-up corrected a
false-positive fixture and aligned UTC timestamp and UUIDv4 rules with the
production schema.

The final re-review reported no findings. The authorized run proved
first/same-archive pairing, wrong-token preservation, new-actor restoration and
private metadata permissions; details are in
[Issue #31 acceptance](acceptance-31.md).
