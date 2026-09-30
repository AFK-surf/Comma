---
name: reset-dev-db
description: Reset explicitly selected local development databases and the Salix bucket when the user requests a destructive reset, preserving platform defaults. Not a startup, upgrade, or migration repair procedure.
---

# Reset dev database (preserving platform defaults)

Use only for an explicitly requested reset of the resolved local targets.
Startup failure, an old version, or a pending handoff does not authorize a wipe.
For ordinary initialization, follow `docs/development.md` from the repository
root and the selected stack's current bootstrap. Never seed admission markers
manually to bypass a failed migration or apply this procedure to staging/production.

Full wipe of the BridgeForTeams, BillingCore, and SalixStore Postgres repos and the `salix-dev` MinIO bucket, followed by
tenant re-creation. **Platform defaults** are deployment config, not tenant
data — they are backed up before the wipe and restored after, so global OAuth
fallback, the Composio fallback API key, and cloud-VM provisioning keep working
on the fresh tenants. Back them up from their **authoritative store**: OAuth
apps and Composio settings are now in Postgres (a PG-only rotation leaves the
old S3 object stale, so backing up S3 would lose the current secret); cloud-VM
config (`ctl/vm/default_config.json`) still lives in S3.

Prerequisites (the standard dev stack): MinIO on `127.0.0.1:19000`
(podman container, creds `minioadmin`/`minioadmin`), Postgres per
`config/config.exs` plus `config/runtime.exs`, and the dev node named `comma` with cookie `comma-dev-cookie`.
This recipe targets the native dev stack with host-network Podman. It does not
reset the Dev Container or an isolated `make salix-dev-up` stack. Resolve that
stack's actual targets before adapting this procedure; do not substitute a
volume-wide reset when platform defaults must survive.

Run the following steps from `systems/`:

```sh
cd systems
export MIX_ENV=dev
```

## 0. Resolve the destructive scope

Before deletion, resolve the configured host, port, database, and role for the
three named repos. Confirm them with read-only connections and bounded catalog
queries. Verify the MinIO endpoint and bucket with a bounded object listing.
Proceed only when existing authorization covers those databases and the entire
bucket. Preserve all other databases and volumes, including Comma and AlertRouter.

Tenant recreation is optional. Before using `resetup.exs`, inspect its current
roster and model configuration. It can provision real agents and incur usage.
Run it only when that recreation is part of the requested reset.

What is **lost**: all orgs/users/swarms/conversations, tenant OAuth
_connections_ (users must redo the Google consent flow), agent state.
What is **kept**: platform OAuth defaults, the platform Composio default,
platform VM defaults, and — via
re-creation — the standard tenant roster defined in `resetup.exs`.

## 1. Back up platform defaults

```bash
umask 077
export BK=$(mktemp -d)
# OAuth apps + Composio settings are authoritative in Postgres — export the
# deployment defaults from PG (the S3 copies are frozen at cutover time and miss
# any later PG-only rotation).
mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:salix_store)
  bk = System.fetch_env!("BK")
  File.write!(bk <> "/oauth_defaults.json", Jason.encode!(
    SalixStore.OAuthProviderApps.list_by_scope(SalixStore.OAuthProviderApps.default_scope())))
  composio = case SalixStore.ComposioSettings.get(SalixStore.ComposioSettings.default_scope()) do
    {:ok, rec} -> rec
    _ -> nil
  end
  File.write!(bk <> "/composio_default.json", Jason.encode!(composio))
'
# cloud-VM config still lives in S3.
podman run --rm --network host -v $BK:/bk:Z --entrypoint /bin/sh docker.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 -c '
mc alias set local http://127.0.0.1:19000 minioadmin minioadmin >/dev/null || exit 1
mc cp local/salix-dev/ctl/vm/default_config.json /bk/ >/dev/null 2>&1
ls -lR /bk'
```

Confirm the listing shows the files you expect (`oauth_defaults.json`,
`composio_default.json`, and `default_config.json`) before proceeding.

## 2. Stop the dev server

`ecto.drop` fails while the app holds connections. Stop the background dev
server through the process handle that launched it. Stop other writers to the
approved targets and confirm their connections have closed before continuing.

## 3. Drop, recreate, and migrate the three approved repos

