# Cloudflare infrastructure-state recovery

Status: source-research draft for issue #32. No recovery rehearsal, cloud
mutation, deployment, or personal-environment acceptance has been performed.

This document covers Alchemy infrastructure state for Trigo's Cloudflare stack.
It does not turn infrastructure state into a backup of call audio, canonical call
documents, or the D1 catalog. Those remain product data with their own retention
and recovery requirements.

## Source baseline

The conclusions below are intentionally version-specific:

- Trigo pins `alchemy@2.0.0-beta.76`. With the default state configuration used
  by #29, its Cloudflare state layer targets the account-wide
  `alchemy-state-store` Worker and stores its root index and per-stack resource
  records in SQLite-backed Durable Objects.
- The state Worker reads `AlchemyStateStoreEncryptionKey` from Cloudflare
  Secrets Store and uses that 32-byte key to encrypt every resource record. A
  replacement key cannot decrypt existing ciphertext.
- `alchemy state export` reads all resource records and serializes redacted
  values as `{ "__redacted__": <actual value> }`. The resulting JSON is a
  secret-bearing plaintext export, not a redacted report.
- The pinned CLI registers `state export` but no `state import`. Its deploy CLI
  does register `--adopt`, explicitly described as useful for importing
  pre-existing infrastructure into a fresh state store.
- On a state cold start, Alchemy asks each provider to find the physical
  resource. A plain provider result is silently adopted; an unowned result is
  rejected unless `--adopt` is set. Adoption then performs an update so tags and
  desired configuration converge.

Pinned implementation sources:

