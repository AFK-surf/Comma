# Dashboard end-to-end tests (Playwright)

Browser end-to-end tests of the BridgeForTeams dashboard. They drive the real
dashboard (the React app served by Phoenix) on port 4101.

## How auth works here

The suite uses a **guarded dev-login route**, `GET /dev/login?email=...`, which
mints a real `BridgeForTeams.Auth.Sessions` session. The route returns 404 unless
`:dev_login` is set. `config/runtime.exs` sets it only for non-prod when
`config.json` has `bridge_for_teams.dashboard.dev_login=true`. It is **never**
active in prod.

This "e2e mode" also injects OIDC and Feishu SSO provider fakes, so tests run
without a live IdP.

**Salix stays real.** The same `mix run` boots `salix_web`, so this run needs
Postgres **and** MinIO.

## Run locally

From the umbrella root (`systems/`), with Postgres reachable at
`127.0.0.1:5432` (user/pass `postgres`) and MinIO at `:19000`:

```sh
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
  },
  bridge_for_teams: {
    database: {
      url: "ecto://postgres:postgres@127.0.0.1:5432/bridge_for_teams_e2e"
    },
    web: {
      public_base_url: "http://127.0.0.1:4101"
    },
    dashboard: {
      server: true,
      dev_login: true,
      secret_key_base: "dev_only_secret_key_base_change_me_333333333333333333333333333333333333"
    }
  }
}' > config.json

MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
MIX_ENV=dev mix ecto.create -r BillingCore.Repo -r Comma.Repo -r SalixStore.Repo
MIX_ENV=dev mix ecto.migrate -r BillingCore.Repo -r Comma.Repo -r SalixStore.Repo
# Seed the Salix cutover markers as in ../../salix_web/e2e/README.md.
mix assets.setup && mix assets.build
MIX_ENV=dev mix run apps/bridge_for_teams_web/e2e/seed.exs   # seeds e2e user+org+signup invite codes
MIX_ENV=dev mix run --no-halt &                       # serves :4101
# Set E2E_INVITE_PREFIX to override the default bft_e2e_0..4 signup codes.

cd apps/bridge_for_teams_web/e2e
npm install
npx playwright install chromium
npx playwright test            # E2E_BASE_URL defaults to http://127.0.0.1:4101
```

CI runs the same flow in the `dashboard-e2e` job of
`.github/workflows/systems-ci.yml`.

## Meeting preparation preview

This runs the production Dashboard with local provider fixtures and labeled sample meetings:

```sh
MIX_ENV=test MEETING_PREVIEW_DB_PORT=<local-postgres-port> \
  mix run --no-start apps/bridge_for_teams_web/e2e/meeting_preparation_preview.exs
```

Run this command from `systems/` after you build the Dashboard assets and the React
dashboard (`pnpm --dir clients --filter @comma/bft build`). It creates dedicated
`*_meeting_preview` databases on loopback and serves port 4411. Open the printed
login URL. The preview creates no schedules, model runs, or provider messages.
Set `MEETING_PREVIEW_LOCALE=en` to run the history browser test:

```sh
MEETING_PREVIEW_URL="<printed login URL>" npx playwright test tests/meeting-history-preview.spec.ts
```

Run the browser command from this `e2e/` directory. Stop the process to stop the preview.
