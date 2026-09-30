# Dashboard end-to-end tests (Playwright)

Browser end-to-end coverage of the primary BridgeForTeams dashboard flows, driven
through the real LiveView UI on port 4101:

- login (via the guarded `/dev/login` bypass) and the app shell,
- create an organization,
- create a project (allocates the Salix `proj_…` tenant),
- project detail: settings + create an agent,
- task detail: add, update, filter, and delete a conversation-owned Schedule,
- project detail: create a project device request through an online runner,
- connect a per-project Slack integration,
- members list + roles,
- org settings + OIDC SSO form.

## How auth works here

The dashboard uses OIDC SSO, whose real flow redirects to an external IdP that
can't complete in a headless browser. Instead the suite uses a **guarded
dev-login route**, `GET /dev/login?email=…`, which mints a real
`BridgeForTeams.Auth.Sessions` session. It is disabled by default and returns 404
unless `:dev_login` is set — wired only for non-prod when
`bridge_for_teams.dashboard.dev_login=true` is present in `config.json` (see
`config/runtime.exs`). It is **never** active in prod.

"e2e mode" (`bridge_for_teams.dashboard.dev_login=true`) injects the OIDC and
Feishu SSO provider fakes, so browser tests can exercise callback/session
behavior without a live IdP. The Feishu SSO smoke intercepts the fake Feishu
authorization URL and redirects back to the local dashboard callback with the
returned `state`.
**Salix stays real**: the same `mix run` boots `salix_web`, so the erpc client
(`BridgeForTeams.Salix.Erpc`) discovers the local node, and runtime-touching
flows (connector tokens, agent/IM-connect reconcile) execute against the real
Salix control plane backed by MinIO. That is why this run needs Postgres **and**
MinIO.

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

Use the production LiveView with local provider fixtures and clearly labeled sample meetings:

```sh
MIX_ENV=test MEETING_PREVIEW_DB_PORT=<local-postgres-port> \
  mix run --no-start apps/bridge_for_teams_web/e2e/meeting_preparation_preview.exs
```

Run this command from `systems/` after building the Dashboard assets.
It creates dedicated `*_meeting_preview` databases on loopback and serves port 4411.
Open the printed login URL. The preview creates no schedules, model runs, or provider messages.
Its calendar accounts, channel, meeting statuses, reports, and history links are local test data.
Set `MEETING_PREVIEW_LOCALE=en` to run the history browser test:

```sh
MEETING_PREVIEW_URL="<printed login URL>" npx playwright test tests/meeting-history-preview.spec.ts
```

Run the browser command from this `e2e/` directory. Source links are fixtures and are not opened during the test.
Stop the process to stop the preview. Keep the local Postgres instance available while viewing it.
