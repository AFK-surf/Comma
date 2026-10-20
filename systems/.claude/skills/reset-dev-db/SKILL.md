---
name: reset-dev-db
description: Reset explicitly selected local development databases and the Salix bucket when the user requests a destructive reset, preserving platform defaults. Not a startup, upgrade, or migration repair procedure.
---

# Reset dev database (preserving platform defaults)

Use only for an explicitly requested reset of the resolved local targets.
Startup failure, an old version, or a pending handoff does not authorize a wipe.
For ordinary initialization, follow `docs/development.md` from the repository
root and the selected stack's current bootstrap. Never seed admission markers
manually to bypass a failed migration. Never apply this procedure to staging or production.

This wipes the BridgeForTeams, BillingCore, and SalixStore Postgres repos and the
`salix-dev` MinIO bucket, then re-creates tenants. **Platform defaults** are
deployment config, not tenant data. Back them up before the wipe and restore them
after, so global OAuth fallback, the Composio fallback API key, and cloud-VM
provisioning keep working. Back them up from their **authoritative store**.
OAuth apps and Composio settings are in Postgres. Do not back them up from S3,
because the S3 copies can hold an old secret. The cloud-VM config
(`ctl/vm/default_config.json`) is in S3.

Prerequisites (the standard dev stack): MinIO on `127.0.0.1:19000`
(podman container, creds `minioadmin`/`minioadmin`), Postgres per
`config/config.exs` plus `config/runtime.exs`, and the dev node named `comma` with cookie `comma-dev-cookie`.
This recipe targets the native dev stack with host-network Podman. It does not
reset the Dev Container or an isolated `make salix-dev-up` stack. Resolve that
stack's actual targets before you adapt this procedure. Do not use a volume-wide
reset when platform defaults must survive.

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

What is **lost**: all orgs, users, swarms, conversations, tenant OAuth
_connections_ (users must redo the Google consent flow), and agent state.
What is **kept**: platform OAuth defaults, the platform Composio default,
platform VM defaults, and (through re-creation) the tenant roster in `resetup.exs`.

## 1. Back up platform defaults

```bash
umask 077
export BK=$(mktemp -d)
# OAuth apps and Composio settings: export the deployment defaults from Postgres.
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
# Cloud-VM config is in S3.
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

The Salix control repo (`salix_dev`) holds the control datasets (tenant API
keys, provider credentials, tenant configs, schedules, OAuth apps) and their
cutover markers. Step 4 runs the owning cutover routines. Do not write markers
directly. Do not use an empty-store procedure against retained data.

## 4. Wipe the bucket, restore platform defaults

Destructive. This empties the whole `salix-dev` bucket:

```bash
podman run --rm --network host -v $BK:/bk:ro,Z --entrypoint /bin/sh docker.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 -c '
mc alias set local http://127.0.0.1:19000 minioadmin minioadmin >/dev/null || exit 1
mc rm --recursive --force local/salix-dev/ || exit 1
echo "bucket wiped"
[ -f /bk/default_config.json ] && mc cp /bk/default_config.json local/salix-dev/ctl/vm/default_config.json
mc ls --recursive local/salix-dev/'
```

The final listing must show only the restored `ctl/vm/default_config.json`.
The OAuth and Composio defaults go back into Postgres below.

Run the cutover owners for the empty store. They write their own completion
markers. The list matches `run_salix_cutover_for_dev_compose/0` in
`apps/comma/lib/comma/release.ex`. Check it before you adapt the list to a
different stack:

```bash
mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:salix_store); :ok = SalixStore.TenantApiKeyCutover.run(); :ok = SalixStore.ProviderCredentialsCutover.run(); :ok = SalixStore.TenantConfigsCutover.run(); :ok = SalixStore.SchedulesCutover.run(); :ok = SalixStore.OAuthAppsCutover.run()'
```

Restore the deployment OAuth and Composio defaults into Postgres:

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

Run the long-running dev server in the background:

```bash
elixir --sname comma --cookie comma-dev-cookie -S mix run --no-halt
```

Wait until `curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/dash/login`
returns `200`. Poll one endpoint every 3 seconds for at most 2 minutes.
If startup fails, inspect the server log and report the error before proceeding.

## 6. Recreate the dev tenants

The script runs over erpc against the live node. It defines the tenant roster,
platform model, and billing grants. Filter the verbose output for status lines:

```bash
elixir --sname resetup_$RANDOM --cookie comma-dev-cookie .claude/skills/reset-dev-db/resetup.exs 2>&1 |
  grep -E '^(platform model|package version|org |swarm |router |fee-control |re-setup)'
```

Expect: the platform model tiers (or a kept configuration), 2 package versions,
3 orgs, credit + unlimited grants, 3 swarms, all 3 routers provisioned
(`router <slug>: agent_...`), and `fee-control <slug>: allowed=true` for each.

## 7. Verify platform defaults survived

Use `web.api_token` from the effective `SalixStore.ConfigJson` path.
The commands below assume that path is `systems/config.json` (gitignored):

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('config.json'))['web']['api_token'])")
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4000/v1/admin/oauth/default-apps
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4000/v1/admin/composio/default-settings
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4000/v1/admin/vm/default-config
```

The google entry must show `client_secret_configured: true`. The VM config must
show `token_configured: true`. If a platform Composio key existed before the
reset, the Composio default must show `api_key_configured: true`. Then clean up
with `rm -rf $BK`.
