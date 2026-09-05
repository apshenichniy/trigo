# Cloud operations

This runbook covers the Cloudflare infrastructure owned by issue #29. It is an
operator procedure, not an ordinary development prerequisite. Every cloud command
requires both an explicit stage and a matching local configuration. Running a
bootstrap, deployment or remote fixture command also requires separate owner
authorization for that cloud mutation.

The implementation is pinned to Bun 1.3.13, Effect 4.0.0-rc.112, Alchemy
2.0.0-beta.76 and Wrangler 4.124.0. Use the repository wrappers; do not substitute
syntax or state-store behavior from a newer Alchemy release.

## Targets and retained resources

Both targets use the `trigo-cloud` stack name. Alchemy separates their state by
stage, while the pinned `Cloudflare.state()` backend is the single account-wide
`alchemy-state-store` Worker. Resource names are closed and stable:

| Stage      | Profile                | R2 archive               | D1 catalog               | API Worker           | Workflow declaration ID           |
| ---------- | ---------------------- | ------------------------ | ------------------------ | -------------------- | --------------------------------- |
| `dev`      | `trigo-cloud-dev`      | `trigo-dev-archive`      | `trigo-dev-catalog`      | `trigo-dev-api`      | `trigo-dev-archive-workflow`      |
| `personal` | `trigo-cloud-personal` | `trigo-personal-archive` | `trigo-personal-catalog` | `trigo-personal-api` | `trigo-personal-archive-workflow` |

R2 public access is disabled and no custom domain is configured. The R2 bucket
does not permit force-empty deletion. Both R2 and D1 have a retain removal policy,
so removing or replacing their declarations does not silently delete stored data.
Changing a stable name creates a different resource and requires a separately
reviewed migration. Do not destroy or rename resources as part of a routine deploy.
The Workflow column is Alchemy's stable logical declaration ID. In this pinned
release, the account-global Cloudflare Workflow name is deterministically derived
from the stable Worker name and exported `PendingArchiveWorkflow` class, with a
hash suffix; do not hard-code or rename that derived physical value.

The Worker receives `ARCHIVE`, `CATALOG`, `ARCHIVE_WORKFLOW`, `AI` and
`DEPLOYMENT_STAGE`. The Workflow entrypoint is deliberately unavailable until its
owning feature is implemented. `/v1/*` also remains unavailable until issue #30
adds archive identity, owner-token administration and authentication. The
infrastructure diagnostic checks binding shape without reading storage, starting a
Workflow or making a Workers AI inference.

## Local stage configuration

Create the ignored stage file from its tracked template:

```sh
cp config/cloud/dev.example.json config/cloud/dev.json
```

Replace `accountId` with the 32-character Cloudflare account ID. Keep `stage` and
`profile` unchanged. Do not add API tokens or state-store secrets to the JSON file.
After the first deployment, add its exact HTTPS Worker origin as `apiUrl`:

```json
{
  "stage": "dev",
  "accountId": "0123456789abcdef0123456789abcdef",
  "profile": "trigo-cloud-dev",
  "apiUrl": "https://trigo-dev-api.example.workers.dev"
}
```

The example values above are shapes, not project credentials or a known deployed
URL. `config/cloud/*.json` is ignored; only `*.example.json` is tracked. The wrapper
rejects unknown fields, a stage/profile mismatch, a malformed account ID and a
non-origin or non-HTTPS `apiUrl` before Alchemy constructs the remote-state layer.
For bootstrap/deploy it also reads only the selected profile's method and account
metadata: OAuth and stored profiles must belong to the configured account, while an
`env` profile is bound to the wrapper's explicit account environment. Credential
values are never printed by this validation.

The personal template proves the separate mapping but remains set to
`personalDeploymentGate: blocked-by-32`. The first personal deployment is rejected
until issue #32 is accepted and the owner intentionally changes that field to
`approved-after-32`. Remote fixture operations always reject `personal`.

## Authentication and first bootstrap

Configure and authenticate the dedicated profile from the stage file before using
the wrapper:

