import Config

config :alert_router,
  ecto_repos: [AlertRouter.Repo],
  start_repo: true,
  start_oban: true,
  start_http: false,
  mode: :shadow,
  delivery_lease_seconds: 3,
  max_delivery_attempts: 5,
  max_reconcile_attempts: 3,
  reconcile_delay_seconds: 1,
  history_window_seconds: 300,
  timeline_batch_size: 25

config :alert_router, AlertRouter.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: String.to_integer(System.get_env("ALERT_ROUTER_TEST_DB_PORT", "5432")),
  database: System.get_env("ALERT_ROUTER_TEST_DB", "alert_router_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 4,
  migration_source: "alert_router_schema_migrations",
  migration_primary_key: [name: :id, type: :binary_id]

config :alert_router, Oban,
  name: AlertRouter.Oban,
  repo: AlertRouter.Repo,
  peer: false,
  queues: false,
  plugins: false,
  testing: :manual,
  shutdown_grace_period: 1_000

config :alert_router, :slack,
  client: AlertRouter.Slack.ReqClient,
  base_url: "http://127.0.0.1:0/api",
  request_timeout_ms: 1_000,
  bot_token: "xoxb-alert-router-test",
  routes: %{"shadow" => "C0ALMF2AD70", "live" => "C0BJ1699HSN"}

config :alert_router,
  gcp_projects: %{staging: "example-staging-project", production: "example-prod-project"},
  gke_cluster: "example-cluster"

config :alert_router, :gcp_push,
  auth_module: AlertRouter.Web.GCPPushAuth.DenyAll,
  oidc_provider_enabled: false,
  audience: "https://alert-router.test/v1/events/gcp",
  service_account_email: "alert-router-push@test.iam.gserviceaccount.com"

config :alert_router, :grafana_webhook,
  secret: "alert-router-grafana-test-secret",
  signature_header: "x-grafana-alerting-signature",
  timestamp_header: "x-grafana-alerting-signature-timestamp",
  tolerance_seconds: 300

config :alert_router, :github_webhook,
  secret: "alert-router-github-webhook-test-secret",
  signature_header: "x-hub-signature-256",
  event_header: "x-github-event",
  delivery_header: "x-github-delivery"

config :alert_router, :posthog_webhook,
  secret: "alert-router-posthog-webhook-test-secret",
  project_id: "123",
  origin: "https://us.posthog.com",
  environment: "staging"

# BridgeForTeams tests run Salix in-process and mock Salix's S3 dependency
# directly. The live-LLM CI lane opts into MinIO before the applications start;
# ordinary tests retain the process-local fake.
live_llm_s3_backend =
  case System.get_env("SALIX_LIVE_LLM_S3_BACKEND") do
    "aws" -> SalixStore.S3.AWS
    _ -> SalixStore.S3.Fake
  end

config :salix_store,
  agent_vmm_settlement_sweep_interval_ms: 3_600_000,
  conversation_search_writer_generation: "test-search-generation",
  agent_vmm_environment_scoped_bindings_enabled: true,
  compute_workload_credential_secret: String.duplicate("test-compute-workload-secret-", 2),
  compute_runtime_base_url: "https://salix.test",
  runtime_active_revision_override: "test-runtime-revision",
  runtime_bundle_root: Path.expand("../apps/salix_store/test/fixtures/runtime-bundle", __DIR__),
  s3_bucket: "salix-test",
  s3_backend: live_llm_s3_backend,
  triage_record_backend: SalixStore.TriageRecords,
  snowflake_worker_id: 0

# Control-plane Postgres repo (docs/storage-search.md).
# Deliberately NOT the SQL sandbox: like the shared S3.Fake bucket, the salix
# control tables are node-global test state — suites isolate by unique
# generated ids, and SalixStore.RepoTestSetup truncates at suite start.
# `start_repo` is on for the same reason BridgeForTeams.Repo starts in test:
# the e2e runners boot the umbrella as a real server through `mix run`, which
# never executes an ExUnit test_helper, and tenant API keys are served from
# this repo. CI creates/migrates the database before those runners start.
config :salix_store,
  ecto_repos: [SalixStore.Repo],
  start_repo: true

config :salix_store, SalixStore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: String.to_integer(System.get_env("SALIX_TEST_DB_PORT", "5432")),
  # Overridable so parallel checkouts (worktrees / sibling clones) with
  # DIVERGED unmerged migrations can isolate their test schemas instead of
  # corrupting each other through one shared database.
  database: System.get_env("SALIX_TEST_DB", "salix_store_test"),
  pool_size: 8,
  migration_source: "salix_schema_migrations",
  migration_primary_key: [name: :id, type: :binary_id]

config :salix_web,
  port: 0,
  api_token: "test-token"

# Projection tests claim jobs explicitly; a background poller would race their
# assertions against the node-global Salix test database.
config :salix_im, :conversation_search_worker, false

config :comma_web,
  port: 0,
  api_token: "test-token",
  session_cookie: [secure: false]

config :comma_core, :auth,
  challenge_store: Comma.AuthChallengeStore.Memory,
  email_delivery: Comma.EmailDelivery.Logger,
  secret: "comma-test-auth-secret",
  rate_limit_secret: "comma-test-rate-limit-secret",
  challenge_ttl_seconds: 900,
  max_attempts: 5,
  session_ttl_seconds: 3600,
  auto_create_users: true,
  resend_cooldown_seconds: 0,
  email_request_limit: 1_000_000,
  ip_request_limit: 1_000_000,
  verification_failure_limit: 1_000_000,
  provider_failure_threshold: 1_000_000,
  expose_codes: true

# Boruta OAuth/OIDC IdP: wire the provider to Comma.Repo and the Comma adapters
# (docs/identity-security.md PR 2). The global signing key is injected
# per-suite by Comma.OauthIdpTestKeys; production wiring lands with the
# endpoints (PR 4).
# The IdP entry-point limiter shares the test Redis; endpoint tests override
# the per-endpoint budgets to drive deterministic 429s.
config :comma_core,
  oauth_idp_rate_limit_redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379/14"),
  task_share_rate_limit_redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379/14")

config :boruta, Boruta.Oauth,
  repo: Comma.Repo,
  issuer: "https://comma.test",
  contexts: [
    resource_owners: Comma.OauthIdp.ResourceOwners,
    access_tokens: Comma.OauthIdp.HashedAccessTokens,
    codes: Comma.OauthIdp.HashedCodes,
    clients: Comma.OauthIdp.Clients,
    scopes: Comma.OauthIdp.Scopes
  ]

config :comma_core, :google_auth,
  adapter: Comma.Auth.GoogleAdapter.Fake,
  issuer: "https://accounts.google.com",
  web_client_id: "comma-web-test.apps.googleusercontent.com",
  electron_client_id: "comma-electron-test.apps.googleusercontent.com",
  electron_client_secret: "comma-electron-test-client-secret",
  attempt_ttl_seconds: 300

config :comma_core,
  ecto_repos: [Comma.Repo],
  start_repo: true,
  start_oban_backlog_sampler: false,
  start_schema_readiness: false

config :comma_core, Comma.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: String.to_integer(System.get_env("COMMA_TEST_DB_PORT", "5432")),
  database: "comma_core_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 8,
  telemetry_prefix: [:comma, :repo],
  migration_primary_key: [name: :id, type: :binary_id]

config :comma_core, :chat_suggestions, false

config :comma_core, Oban,
  name: Comma.Oban,
  repo: Comma.Repo,
  peer: false,
  queues: false,
  plugins: false,
  testing: :manual,
  shutdown_grace_period: 5_000

config :billing_core,
  ecto_repos: [BillingCore.Repo]

config :billing_commerce,
  repo: BillingCore.Repo,
  cycle_scheduler_enabled: false

config :billing_stripe,
  repo: BillingCore.Repo,
  secret_key: "sk_test_comma",
  webhook_secret: "whsec_comma",
  stripe_api: BillingStripe.TestAPI

config :billing_core, :pending_charge_worker_enabled, false
config :billing_core, :llm_usage_worker_enabled, false

config :billing_core, BillingCore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: String.to_integer(System.get_env("BILLING_TEST_DB_PORT", "5432")),
  database: "billing_core_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  migration_primary_key: [name: :id, type: :binary_id]

# ====================== BridgeForTeams subsystem (test) ======================
# Live Postgres (podman) + Ecto SQL sandbox (manual mode; DataCase/ConnCase
# check out per test). The default database is pre-created; worktrees may
# override it to avoid mixing divergent migration ledgers.
config :bridge_for_teams_core, BridgeForTeams.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: String.to_integer(System.get_env("BRIDGE_TEST_DB_PORT", "5432")),
  database: System.get_env("BRIDGE_TEST_DB", "bridge_for_teams_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  migration_primary_key: [name: :id, type: :binary_id]

# Tests use the real Salix client boundary. Since test_helper starts :salix_web
# in the same BEAM, Erpc discovers Node.self() as a Salix node.
config :bridge_for_teams_core,
  salix_client: BridgeForTeams.Salix.Erpc,
  oidc_provider: BridgeForTeams.Auth.OIDC.Fake,
  feishu_provider: BridgeForTeams.Auth.Feishu.Fake,
  login_link_delivery: BridgeForTeams.LoginLinks.Delivery.Fake

# The magic-link rate limiter is a node-global ETS bucket and ConnTest shares
# one remote IP; effectively disable the ambient limits so tests that want
# them pass explicit :rate_limits.
config :bridge_for_teams_core,
  login_link_rate_limits: [ip_burst: 1_000_000, email_burst: 1_000_000],
  rate_limit_redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379/14")

config :bridge_for_teams_core,
  sourced_context_features: [
    onboarding_preview: true,
    discovery: true,
    acquisition: true,
    derivation: true,
    commit: true,
    grounding: true,
    knowledge_inspection: true
  ],
  sourced_context_encryption_key: "dGVzdF9vbmx5X3NvdXJjZWRfY29udGV4dF9rZXkhISE="

config :salix_web,
  site_rate_limit_redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379/14")

# The reconcile outbox drainer is driven deterministically by tests
# (Reconciler.drain_once/1), not the periodic GenServer loop — its background
# DB access has no sandbox connection and would just churn errors.
config :bridge_for_teams_core, BridgeForTeams.Salix.Reconciler, enabled: false
config :bridge_for_teams_core, BridgeForTeams.Salix.TenantConfigChecker, enabled: false

# Mac mini provision-request watching is also driven directly by tests. The
# background loop has no SQL sandbox connection.
config :bridge_for_teams_core, BridgeForTeams.EnvironmentProvisioning.Reconciler, enabled: false

# The artifact-document sweeper stays off under the SQL sandbox; sweeper tests
# start their own supervised instance and drive it via sweep_once/1.
config :bridge_for_teams_core, BridgeForTeams.Artifacts.Sweeper, enabled: false

# Ephemeral HTTP port for the web suite.
config :bridge_for_teams_web,
  port: 0,
  public_base_url: "http://localhost:4102",
  # The React dashboard build is not part of the Elixir suite; serve a fixture.
  spa_index_path: Path.expand("../apps/bridge_for_teams_web/test/support/spa_index.html", __DIR__)

config :salix_web, oauth_return_base_urls: ["http://localhost:4102"]

# Dashboard endpoint under test: LiveViewTest drives it in-process (server:
# false) with a fixed secret/salt.
config :bridge_for_teams_web, BridgeForTeamsWeb.DashboardEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  secret_key_base: "test_only_secret_key_base_00000000000000000000000000000000000000000000",
  live_view: [signing_salt: "comma4t-dash-test-salt"],
  server: false,
  check_origin: false

# The local Triage rehearsal is an explicitly invoked, long-running acceptance
# drive. Normal tests keep the endpoint in-process; the rehearsal opts into the
# exact same endpoint over loopback so a browser can inspect the existing BFT
# Timeline while the SQL sandbox owner remains shared with the drive.
if rehearsal_port = System.get_env("COMMA_TRIAGE_REHEARSAL_UI_PORT") do
  config :logger, level: :info

  config :bridge_for_teams_web, BridgeForTeamsWeb.DashboardEndpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(rehearsal_port)],
    server: true,
    check_origin: false

  config :bridge_for_teams_web, dev_login: true
end

config :salix_im,
  provider_runtime: false,
  slack_router_status: false,
  private_chat_status: false

# Off the default :4400 so a running dev node doesn't collide with the test
# boot. E2E tests can still choose a free port before the app starts.
config :salix_env,
  transfer_port: String.to_integer(System.get_env("SALIX_TRANSFER_PORT", "4401")),
  # Reconciler tests invoke bounded sweeps explicitly; the production ticker
  # would race their shared database fixtures.
  compute_reconciler_start_sweeper?: false

# Recovery sweep is driven deterministically by tests (Recovery.sweep_once/1),
# not the periodic GenServer.
config :salix_cluster,
  enabled: false

# Auto session titles fire a background LLM call after settles, which would
# steal scripted LLM.Mock turns in unrelated tests — titles tests enable this
# explicitly via Application.put_env.
config :salix_agent,
  session_titles: false,
  # Runtime-ownership tests deliberately crash transient FleetSup children.
  # Keep those synthetic failures from sharing the production supervisor's
  # default 3-in-5s restart-intensity circuit breaker across test cases.
  fleet_supervisor_max_restarts: 1_000_000,
  fleet_supervisor_max_seconds: 1,
  # OAuth tool tests stub the C3 store per-test; a global SalixWeb.OAuthStore
  # would read live control-plane records during unrelated scripted suites.
  oauth_store_mod: nil,
  # Composio tool tests stub the settings store per-test, same rationale.
  composio_store_mod: nil,
  # Inbound API key tools reach live control-plane records and mint
  # credentials; the suites that exercise them attach the binding themselves.
  inbound_api_key_store_mod: nil,
  # Plugin projection is part of the runtime materialization path; tests should
  # use the same control-plane binding as production and seed groups normally.
  plugin_store_mod: Salix.Bindings.AgentPluginStore,
  meeting_preparation_mod: nil,
  meeting_mod: nil,
  calendar_mod: nil,
  # Site tests opt in via Application.put_env; a default domain here would
  # inject the <agent-config> prompt block into every scripted-LLM test and
  # flip tenant site URLs to the subdomain form suite-wide.
  sites_domain: nil,
  # Production compaction summarizes through the session's own LLM; in tests
  # that would steal scripted LLM.Mock turns, so pin the deterministic
  # summarizer. LLM-compaction tests clear this via Application.put_env.
  summarizer: {SalixAgent.Compaction, :deterministic_summary},
  # Post-round trajectory eval spawns background S3 reads/writes that would
  # race scripted round tests; eval tests enable it or call the runner
  # directly.
  trajectory_eval: [enabled: false],
  trajectory_eval_recorder_mod: SalixAgent.TrajectoryEval.Recorder.Noop,
  # Per-tenant override reads a control-plane record; unset here so agent-side
  # tests get the global config. Tenant-override tests stub this per-test.
  trajectory_eval_tenant_mod: nil

config :salix_agent, session_history_enabled: false

config :salix_agent, :subscription_storage_key, String.duplicate("s", 32)

# Tests start Signal account owner processes themselves, so the ring keeper
# is off.
config :salix_signal, account_keeper: false

config :salix_agent, session_memory_budget_bytes: 8 * 1024 * 1024 * 1024

config :salix_im, :conversation_log_recovery, false
