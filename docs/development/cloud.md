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
jq -e '
  keys == ["accountId", "profile", "stage"] and
  .stage == "dev" and
  .profile == "trigo-cloud-dev" and
  (.accountId | test("^[0-9A-Fa-f]{32}$"))
' config/cloud/dev.json >/dev/null

mise exec -- bun --bun infra/node_modules/alchemy/bin/alchemy.js profile show \
  --profile trigo-cloud-dev

TRIGO_DEV_ACCOUNT_ID="$(jq -r '.accountId' config/cloud/dev.json)"
mise exec -- node node_modules/wrangler/bin/wrangler.js whoami \
  --account "$TRIGO_DEV_ACCOUNT_ID" --json |
  jq -e --arg id "$TRIGO_DEV_ACCOUNT_ID" \
    '.loggedIn == true and any(.accounts[]?; .id == $id)' >/dev/null
```

The last command is a read-only authentication/account check. It cannot prove the
token's write permissions; compare those permissions in the Cloudflare token
dashboard with the list above before bootstrap.

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