```sh
mise exec -- bun --bun infra/node_modules/alchemy/bin/alchemy.js login \
  --configure --profile trigo-cloud-dev
```

This profile setup is mandatory on every machine, including when the profile uses
environment credentials: a `CLOUDFLARE_API_TOKEN` by itself does not replace the
profile registry entry that binds the stage to its account. For an `env` profile,
provide a suitably scoped token in the process environment for each command.
The login command deliberately uses `--configure`: pinned Alchemy otherwise
reuses an existing provider entry. Confirm that its printed Cloudflare account is
the intended dev account before bootstrapping or deploying.
Never paste the token into the stage file, a command argument, a log or Git. Create
a custom token restricted to the intended dev account under **Account Resources**
with exactly these account permissions:

- [`Workers Scripts Write`](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/content/methods/update/)
  for the state/application Workers and the
  [Workflow definition](https://developers.cloudflare.com/api/resources/workflows/methods/update/)
- [`Workers R2 Storage Write`](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/methods/create/)
  for the retained bucket and acceptance object
- [`D1 Write`](https://developers.cloudflare.com/api/resources/d1/subresources/database/methods/create/)
  for the retained database and acceptance row
- [`Account Secrets Store Edit`](https://developers.cloudflare.com/secrets-store/access-control/)
  for state-store secrets and their Worker binding

No zone permission is required because this stage uses `workers.dev` and no custom
domain. The Workers AI binding is part of the Worker upload and #29 never invokes
inference, so this acceptance path does not require a Workers AI token permission.
Load the token into the environment from an interactive hidden prompt or the
operator's secret manager; the commands below assume it is already present and do
not show a token assignment that could be retained in shell history.

Before requesting cloud authorization, validate the local inputs without creating
or changing a Cloudflare resource:

```sh
mise exec -- bun run cloud:preflight --stage dev

TRIGO_DEV_ACCOUNT_ID="$(jq -r '.accountId' config/cloud/dev.json)"
mise exec -- node node_modules/wrangler/bin/wrangler.js whoami \
  --account "$TRIGO_DEV_ACCOUNT_ID" --json |
  jq -e --arg id "$TRIGO_DEV_ACCOUNT_ID" \
    '.loggedIn == true and any(.accounts[]?; .id == $id)' >/dev/null
```

The project preflight validates the whole stage configuration and reads the pinned
Alchemy profile registry directly, including its Cloudflare provider and account
mapping. Do not substitute Alchemy's `profile show` command as a pass/fail gate:
this pinned release exits zero after printing a not-found message for an absent
profile. The Wrangler command is a read-only authentication/account check. It
cannot prove the token's write permissions; compare those permissions in the
Cloudflare token dashboard with the list above before bootstrap.

With explicit authorization, bootstrap remote state once for the account:

```sh
mise exec -- bun run cloud:bootstrap --stage dev
```

Alchemy deploys or adopts the account-wide `alchemy-state-store` Worker. Its bearer
token and encryption key are managed in the account Secrets Store. The local cache
at `~/.alchemy/credentials/trigo-cloud-dev/cloudflare-state-store.json` contains
the endpoint and bearer token and is sensitive. Do not copy it into the repository
or share it as acceptance evidence.

Because the state backend is account-wide, coordinate exactly one bootstrap or
state-maintenance writer for the Cloudflare account at a time. For each stack/stage,
coordinate exactly one deployment writer at a time. Dev and personal have separate
resource/state identities, but they do not have separate state-store Workers.

## Deploy and verify dev

Record the exact selected versions before live acceptance without including any
environment values:

```sh
mise exec -- bun --version
mise exec -- node --version
mise exec -- bun --bun infra/node_modules/alchemy/bin/alchemy.js --version
mise exec -- node node_modules/wrangler/bin/wrangler.js --version
```

Deploy only after bootstrap has completed:

```sh
mise exec -- bun run cloud:deploy --stage dev
```

Copy the returned `apiUrl` HTTPS origin into `config/cloud/dev.json`. Then inspect
the live deployment without mutating application data:

```sh
mise exec -- bun run test:cloud --stage dev
```

The verifier uses the pinned Wrangler boundary and therefore requires
`CLOUDFLARE_API_TOKEN` even if Alchemy login credentials already exist. It confirms
the Worker deployment, disabled R2 development URL, absence of R2 custom domains,
and the diagnostic report for R2, D1, Workflow and AI bindings. The report includes
a non-secret SHA-256-derived identity tied to both the configured account and the
stable Worker name, so a stale URL from another account/Worker cannot satisfy the
acceptance check. The verifier never invokes Workers AI.

Use one UUIDv4 to prove retained R2 and D1 data across repeated deployment:

```sh
FIXTURE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
mise exec -- bun run test:cloud --stage dev --seed "$FIXTURE_ID"
mise exec -- bun run cloud:deploy --stage dev
mise exec -- bun run test:cloud --stage dev --verify "$FIXTURE_ID"
```

`--seed` writes only `acceptance/issue-29/<uuid>.json` in dev R2 and the same UUID
to the `trigo_infrastructure_fixture` dev D1 table. `--verify` reads those exact
fixtures and performs no writes. Keep the UUID in the acceptance record; never
record the token. Repeat the final `--verify` from a fresh checkout after following
the access procedure below.

## Fresh checkout and credential recovery

A fresh checkout or machine does not need copied `.alchemy` stack data or a copied
state credential cache:

1. Install the pinned toolchain and dependencies.
2. Recreate `config/cloud/dev.json` from the tracked example with the same account
   ID, profile and deployed `apiUrl`.
3. Configure and authenticate the `trigo-cloud-dev` profile. If it uses
   environment credentials, also provide its authorized API token; the token alone
   is insufficient.
4. With explicit cloud authorization, rerun
   `bun run cloud:bootstrap --stage dev`. Alchemy adopts the existing account-wide
   state Worker and re-derives the local state-store credential.
5. Repeat `bun run cloud:deploy --stage dev` from that fresh checkout, using the
   same stack/stage and stable resource identities.
6. Run the fixture `--verify` command with the previously recorded UUID.

Re-derivation may create an ephemeral Worker preview to read the Secrets Store
binding. The operator therefore needs Worker and Secrets Store access. This is why
`doctor`, `check`, `dev` and ordinary builds never attempt recovery or initialize
cloud state.

If only
`~/.alchemy/credentials/trigo-cloud-dev/cloudflare-state-store.json` is lost, use
the same steps: authenticate and explicitly rerun bootstrap. Do not create a new
stack or state Worker. If bootstrap is interrupted, wait until no other writer is
active and safely replay the same command. The pinned implementation resumes a
local partial bootstrap when present, otherwise it adopts the serving account-wide
Worker and refreshes the cache.

| Condition                                     | Operator action                                                            |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| Fresh checkout or lost local state cache      | Configure the profile, replay dev bootstrap, deploy, then verify the UUID  |
| Interrupted bootstrap                         | Confirm no concurrent writer, replay the identical bootstrap command       |
| Deployment interrupted                        | Confirm no concurrent writer, repeat the same stage deployment             |
| Complete remote state or encryption-key loss  | Stop; follow issue #32 research and recovery acceptance                    |
| Unexpected replacement or missing retained DB | Stop; preserve evidence and do not create resources under improvised names |

Alchemy 2.0.0-beta.76 has no supported remote-state import command. Complete loss
of the remote state Worker, its data or its encryption key is not equivalent to a
fresh checkout and is not solved by this runbook. Do not improvise an Alchemy v1
password recipe, deploy personal, or replace stable resources; issue #32 owns that
recovery gate.

## Disposable interrupted-bootstrap rehearsal

This issue #29 acceptance experiment is destructive and account-scoped. It must
run only in a newly created free Cloudflare account named
`Trigo Recovery Disposable`, account `3fd3cd769d5d372e6757d0ec208a74f2`;
it must never run in the working dev account
`27940cd0d92bb3f03943a5378ccf68d3`, a personal account or a shared account. The
owner has approved that boundary and the account exists with free-tier defaults,
but execution remains blocked until a dedicated account-restricted token and
sole-writer control are handed to the operator. Stop before accepting a paid plan,
adding a payment method or incurring any charge.

The project bootstrap wrapper intentionally remains limited to `dev` and
`personal`, rejects forwarded flags and does not expose state-store teardown or a
worker-name override. This rehearsal invokes only the pinned Alchemy CLI from a
throwaway clone. Pinned Alchemy fixes its profile registry and credential caches at
`~/.alchemy`; it does not provide an alternate config root. Isolation therefore
uses all three supported namespaces without changing `HOME` or `CODEX_HOME`:

- a one-use `trigo-cloud-issue-29-interrupt-<suffix>` environment profile;
- the ignored `config/cloud/issue-29-interrupt.json` account declaration; and
- the clone-local `.alchemy/state/CloudflareStateStore/<profile>_alchemy-state-store`
  stage in a new temporary clone.

The deterministic interruption is a marker-owned directory at
`~/.alchemy/credentials/<profile>/cloudflare-state-store.json`. In beta.76,
`deploy()` settles each resource and writes `__stack_output__.json` before
returning. Only then does bootstrap write this credential cache; version waiting,
login, state hoist and local-stack deletion all happen later. A directory at the
file path makes that write fail consistently at the completed local stack output
checkpoint. This is not a timed signal, a patched dependency or a remote failure.
Removing only the marked directory and replaying the identical command exercises
the native `Resuming Cloudflare State Store ...` branch.

### Action-time prerequisites

Confirm and retain non-secret evidence for every item before arming the seam:

1. The current checkout is the reviewed issue #29 PR head with Bun 1.3.13,
   Alchemy 2.0.0-beta.76 and Wrangler 4.124.0 installed from the lockfile.
2. The selected account is exactly `Trigo Recovery Disposable`, ID
   `3fd3cd769d5d372e6757d0ec208a74f2`. It differs from the protected dev ID above,
   and its inventory is empty: no Workers, Secrets Store, R2 buckets, D1 databases
   or Workflows. A brand-new account can return HTTP 404 from the read-only
   `/workers/subdomain` endpoint until its first Worker exists. Record that result;
   it is the expected unresolved baseline, not permission to infer a subdomain.
3. The dedicated token is restricted under Account Resources to that disposable
   account only. It has Workers Scripts Write and Account Secrets Store Edit, no
   zone permissions and no access to the protected dev account. The token is
   loaded only from a hidden prompt or secret manager into the command environment.
4. No other operator or automation can write to the disposable account during the
   rehearsal. The cost ledger is EUR 0 actual/EUR 0 reserved and the account is on
   the free plan. Any upgrade, payment or charge prompt is a hard stop.
5. The one-use profile, its credential directory and the clone-local bootstrap
   stage do not exist. Record a SHA-256 digest (or `absent`) for the protected dev
   state credential before the experiment; never copy or print that credential.
   Set `umask 077` before creating the clone, profile, logs or state artifacts.
6. The approval covers exactly one induced bootstrap failure, one identical replay,
   deletion of the named disposable resources and deletion of the disposable
   account. It does not authorize dev/personal mutation or application deployment.

Use a new clone under a mode-`0700` temporary root and copy the tracked declaration
to its ignored path. Replace only the random profile suffix before the first run.
Keep `stateStoreOrigin` at its exact `pending-first-worker` sentinel until the first
Worker makes the account subdomain observable. The probe pins both account IDs and
the purpose. Do not put a token in this file:

```sh
umask 077
TRIGO_RECOVERY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/trigo-issue-29.XXXXXX")"
chmod 700 "$TRIGO_RECOVERY_ROOT"
TRIGO_SOURCE_REPOSITORY="$(git rev-parse --show-toplevel)"
TRIGO_REVIEWED_COMMIT="$(git rev-parse HEAD)"

git clone --no-local "$TRIGO_SOURCE_REPOSITORY" "$TRIGO_RECOVERY_ROOT/trigo"
cd "$TRIGO_RECOVERY_ROOT/trigo"
git checkout --detach "$TRIGO_REVIEWED_COMMIT"
mise trust
mise install
mise exec -- bun install --frozen-lockfile

cp config/cloud/issue-29-interrupt.example.json \
  config/cloud/issue-29-interrupt.json
```

Configure exactly that profile with Cloudflare method `env`, then export the same
profile and disposable account ID for the rehearsal process. The source-only probe
performs no network requests: it validates the closed schema, pinned disposable
account, protected-account separation, exact environment identity, restrictive
process umask, the single-provider `env` profile and the absence of both local
experiment artifacts. `preflight` and `arm` accept the exact pending sentinel;
checkpoint assertion, disarm and recovery assertion require it to have been
replaced by the read-only verified Worker origin.

```sh
TRIGO_RECOVERY_CONFIG=config/cloud/issue-29-interrupt.json
TRIGO_RECOVERY_PROFILE="$(jq -r '.profile' "$TRIGO_RECOVERY_CONFIG")"
export CLOUDFLARE_ACCOUNT_ID="$(jq -r '.accountId' "$TRIGO_RECOVERY_CONFIG")"
export ALCHEMY_PROFILE="$TRIGO_RECOVERY_PROFILE"

mise exec -- bun --bun infra/node_modules/alchemy/bin/alchemy.js login \
  --configure --profile "$TRIGO_RECOVERY_PROFILE"

mise exec -- bun scripts/cloud-bootstrap-interruption.ts preflight \
  --config "$TRIGO_RECOVERY_CONFIG"
```

Separately run the pinned Wrangler `whoami --account <disposable-id> --json` check
and inspect the account inventory read-only. Stop unless the token sees the exact
disposable ID, cannot see the protected dev account and every inventory listed in
prerequisite 2 is empty. The local probe cannot establish token scope or remote
emptiness and must not be treated as that evidence.

### Induce, observe and replay

Arm the local collision and run bootstrap once. Capture its status and log without
printing environment values:

```sh
mise exec -- bun scripts/cloud-bootstrap-interruption.ts arm \
  --config "$TRIGO_RECOVERY_CONFIG"

set +e
mise exec -- bun --bun infra/node_modules/alchemy/bin/alchemy.js \
  cloudflare bootstrap --profile "$TRIGO_RECOVERY_PROFILE" \
  >bootstrap-interrupted.log 2>&1
TRIGO_INTERRUPTED_STATUS=$?
set -e
test "$TRIGO_INTERRUPTED_STATUS" -ne 0

TRIGO_SUBDOMAIN_RESPONSE="$TRIGO_RECOVERY_ROOT/workers-subdomain.json"
printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" | \
  curl --fail-with-body --silent --show-error --header @- \
    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/subdomain" \
    >"$TRIGO_SUBDOMAIN_RESPONSE"
TRIGO_WORKERS_SUBDOMAIN="$(jq -er \
  'select(.success == true) | .result.subdomain | select(type == "string" and length > 0)' \
  "$TRIGO_SUBDOMAIN_RESPONSE")"
TRIGO_STATE_STORE_ORIGIN="https://alchemy-state-store.$TRIGO_WORKERS_SUBDOMAIN.workers.dev"
TRIGO_RECOVERY_CONFIG_NEXT="${TRIGO_RECOVERY_CONFIG}.next"
jq --arg origin "$TRIGO_STATE_STORE_ORIGIN" \
  '.stateStoreOrigin = $origin' "$TRIGO_RECOVERY_CONFIG" \
  >"$TRIGO_RECOVERY_CONFIG_NEXT"
chmod 600 "$TRIGO_RECOVERY_CONFIG_NEXT"
mv "$TRIGO_RECOVERY_CONFIG_NEXT" "$TRIGO_RECOVERY_CONFIG"

mise exec -- bun scripts/cloud-bootstrap-interruption.ts assert-interrupted \
  --config "$TRIGO_RECOVERY_CONFIG"
```

The failed run is valid only when the error is the expected attempt to write the
directory-backed credential path. After that failure, the formerly unavailable
read-only subdomain lookup must succeed and the resulting exact state-store origin
must replace the sentinel before `assert-interrupted` runs. Stop if the lookup still
fails, returns an invalid subdomain, or the assertion rejects the origin; never
guess or derive it from another account. The probe parses but never prints the
secret-bearing state. It requires mode-private local state, a stack output
containing the verified origin and a non-empty bearer token, all resource rows in
settled `created`/`updated` states, and these pinned logical IDs:
`StateStoreSecrets`, `StateStoreAuthTokenValue`, `AlchemyStateStoreToken`,
`StateStoreEncryptionKeyValue`, `StateStoreEncryptionKey` and `Api`. Record its
sanitized JSON summary plus the remote Worker/store/secret IDs. The remote account
must now contain only `alchemy-state-store`, one Secrets Store and exactly the
`AlchemyStateStoreToken` and `AlchemyStateStoreEncryptionKey` secrets; R2, D1 and
Workflows remain empty.

Disarm only after that checkpoint passes. The command repeats the full local
checkpoint assertion and refuses to remove anything unless the exact stack output,
resource state and collision directory with its sole `ARMED` marker still match.
Then replay the same pinned bootstrap command without adding `--force` or
`--worker-name`:

```sh
mise exec -- bun scripts/cloud-bootstrap-interruption.ts disarm \
  --config "$TRIGO_RECOVERY_CONFIG"

mise exec -- bun --bun infra/node_modules/alchemy/bin/alchemy.js \
  cloudflare bootstrap --profile "$TRIGO_RECOVERY_PROFILE" \
  >bootstrap-replayed.log 2>&1

mise exec -- bun scripts/cloud-bootstrap-interruption.ts assert-recovered \
  --config "$TRIGO_RECOVERY_CONFIG"
```

Replay acceptance requires all of the following:

- the log contains `Resuming Cloudflare State Store 'alchemy-state-store'
deployment...` followed by the ready message;
- the same Worker, Secrets Store and two secret IDs are adopted in place, with no
  duplicate or replacement and no additional account resource;
- the state-store `/version` endpoint reports contract version 7;
- the local experiment stage is gone only after replay succeeds; and
- the regenerated credential cache is a regular file bound to the disposable
  account and exact post-first-Worker verified state-store origin, with no group/other
  access. The probe reports these last two facts without returning its bearer token.

### Cleanup and retained evidence

Cleanup remains part of the approved destructive boundary, but perform it only
after the recovery assertions and an exact inventory review. Preserve sanitized
evidence first; never preserve the local state files, stack output, credential
cache, full environment or unreviewed logs because they contain or may contain
state secrets.

1. Confirm the selected account is still the disposable ID and the inventory still
   contains only the one Worker, one store and two named secrets recorded above.
2. Delete the `alchemy-state-store` Worker, then delete only the two recorded
   state-store secrets. Delete the Secrets Store only after a read proves it is
   empty. Stop instead of deleting if any foreign resource or secret appears.
3. Re-run the read-only account inventories and retain their zero-resource result.
4. Clear only the one-use Alchemy profile and its credential cache, remove the
   throwaway clone, and prove the protected dev credential digest is unchanged.
5. Have the owner delete `Trigo Recovery Disposable` in Cloudflare and retain the
   account-deletion confirmation. Finish with EUR 0 actual/EUR 0 reserved.

Retain the reviewed commit SHA and tool versions, the owner's exact boundary
approval, disposable account name/ID, a token-scope screenshot with no token,
before/interrupted/replayed/cleaned inventory IDs, the induced exit status and
error class, sanitized probe summaries, the two expected replay log lines,
`/version` result, unchanged protected-dev credential digest, zero-cost ledger and
account-deletion confirmation.

Stop immediately and preserve evidence on any ID/profile mismatch, a token that
can see the protected account, non-empty baseline inventory, pre-existing local
artifact, unexpected first-run success/error, incomplete local checkpoint, replay
without the `Resuming` branch, planned deletion/replacement, changed remote IDs,
foreign cleanup target, changed dev credential digest, provider/billing prompt or
non-zero cost. Do not recover by using `--force`, changing the worker name,
deleting uncertain resources or switching to the dev profile.
