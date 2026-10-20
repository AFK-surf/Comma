# Salix dashboard end-to-end tests (Playwright)

Browser end-to-end tests of the Salix admin dashboard. They drive the real
LiveView UI on `:4000/dash`.

## How auth works here

The Salix dashboard authenticates with the **system-wide admin token**
(`:salix_web, :api_token`, loaded from `config.json`). The suite pastes that token
into the real `/dash/login` form. There is no dev-login bypass and no seeded user.
Playwright reads the token from `SALIX_API_TOKEN` (default `e2e-admin-token`).

Salix needs MinIO and Postgres (`SalixStore.Repo`, dev DB `salix_dev`). See
[`docs/storage-search.md`](../../../../docs/storage-search.md).

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

# Postgres for SalixStore.Repo (salix_dev)
docker run -d --name salix-e2e-pg -p 5432:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres postgres:16-alpine
MIX_ENV=dev mix ecto.create -r SalixStore.Repo
MIX_ENV=dev mix ecto.migrate -r SalixStore.Repo
# Seed the cutover markers on the empty control store. The serve gate and
# /ready stay closed until all markers exist. The request path never writes them.
# This matches the seed step of the dashboard-e2e CI job.
MIX_ENV=dev mix run --no-start \
  -e '{:ok, _} = Application.ensure_all_started(:salix_store); :ok = SalixStore.TenantApiKeyCutover.run(); :ok = SalixStore.ProviderCredentialsCutover.run(); :ok = SalixStore.TenantConfigsCutover.run(); :ok = SalixStore.SchedulesCutover.run(); :ok = SalixStore.OAuthAppsCutover.run(); :ok = SalixStore.AgentConfigurationRollout.open(); :ok = SalixStore.AgentConfigurationRollout.complete(); {:ok, %{next_cursor: nil}} = SalixStore.ComputeMigration.transfer_page()'

# Boot just Salix on :4000 with a known admin token
COMMA_SUBSYSTEMS=salix MIX_ENV=dev mix run --no-halt &     # serves :4000/dash

# Run the suite
cd apps/salix_web/e2e
npm install
npx playwright install chromium
SALIX_API_TOKEN=e2e-admin-token npx playwright test   # E2E_BASE_URL defaults to http://127.0.0.1:4000
```

CI runs this in the `dashboard-e2e` job of `.github/workflows/systems-ci.yml`.
