# Salix dashboard end-to-end tests (Playwright)

Browser end-to-end coverage of the Salix admin dashboard, driven through the real
LiveView UI served on `:4000/dash` (the same Bandit listener as the JSON API):

- admin-token login (and rejection of a bad token) + the app shell,
- cluster overview,
- create a tenant + mint an API key,
- create an agent template,
- create an agent group,
- create an agent (selecting the group + template),
- create a group conversation and send a message (exercises the LiveView
  websocket round-trip),
- OAuth provider apps + IM config,
- logout.

## How auth works here

Unlike BridgeForTeams (OIDC), the Salix dashboard authenticates with the
**system-wide admin token** (`:salix_web, :api_token`, loaded from
`config.json`). The suite logs in by pasting that token into the real
`/dash/login` form — no dev-login bypass and no seeded user. The Playwright
process uses `SALIX_API_TOKEN` only as its input value, defaulting to
`e2e-admin-token`.

Salix keeps most control state in an S3 control store (MinIO in dev/CI), but
tenant API keys now live in Postgres (`SalixStore.Repo`, dev DB `salix_dev`;
see docs/storage-search.md). The "create an API key" flow
therefore needs Postgres reachable, the repo migrated, and the cutover marker
seeded — the DB prep below covers all three.

## Run locally

From the umbrella root (`systems/`), with MinIO reachable at `:19000`:

```sh
# MinIO + bucket (once)
docker run -d --name minio -p 19000:9000 \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e server /data
aws --endpoint-url http://127.0.0.1:19000 s3 mb s3://salix-dev || true

# Runtime config for the server
jq -n '{
  storage: {
    endpoint: "http://127.0.0.1:19000",
    region: "us-east-1",
    bucket: "salix-dev",
    access_key_id: "minioadmin",
    secret_access_key: "minioadmin",
    conditional_delete: "emulate"
  },
  web: {
    api_token: "e2e-admin-token",
    api_base_url: "http://127.0.0.1:4000",
    sites_domain: "salix.localhost"
  },
  salix_dashboard: {
    secret_key_base: "dev_only_secret_key_base_change_me_222222222222222222222222222222222222"
  }
}' > config.json

# Postgres for the tenant-api-key repo (SalixStore.Repo -> salix_dev)
docker run -d --name salix-e2e-pg -p 5432:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres postgres:16-alpine
MIX_ENV=dev mix ecto.create -r SalixStore.Repo
MIX_ENV=dev mix ecto.migrate -r SalixStore.Repo
# Seed the cutover markers on the empty control store so the PG-only serve gate
# opens (the request path never mints them). Salix readiness requires both the
# tenant-api-key and provider-credentials markers.
MIX_ENV=dev mix run --no-start \
  -e '{:ok, _} = Application.ensure_all_started(:salix_store); :ok = SalixStore.TenantApiKeyCutover.run(); :ok = SalixStore.ProviderCredentialsCutover.run()'

# Boot just Salix on :4000 with a known admin token
COMMA_SUBSYSTEMS=salix MIX_ENV=dev mix run --no-halt &     # serves :4000/dash

# Run the suite
cd apps/salix_web/e2e
npm install
npx playwright install chromium
SALIX_API_TOKEN=e2e-admin-token npx playwright test   # E2E_BASE_URL defaults to http://127.0.0.1:4000
```

CI runs this in the `dashboard-e2e` job of `.github/workflows/systems-ci.yml`
(same job that runs the BridgeForTeams e2e — one `mix run --no-halt` serves both
dashboards), against `http://127.0.0.1:4000`.