- [State bootstrap, credentials, and state-Worker adoption](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/StateStore/State.ts)
- [Encrypted Durable Object store](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/StateStore/Store.ts)
- [State token and encryption-key resources](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/StateStore/Token.ts)
- [State Worker contract and public version endpoint](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/StateStore/Api.ts)
- [State export and registered state commands](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cli/commands/state.ts)
- [State export document shape](https://unpkg.com/alchemy@2.0.0-beta.76/src/State/Export.ts)
- [`--adopt` deploy option](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cli/commands/deploy.ts)
- [Adoption ownership rules](https://unpkg.com/alchemy@2.0.0-beta.76/src/AdoptPolicy.ts)
- [State encoding, including unwrapped redacted values](https://unpkg.com/alchemy@2.0.0-beta.76/src/State/StateEncoding.ts)
- [State-only random provider](https://unpkg.com/alchemy@2.0.0-beta.76/src/Random.ts)
- [Secrets Store secret reconciliation](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/SecretsStore/Secret.ts)

Current Cloudflare sources establish the platform boundary:

- Secrets Store never returns a secret value through its API or dashboard; a
  bound service can read it. Cloudflare supports replacing a secret value with
  `PATCH`, so an externally escrowed key can be restored in place. See
  [Manage account secrets](https://developers.cloudflare.com/secrets-store/manage-secrets/)
  and [Patch a secret](https://developers.cloudflare.com/api/resources/secrets_store/subresources/stores/subresources/secrets/methods/edit/).
- A forced Worker deletion is not a code-only deletion: Cloudflare states that
  associated Durable Objects are deleted with the script. See
  [Delete Worker](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/delete/).
- SQLite-backed Durable Objects have per-object Point In Time Recovery (PITR)
  for SQL and KV data for up to 30 days, but the restore calls run through the
  Durable Object storage API. The pinned Alchemy Worker exposes no PITR route or
  CLI command. See
  [SQLite-backed Durable Object Storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/#pitr-point-in-time-recovery-api).
- Worker versions do not back up Durable Object, R2, or D1 state. A Worker
  rollback cannot restore deleted storage. See
  [Versions and deployments](https://developers.cloudflare.com/workers/versions-and-deployments/)
  and [Rollbacks](https://developers.cloudflare.com/workers/versions-and-deployments/rollbacks/).
- The read-only classification calls below use Cloudflare's current
  [Secrets Store API](https://developers.cloudflare.com/api/resources/secrets_store/)
  and [Durable Object namespace list](https://developers.cloudflare.com/api/resources/durable_objects/subresources/namespaces/methods/list/).

## Result

There is a defensible recovery design, but it is not accepted yet:

1. Preserve a full Alchemy state export in encrypted custody and separately
   escrow the exact state encryption key while the state store is healthy.
2. Restore a lost key in place before any Alchemy plan, bootstrap, upgrade, or
   deploy reads the encrypted records.
3. For lost product-stack records or a completely rebuilt state backend, use a
   reviewed `deploy --dry-run --adopt` followed by `deploy --adopt`. The current
   Trigo resource set is discoverable by stable name and/or Alchemy ownership
   tags, so adoption should retain its physical identities.
4. Treat the export as evidence and emergency input, not as an automatically
   restorable backup: version 2.0.0-beta.76 has no importer and does not include
   stack outputs in `state export`.
5. Rehearse key restoration and fresh-state adoption against a disposable
   Cloudflare account before opening the first personal deployment gate.

The final step is mandatory. Source inspection proves available mechanisms, not
their safe composition on Trigo's deployed resource graph.

## Failure matrix

| Failure                                                            | What remains                                                                                              | Source-supported recovery path                                                                                                                                    | Data/identity at risk                                                                                                                         | Unsupported or unproved boundary                                                                                                              | Gate                                                                                       |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Lost local Alchemy credential cache                                | State Worker, Durable Object records, Secrets Store token, and encryption key                             | Authenticate the same profile and replay `cloud:bootstrap`; pinned Alchemy reads the auth token through an ephemeral Worker preview and recreates the local cache | None if the account/profile is correct                                                                                                        | This does not test remote-state or key loss                                                                                                   | Covered by #29, not a #32 disaster                                                         |
| State Worker exists but does not serve `/version`                  | The script, namespace, records, and secrets may still exist                                               | Freeze writers; inventory the script, namespace, deployments, and secrets. Prefer rollback to a known compatible Worker version when Cloudflare permits it        | A blind bootstrap can redeploy against incomplete state and rotate generated secrets                                                          | Rollback restores code/bindings, not storage; the exact incident path remains rehearsal-only                                                  | Pending                                                                                    |
| State Worker was deleted                                           | Product R2, D1, Workflow, and API Worker may remain; the state namespace does not survive a forced delete | Bootstrap a fresh state backend, inventory exact product resources, dry-run adoption, then adopt the existing product resources                                   | All infrastructure records and any values observable only from state                                                                          | Cloudflare's forced delete removes associated Durable Objects. There is no deleted-namespace restore path in the cited API                    | Pending destructive rehearsal                                                              |
| Some product-stack state records are missing, key intact           | State Worker and physical product resources remain                                                        | Use provider discovery plus `deploy --dry-run --adopt`, inspect every planned identity/action, then `deploy --adopt`                                              | Non-observable provider properties, generated values, and incomplete replacement history                                                      | `state export` has no importer. PITR is possible only through a recovery-capable Durable Object code path that pinned Alchemy does not expose | Pending destructive rehearsal                                                              |
| `CloudflareStateStore` bootstrap records are missing, key intact   | State Worker, ciphertext, and key may still work                                                          | Do not force-upgrade. Preserve all readable state and the key, then choose either custom PITR or a controlled fresh-state rebuild plus product adoption           | A forced state-Worker reconcile can regenerate the `Alchemy.Random` key input and patch the existing secret, making old ciphertext unreadable | Pinned Alchemy has no safe command to reconstruct only its own bootstrap records                                                              | Pending focused recovery implementation/rehearsal                                          |
| Encryption-key secret missing or wrong, records intact             | State Worker and ciphertext remain, but records cannot be decoded                                         | Restore the exact 64-hex-character key from external escrow into the same named secret, wait for active status, then verify state before any deploy               | Every encrypted state record; writes made under a wrong replacement key create a mixed-key store                                              | Cloudflare cannot reveal an existing secret value; generating a new key does not recover old ciphertext                                       | Pending destructive rehearsal                                                              |
| Encryption key unavailable, but a complete plaintext export exists | Physical product resources and a secret-bearing export remain                                             | Rebuild state and adopt discoverable resources; retain the export for comparison or a future importer                                                             | Values that cannot be rediscovered from providers                                                                                             | There is no pinned importer, and importing state-Worker self-records into a newly created backend is not a reviewed procedure                 | Unsupported as automatic restore                                                           |
| Encryption key and usable state export both unavailable            | Only discoverable physical resources remain                                                               | Fresh state plus narrowly reviewed adoption can reconstruct discoverable resources                                                                                | Generated secrets, unobservable provider state, replacement history, and stack outputs                                                        | Exact state recovery is impossible from the cited mechanisms                                                                                  | Unsupported exact recovery; owner decision required if rehearsal exposes such a dependency |
| R2 object or D1 row was deleted while infrastructure state remains | Infrastructure identities may be intact                                                                   | Use the product-data recovery mechanism, not Alchemy state                                                                                                        | Private archive content                                                                                                                       | R2 durability does not protect intentional/accidental deletion; D1 Time Travel is limited and does not restore R2                             | Outside infrastructure-state recovery                                                      |

### Why current Trigo resources are adoptable candidates

Issue #29's current interface uses stable `dev` and `personal` names for a
private retained R2 bucket, retained D1 database, API Worker, and Workflow. In
the pinned providers:

- R2 reads a bucket by its desired name and returns its existing attributes.
- D1 falls back from a missing stored UUID to an exact name lookup and returns
  the existing database UUID.
- Workflow reads by its desired physical name, and its PUT is an upsert that
  preserves the existing Workflow ID.
- Worker reads by its desired script name. Matching Alchemy tags prove
  ownership; `--adopt` is required when that positive ownership signal is not
  present.

See the pinned [R2 provider](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/R2/Bucket.ts),
[D1 provider](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/D1/Database.ts),
[Workflow provider](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/Workflows/Workflow.ts),
and [Worker provider](https://unpkg.com/alchemy@2.0.0-beta.76/src/Cloudflare/Workers/WorkerProvider.ts).

This is not a blanket claim that every future MVP resource is adoptable. Before
the rehearsal, compare the integrated #29/#30 resource graph with the provider
list again. Any resource whose identity or secret value exists only in lost
Alchemy state must be added to backup custody or given a purpose-built restore
path.

## Backup custody

### Required artifacts

Maintain these artifacts after the first accepted dev deployment, before the
first personal deployment, and after any infrastructure identity or secret
change:

1. **Full state export in encrypted custody.** Store the complete
   `alchemy state export` output only in encrypted custody. It contains
   unwrapped secret values despite the `__redacted__` marker.
2. **Separately escrowed state encryption key.** Extract the
   `StateStoreEncryptionKeyValue` `Alchemy.Random` value from a healthy export
   and keep a separately recoverable copy. This is the value needed to repair
   `AlchemyStateStoreEncryptionKey` in place.
3. **Non-secret inventory manifest.** Record Alchemy version, state-store
   contract version, Cloudflare account, stack/stage, physical resource names
   and IDs, export timestamp, record count, and ciphertext-independent backup
   checksum. Do not record tokens, key material, private object contents, or
   signed URLs in this manifest.
4. **Product-data recovery record.** Separately record the policy and evidence
   for local canonical data, R2 objects, and D1 catalog data. The Alchemy export
   contains resource metadata, not those payloads.

Use two independent encrypted custody locations controlled by the owner. At
least one must remain available after loss of the current Mac and Cloudflare
account session. The state export and key escrow must not live only in the same
Cloudflare account they recover. Test retrieval without printing their contents.

R2's durability documentation explicitly says durability does not prevent
intentional or accidental deletion. Bucket locks can prevent overwrite/deletion
for a chosen retention period, while deleting an unlocked object is not
recoverable through the documented bucket deletion flow. See
[R2 durability](https://developers.cloudflare.com/r2/reference/durability/),
[bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/), and
[delete buckets](https://developers.cloudflare.com/r2/buckets/delete-buckets/).
D1 Time Travel is automatic but limited to 30 days on Workers Paid and 7 days on
Workers Free, and restoring overwrites the database in place. See
[D1 Time Travel](https://developers.cloudflare.com/d1/reference/time-travel/).

### Backup validation

A backup is usable only when all of the following are true:

- JSON parsing succeeds and the export contains both the
  `CloudflareStateStore` stack and the expected `trigo-cloud` stage.
- Exactly one `Alchemy.Random` record has logical ID
  `StateStoreEncryptionKeyValue`, and its redacted payload is 64 lowercase hex
  characters.
- The manifest checksum matches the encrypted custody copy after retrieval.
- The manifest's account, stage, resource names, and IDs match read-only
  Cloudflare inventory.
- No backup command or acceptance record prints a token or key.

## Recovery ordering

The ordering is part of the safety boundary:

1. **Freeze writers.** Stop state bootstrap, deploy, state maintenance, D1
   mutation, and product writes for the affected account/stack/stage. Record the
   last known successful operation and time.
2. **Classify before mutating.** Inspect `/version`, Worker settings and
   deployments, Durable Object namespaces, Secrets Store metadata, and product
   resource inventory. Distinguish a local-cache failure from missing records,
   missing key, non-serving code, and deleted Worker/namespace.
3. **Preserve remaining recovery points.** Retrieve the latest encrypted export
   and key escrow. If the state store still reads, take a new export. Record a D1
   bookmark before any D1 restore. Do not force-bootstrap a partially healthy
   state backend.
4. **Restore the exact key first** when its secret alone is missing or wrong.
   Wait until Cloudflare reports the secret active. Prove state reads before any
   Alchemy plan or deploy.
5. **Restore state records second.** Prefer in-place PITR only if a reviewed
   recovery Worker can target every affected named object within the retention
   window. Otherwise bootstrap a fresh state backend and use narrowly reviewed
   product-resource adoption.
6. **Adopt before ordinary deployment.** Run an adoption dry run; reject creates,
   replacements, deletes, renames, resource-name changes, new archive identity,
   or a different account. Only then run the adoption apply.
7. **Verify data and identities.** Prove the same R2 fixture, D1 fixture and
   database UUID, Workflow ID, API Worker identity/URL, stack/stage, and archive
   identity where #30 establishes it.
8. **Resume one writer.** Run the ordinary #29 verifier and repeat deploy only
   after recovery verification passes. Re-enable application writes last.

## Operator runbook draft

The commands below are non-secret templates. They have **not** been executed in
this research phase. Cloud mutations in sections marked `MUTATION` require a
separate owner authorization and a disposable target for rehearsal.

### 1. Set an explicit recovery context

Run from a clean checkout of the exact reviewed recovery revision. Keep the API
token in the process environment using the operator's secret manager; do not put
it in the command line or stage JSON.

```sh
set -eu
umask 077

TRIGO_RECOVERY_STAGE=dev
TRIGO_RECOVERY_PROFILE=trigo-cloud-dev
TRIGO_RECOVERY_CONFIG=config/cloud/dev.json
TRIGO_ALCHEMY=infra/node_modules/.bin/alchemy
TRIGO_STATE_WORKER=alchemy-state-store
TRIGO_RECOVERY_DIR=/absolute/path/on-an-encrypted-private-volume/trigo-recovery

: "${TRIGO_STATE_URL:?set to the exact https origin of alchemy-state-store}"
test -d "$TRIGO_RECOVERY_DIR"
test -f "$TRIGO_RECOVERY_CONFIG"
test -x "$TRIGO_ALCHEMY"
test -n "${CLOUDFLARE_API_TOKEN:-}"

TRIGO_ACCOUNT_ID="$(jq -er '.accountId' "$TRIGO_RECOVERY_CONFIG")"
test "${#TRIGO_ACCOUNT_ID}" -eq 32
```

For the accepted implementation, confirm the stage map before continuing:

```sh
test "$(jq -er '.stage' "$TRIGO_RECOVERY_CONFIG")" = "$TRIGO_RECOVERY_STAGE"
test "$(jq -er '.profile' "$TRIGO_RECOVERY_CONFIG")" = "$TRIGO_RECOVERY_PROFILE"
```

### 2. Read-only classification

Probe the public state contract without credentials:

```sh
curl --fail-with-body --silent --show-error \
  "${TRIGO_STATE_URL%/}/version" |
  jq -e '.version == 7'
```

Inventory the Worker, state namespace, Secrets Store metadata, and product
resources with Cloudflare's read APIs. These responses contain identifiers and
configuration; retain them as private operator evidence.

```sh
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/workers/scripts/$TRIGO_STATE_WORKER/settings" |
  jq -e '.success == true'

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/workers/durable_objects/namespaces?per_page=1000" |
  jq -e --arg worker "$TRIGO_STATE_WORKER" \
    '.success == true and ([.result[] | select(.script == $worker and .class == "Store")] | length == 1)'

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/secrets_store/stores?per_page=100" |
  jq -e '.success == true and (.result | length == 1)'
```

When the state Worker is readable, inspect the state tree. This proves the
unencrypted indexes are readable; it does not by itself prove that the key can
decrypt each resource record.

```sh
mise exec -- bun --bun "$TRIGO_ALCHEMY" state tree \
  --profile "$TRIGO_RECOVERY_PROFILE" infra/cloud.ts
```

If this fails, stop. Do not convert a read failure into an automatic bootstrap.

### 3. Capture and validate a healthy backup

This writes secret-bearing plaintext. `TRIGO_RECOVERY_DIR` must already be on an
owner-approved encrypted private volume; move the result into the two approved
custody locations immediately after validation.

```sh
TRIGO_STATE_EXPORT="$TRIGO_RECOVERY_DIR/alchemy-state.json"
TRIGO_STATE_KEY="$TRIGO_RECOVERY_DIR/alchemy-state-key.hex"
TRIGO_STATE_CHECKSUM="$TRIGO_RECOVERY_DIR/alchemy-state.sha256"

mise exec -- bun --bun "$TRIGO_ALCHEMY" state export \
  --profile "$TRIGO_RECOVERY_PROFILE" infra/cloud.ts > "$TRIGO_STATE_EXPORT"

jq -e '.resources | type == "array" and length > 0' "$TRIGO_STATE_EXPORT" >/dev/null

jq -e --arg stage "$TRIGO_RECOVERY_STAGE" '
  ([.resources[] | select(.stack == "CloudflareStateStore")] | length > 0)
  and ([.resources[] | select(.stack == "trigo-cloud" and .stage == $stage)] | length > 0)
' "$TRIGO_STATE_EXPORT" >/dev/null

jq -er '
  [
    .resources[]
    | select(
        .stack == "CloudflareStateStore"
        and .state.resourceType == "Alchemy.Random"
        and .state.logicalId == "StateStoreEncryptionKeyValue"
      )
    | .state.attr.text.__redacted__
  ]
  | if length == 1 then .[0] else error("expected one state encryption key") end
' "$TRIGO_STATE_EXPORT" > "$TRIGO_STATE_KEY"

grep -Eq '^[0-9a-f]{64}$' "$TRIGO_STATE_KEY"
chmod 600 "$TRIGO_STATE_EXPORT" "$TRIGO_STATE_KEY"
shasum -a 256 "$TRIGO_STATE_EXPORT" > "$TRIGO_STATE_CHECKSUM"
```

Do not attach these files to GitHub, CI artifacts, logs, chat, or the repository.
Only the checksum, timestamp, record count, and non-secret inventory belong in an
acceptance record.

### 4. Restore a missing key in place — MUTATION

Use this path only when the state Worker and Durable Object namespace/records
still exist and the exact old key is available. The API token requires Secrets
Store edit permission. First resolve the store and secret IDs from metadata:

```sh
TRIGO_STORE_ID="$(
  curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/secrets_store/stores?per_page=100" |
    jq -er '.result | if length == 1 then .[0].id else error("expected one Secrets Store") end'
)"

TRIGO_KEY_SECRET_ID="$(
  curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/secrets_store/stores/$TRIGO_STORE_ID/secrets" |
    jq -er '
      [.result[] | select(.name == "AlchemyStateStoreEncryptionKey")]
      | if length == 1 then .[0].id else error("state encryption-key secret is absent or ambiguous") end
    '
)"
```

Patch through stdin so the key does not enter shell history or process arguments:

```sh
jq -n --rawfile value "$TRIGO_STATE_KEY" \
  '{value: ($value | rtrimstr("\n")), scopes: ["workers"], comment: "Alchemy state-store encryption key"}' |
  curl --fail-with-body --silent --show-error \
    --request PATCH \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/secrets_store/stores/$TRIGO_STORE_ID/secrets/$TRIGO_KEY_SECRET_ID" |
  jq -e '.success == true' >/dev/null
```

Poll the non-secret status with a bounded wait, then rerun a fresh export and
the validation in section 3. A successful tree alone is insufficient because
its indexes are not encrypted.

```sh
TRIGO_KEY_STATUS=pending
TRIGO_KEY_ATTEMPT=0
while [ "$TRIGO_KEY_STATUS" != active ] && [ "$TRIGO_KEY_ATTEMPT" -lt 30 ]; do
  TRIGO_KEY_STATUS="$(
    curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/$TRIGO_ACCOUNT_ID/secrets_store/stores/$TRIGO_STORE_ID/secrets/$TRIGO_KEY_SECRET_ID" |
      jq -er '.result.status'
  )"
  TRIGO_KEY_ATTEMPT=$((TRIGO_KEY_ATTEMPT + 1))
  [ "$TRIGO_KEY_STATUS" = active ] || sleep 2
done
test "$TRIGO_KEY_STATUS" = active
```

If the named secret was deleted rather than patched, the create path and
binding propagation must be rehearsed separately; do not improvise it on
personal.

### 5. Rebuild state and adopt product resources — MUTATION

This path is only for an authorized disposable account rehearsal or an approved
real incident after the old backend has been classified as unrecoverable. A
disposable rehearsal must not share the account-wide `alchemy-state-store` with
any other stack.

After authorized bootstrap of a fresh backend, run a read-only adoption plan:

```sh
mise exec -- env \
  ALCHEMY_PROFILE="$TRIGO_RECOVERY_PROFILE" \
  CLOUDFLARE_ACCOUNT_ID="$TRIGO_ACCOUNT_ID" \
  TRIGO_CLOUD_STAGE="$TRIGO_RECOVERY_STAGE" \
  bun --bun "$TRIGO_ALCHEMY" deploy \
    --stage "$TRIGO_RECOVERY_STAGE" \
    --profile "$TRIGO_RECOVERY_PROFILE" \
    --dry-run --adopt infra/cloud.ts
```

Reject the plan if it creates, replaces, deletes, or renames the retained R2 or
D1 resources, changes their physical names/IDs, points to another account, or
changes archive identity. After a human reviews and separately authorizes that
exact plan, apply adoption:

```sh
mise exec -- env \
  ALCHEMY_PROFILE="$TRIGO_RECOVERY_PROFILE" \
  CLOUDFLARE_ACCOUNT_ID="$TRIGO_ACCOUNT_ID" \
  TRIGO_CLOUD_STAGE="$TRIGO_RECOVERY_STAGE" \
  bun --bun "$TRIGO_ALCHEMY" deploy \
    --stage "$TRIGO_RECOVERY_STAGE" \
    --profile "$TRIGO_RECOVERY_PROFILE" \
    --yes --adopt infra/cloud.ts
```

Do not use `--force`, `state clear`, `unsafe nuke`, state-store teardown, an
improvised resource name, or the personal target in the first rehearsal.

### 6. Post-recovery verification

Compare against the pre-failure manifest and seed ID:

```sh
mise exec -- bun run test:cloud \
  --stage "$TRIGO_RECOVERY_STAGE" --verify "$TRIGO_FIXTURE_ID"

mise exec -- bun --bun "$TRIGO_ALCHEMY" state tree \
  --profile "$TRIGO_RECOVERY_PROFILE" infra/cloud.ts

mise exec -- bun run cloud:deploy --stage "$TRIGO_RECOVERY_STAGE"
mise exec -- bun run test:cloud \
  --stage "$TRIGO_RECOVERY_STAGE" --verify "$TRIGO_FIXTURE_ID"
```

Acceptance evidence must prove, before and after recovery:

- the same private R2 bucket name and seeded object content/checksum;
- the same D1 database UUID and seeded catalog row;
- the same Workflow ID and API Worker identity/origin;
- the same `trigo-cloud/dev` stage and expected resource FQNs;
- the same archive identity after #30 establishes it;
- disabled R2 public access and no unexpected custom domains;
- no Workers AI invocation and no private payload or secret in evidence; and
- a repeat deployment plus verification from a fresh local credential cache.

## Unsupported boundaries

- **No state import:** the pinned export is not automatically restorable. A
  future importer must restore resource records and stack outputs deliberately,
  validate schema/version, avoid importing stale state-Worker self-identities,
  and be rehearsed before it becomes an operator tool.
- **No pinned PITR surface:** Cloudflare can restore an individual SQLite-backed
  Durable Object, but Alchemy 2.0.0-beta.76 exposes no authenticated operation to
  choose the root and per-stack objects, select bookmarks, restart them, and
  verify all records. Adding that surface is a recovery implementation decision,
  not a documented command.
- **No secret history:** Cloudflare cannot reveal or roll back a Secrets Store
  value. In-place key repair requires independent escrow of the exact old value.
- **No deleted namespace recovery:** forced Worker deletion removes associated
  Durable Objects. Recreating the same Worker name creates a new state backend;
  it does not restore deleted ciphertext.
- **No general adoption guarantee:** adoption is credible for the current stable
  R2/D1/Workflow/Worker graph. It does not prove future resources whose values or
  identity are not discoverable from Cloudflare and source configuration.
- **No archive-data recovery claim:** Worker rollback and Alchemy state recovery
  do not restore R2 objects or D1 rows. R2 deletion prevention/backup and D1 Time
  Travel remain separate product-data controls.

## Rehearsal gate

Rehearsal acceptance is **pending**. The first personal deployment gate in #32
must remain closed until the following concrete target and authority exist:

- a disposable Cloudflare account whose account-wide `alchemy-state-store`,
  Secrets Store, Durable Object namespace, `trigo-dev-*` resources, and fixtures
  are dedicated to this rehearsal and contain no unrelated data;
- explicit owner authorization naming that account and permitting the planned
  state-record deletion, encryption-key replacement/restoration, and forced
  state-Worker deletion/rebootstrap sequence;
- one designated deployment/state writer for the account and confirmation that
  no other task is mutating it;
- accepted #29 bootstrap/deploy/verifier commands and a review of the integrated
  #29/#30 resource graph for additional non-adoptable secrets or identities; and
- an agreed cost reservation inside the Goal's shared EUR 20 ceiling. The
  rehearsal must make no Workers AI request.

A separate stage or profile in the owner's shared Cloudflare account is not an
isolated target: the pinned state Worker and Secrets Store are account-wide. If a
disposable account cannot be provided, the focused owner decision is whether to
fund and implement a non-destructive importer/PITR recovery tool before personal
deployment or accept an explicitly narrower recovery objective. The gate must
not be silently waived.