```bash
set -e
mix ecto.drop -r BridgeForTeams.Repo && mix ecto.create -r BridgeForTeams.Repo && mix ecto.migrate -r BridgeForTeams.Repo
mix ecto.drop -r BillingCore.Repo && mix ecto.create -r BillingCore.Repo && mix ecto.migrate -r BillingCore.Repo
mix ecto.drop -r SalixStore.Repo && mix ecto.create -r SalixStore.Repo && mix ecto.migrate -r SalixStore.Repo
```

The salix control repo (`salix_dev`) holds the migrated control datasets
(tenant API keys, provider credentials, tenant configs, schedules, oauth apps)
and their
cutover markers. After the approved wipe, step 4 calls the owning cutover
routines. The request path does not create these facts. Do not write markers
directly or use an empty-store procedure against retained data.

## 4. Wipe the bucket, restore platform defaults

Destructive — this empties the whole `salix-dev` bucket:

```bash
podman run --rm --network host -v $BK:/bk:ro,Z --entrypoint /bin/sh docker.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 -c '
mc alias set local http://127.0.0.1:19000 minioadmin minioadmin >/dev/null || exit 1
mc rm --recursive --force local/salix-dev/ || exit 1
echo "bucket wiped"
[ -f /bk/default_config.json ] && mc cp /bk/default_config.json local/salix-dev/ctl/vm/default_config.json
mc ls --recursive local/salix-dev/'
```

The final listing must show exactly the restored `ctl/vm/default_config.json`
(the OAuth/Composio defaults are restored into Postgres below, not S3).

For this now-empty native development store, run its existing cutover owners.
These functions must establish their own completion facts, not accept fabricated
markers. Check the current `Comma.Release` local migration path before adapting
the list to a different stack:

```bash
mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:salix_store); :ok = SalixStore.TenantApiKeyCutover.run(); :ok = SalixStore.ProviderCredentialsCutover.run(); :ok = SalixStore.TenantConfigsCutover.run(); :ok = SalixStore.SchedulesCutover.run(); :ok = SalixStore.OAuthAppsCutover.run(); :ok = SalixAgent.InternalSessionFormat2Cutover.run()'
```

Finally, restore the deployment OAuth + Composio defaults into their
**authoritative Postgres tables** (they were exported from PG in step 1; the
markers now exist, so these are ordinary post-cutover PG writes):

```bash
mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:salix_store)
  bk = System.fetch_env!("BK")
  scope = SalixStore.OAuthProviderApps.default_scope()
  (bk <> "/oauth_defaults.json") |> File.read!() |> Jason.decode!()
  |> Enum.each(fn rec -> {:ok, _} = SalixStore.OAuthProviderApps.put(scope, rec) end)
  case (bk <> "/composio_default.json") |> File.read!() |> Jason.decode!() do
    rec when is_map(rec) -> {:ok, _} = SalixStore.ComposioSettings.put(SalixStore.ComposioSettings.default_scope(), rec)
    _ -> :ok
  end
'
```

## 5. Restart the dev server

Run in the background (this is the long-running dev server):

```bash
elixir --sname comma --cookie comma-dev-cookie -S mix run --no-halt
```

Wait until `curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/dash/login`
returns `200`. Poll one endpoint every 3 seconds for at most 2 minutes.
If startup fails, inspect the server log and report the error before proceeding.

## 6. Recreate the dev tenants

Runs over erpc against the live node; the tenant roster, templates, and billing
grants live in the script. Output is verbose (remote SQL debug logs relay to
the caller), so filter for the status lines:

```bash
elixir --sname resetup_$RANDOM --cookie comma-dev-cookie .claude/skills/reset-dev-db/resetup.exs 2>&1 |
  grep -E '^(template |package version|org |swarm |router |fee-control |re-setup)'
```

Expect: 2 templates created, 2 package versions, 3 orgs, credit + unlimited
grants, 3 swarms, all 3 routers provisioned (`router <slug>: agent_...`), and
`fee-control <slug>: allowed=true` for each. `router board-demo` having an
empty `template=` is normal (that org has no default template override).

## 7. Verify platform defaults survived

Use `web.api_token` from the effective `SalixStore.ConfigJson` path.
The commands below assume that path is `systems/config.json` (gitignored):

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('config.json'))['web']['api_token'])")
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4000/v1/admin/oauth/default-apps
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4000/v1/admin/composio/default-settings
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4000/v1/admin/vm/default-config
```

The google entry must show `client_secret_configured: true`, the VM config
`token_configured: true`, and — when a platform Composio key existed before
the reset — the composio default `api_key_configured: true`. Finally clean up: `rm -rf $BK`.
