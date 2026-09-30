import Config

# The local recommendation provider is a compile-time capability. Dev/test
# builds include it; production releases include it only when the Docker
# builder opts in explicitly. Runtime configuration may toggle the capability
# only after it has been compiled into the release.
local_recommendation_mock_compiled? =
  config_env() in [:dev, :test] or
    System.get_env("COMMA_LOCAL_RECOMMENDATION_MOCK") == "true"

config :salix_web,
  local_recommendation_mock_compiled: local_recommendation_mock_compiled?

config :comma_web,
  local_recommendation_mock_compiled: local_recommendation_mock_compiled?

# OAuth/OIDC IdP (docs/identity-security.md). The Boruta provider is wired to
# Comma.Repo and the Comma adapters in every environment, but stays inert until
# the deployment enables the endpoint flag (runtime.exs); with the flag off no
# route exists and no Boruta call runs. test.exs overrides the issuer.
config :comma_web, :oauth_idp_enabled, false

config :boruta, Boruta.Oauth,
  repo: Comma.Repo,
  issuer: "http://127.0.0.1:4200",
  contexts: [
    resource_owners: Comma.OauthIdp.ResourceOwners,
    access_tokens: Comma.OauthIdp.HashedAccessTokens,
    codes: Comma.OauthIdp.HashedCodes,
    clients: Comma.OauthIdp.Clients,
    scopes: Comma.OauthIdp.Scopes
  ]

config :ex_aws, http_client: ExAws.Request.Req

# Release-owned, bounded Prometheus model dimension. Provider-returned model
# strings outside this approved product key set converge to `other`.
config :systems_observability, model_keys: ["gpt-5.2"]

config :telemetry_poller, :default,
  period: 10_000,
  measurements: [
    :memory,
    :total_run_queue_lengths,
    :system_counts
  ]

# ====================== Alert Router subsystem ======================
# A separate deployable with its own logical database on the existing Cloud SQL
# instance. It intentionally does not depend on Comma product or Salix runtime.
config :alert_router,
  ecto_repos: [AlertRouter.Repo],
  start_repo: true,
  start_oban: true,
  start_http: true,
  mode: :disabled,
  port: 4300,
  delivery_lease_seconds: 15,
  max_delivery_attempts: 5,
  max_reconcile_attempts: 3,
  reconcile_delay_seconds: 5,
  history_window_seconds: 300,
  timeline_batch_size: 25

config :alert_router, AlertRouter.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "alert_router_dev",
  migration_source: "alert_router_schema_migrations",
  migration_primary_key: [name: :id, type: :binary_id],
  telemetry_prefix: [:alert_router, :repo],
  pool_size: 4

config :alert_router, Oban,
  name: AlertRouter.Oban,
  repo: AlertRouter.Repo,
  peer: {Oban.Peers.Postgres, []},
  queues: [alert_delivery: 2, alert_reconciliation: 1, runtime_log: 1],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}],
  shutdown_grace_period: 10_000

config :alert_router, :slack,
  client: AlertRouter.Slack.ReqClient,
  base_url: "https://slack.com/api",
  request_timeout_ms: 5_000,
  bot_token: nil,
  routes: %{
    "shadow" => "C0ALMF2AD70",
    "live" => nil
  }

config :alert_router, :gcp_push,
  auth_module: AlertRouter.Web.GCPPushAuth.OIDC,
  oidc_provider_enabled: false,
  audience: nil,
  service_account_email: nil

config :alert_router, :grafana_webhook,
  secret: nil,
  signature_header: "x-grafana-alerting-signature",
  timestamp_header: "x-grafana-alerting-signature-timestamp",
  tolerance_seconds: 300

config :alert_router, :github_webhook,
  secret: nil,
  signature_header: "x-hub-signature-256",
  event_header: "x-github-event",
  delivery_header: "x-github-delivery"

# IANA timezone database for cron-style schedules (SalixCluster.Cron / .Schedules).
# Without this, Elixir defaults to Calendar.UTCOnlyTimeZoneDatabase and any
# non-UTC zone lookup (e.g. "America/New_York") fails. `tz` compiles the IANA
# data at build time — no runtime updater.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Text formats the agent runtime reads (any valid UTF-8 — see SalixAgent.Tools
# binary_content?/1) but the mime library doesn't know by default. Needed so
# LiveView's allow_upload accepts them as chat attachments
# (BridgeForTeams.AssistantChats.attachment_upload_extensions/0). The mime lib
# bakes this in at compile time — `mix deps.compile mime --force` after edits.
config :mime, :types, %{
  "text/tab-separated-values" => ["tsv"],
  "application/jsonl" => ["jsonl"],
  "application/yaml" => ["yaml", "yml"],
  "application/toml" => ["toml"],
  "text/x-log" => ["log"]
}

# Route the standard Logger through a JSON-line formatter (CommaLog.Formatter) so
# the whole release emits structured logs in the same shape as the CommaLog
# diagnostic stream. Excluded from :test, where suites assert on the default
# human-readable log format via capture_log.
if config_env() != :test do
  config :logger, :default_formatter,
    format: {CommaLog.Formatter, :format},
    metadata: :all
end

# Storage kernel defaults. Deploy/runtime overrides come from config.json.
# Dev/test point at local MinIO on :19000.
config :salix_store,
  s3_endpoint: "http://127.0.0.1:19000",
  s3_region: "us-east-1",
  s3_bucket: "salix-dev",
  s3_access_key_id: "minioadmin",
  s3_secret_access_key: "minioadmin",
  s3_addressing: :path,
  s3_backend: SalixStore.S3.AWS

# Control-plane Postgres repo defaults (docs/storage-search.md).
# `start_repo: true` is the dev/test default so a bare `mix run`/`mix test`
# starts the repo against the local `salix_dev`/`salix_store_test` DB below.
# runtime.exs supplies the prod URL (and re-affirms start_repo) only when
# `salix.database.url` is set, and prod raises without it for salix. Starting
# is gated by SalixStore.Application's start_repo check, and salix_store only
# boots under the salix subsystem — so a non-salix pod never opens a connection.
# `migration_source` is namespaced because dev and compose deployments share one
# physical database across repos, and shared `schema_migrations` rows silently
# skip same-numbered migrations (see the bridge_for_teams phantom-migration).
config :salix_store,
  ecto_repos: [SalixStore.Repo],
  start_repo: true

config :salix_store, SalixStore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "salix_dev",
  migration_source: "salix_schema_migrations",
  migration_primary_key: [name: :id, type: :binary_id],
  pool_size: 8

config :salix_meet,
  meeting_group_projection_auditor: [interval_ms: 300_000, page_size: 50]

config :salix_web,
  port: 4000

config :salix_im,
  protected_source_ref_contracts: [
    SalixIM.TaskContinuation,
    SalixIM.TaskReplySource,
    SalixIM.MeetingActivationSourceRefs,
    SalixIM.Triage.DelegationAuthorization,
    SalixIM.IFCSourceRefs,
    SalixIM.TaskExecution,
    SalixMeet.PreparationAuthority
  ]

config :comma_core,
  pubsub_server: CommaWeb.PubSub,
  recommendation_runtime_mod: CommaWeb.RecommendationRuntime,
  ecto_repos: [Comma.Repo],
  start_repo: true

config :comma_core, Comma.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "comma_core_dev",
  migration_primary_key: [name: :id, type: :binary_id],
  telemetry_prefix: [:comma, :repo],
  pool_size: 8

operation_claim_timeout_ms = 300_000

# Queue concurrency is per Comma node: 4 external operations, 8 Routine
# generations, and 2 Routine control jobs. Model waits do not hold DB leases
# or consume control slots. Oban shares Comma.Repo's pool rather than owning another
# connection pool. The Postgres peer elects plugin leadership only; durable
# correctness is owned by operation generation fences, never by Oban uniqueness.
# Lifeline and the domain claim use the same recovery window. That keeps a
# Pod-killed `executing` job and its operation on one clock. Routine jobs use
# their separate eight-minute deadline before orphan recovery.
config :comma_core, Oban,
  name: Comma.Oban,
  repo: Comma.Repo,
  peer: {Oban.Peers.Postgres, []},
  queues: [comma_external: 4, comma_recommendations: 8, comma_recommendation_control: 2],
  plugins: [
    {Comma.ObanPlugins.OperationLifeline, rescue_after: operation_claim_timeout_ms, limit: 1_000},
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Comma.Workers.ProfileAvatarCleanup},
       {"17 * * * *", Comma.Workers.MemberSourceItemRetention}
     ]}
  ],
  shutdown_grace_period: 30_000

config :comma_core, :start_oban, true
config :comma_core, :chat_suggestions, true
config :comma_core, :operation_claim_timeout_ms, operation_claim_timeout_ms
config :comma_core, :profile_avatar, adapter: Comma.ProfileAvatar.Storage.GCS, bucket: nil

config :bridge_for_teams_core,
  rate_limit_redis_url: "redis://127.0.0.1:6379/0"

config :salix_web,
  site_rate_limit_redis_url: "redis://127.0.0.1:6379/0"

# Router post_message API windows (docs/product-features.md):
# one sliding minute per key and per group. Zero disables a window.
config :salix_web,
  router_inbox_rate_limits: [key_per_minute: 60, group_per_minute: 600]

config :comma_core, :auth,
  challenge_store: Comma.AuthChallengeStore.Redis,
  email_delivery:
    if(config_env() == :prod, do: Comma.EmailDelivery.Postmark, else: Comma.EmailDelivery.SMTP),
  secret: if(config_env() == :prod, do: nil, else: "comma-dev-auth-secret"),
  rate_limit_secret: if(config_env() == :prod, do: nil, else: "comma-dev-rate-limit-secret"),
  redis_url: if(config_env() == :prod, do: nil, else: "redis://127.0.0.1:6379/0"),
  challenge_ttl_seconds: 900,
  max_attempts: 5,
  session_ttl_seconds: 30 * 24 * 60 * 60,
  auto_create_users: true

config :comma_core, :google_auth,
  adapter: Comma.Auth.GoogleAdapter.Oidcc,
  issuer: "https://accounts.google.com",
  attempt_ttl_seconds: 300

config :comma_core, :mail,
  host: "localhost",
  port: 1025,
  username: "",
  password: "",
  from: "no-reply@comma.local"

config :comma_web,
  port: 4200,
  web_cookie_origin: "http://127.0.0.1:5174",
  admin_cookie_origin: "http://127.0.0.1:4175",
  allowed_origins: [
    "http://127.0.0.1:5173",
    "http://localhost:5173",
    "http://127.0.0.1:5174",
    "http://localhost:5174",
    "http://127.0.0.1:4175",
    "http://localhost:4175"
  ],
  session_cookie: [secure: config_env() == :prod]

config :comma_web, :telegram,
  enabled: false,
  oidc_enabled: false,
  bot_adapter: CommaWeb.TelegramBot.Req,
  oidc_adapter: CommaWeb.TelegramOIDC.Oidcc

config :billing_core,
  repo: BillingCore.Repo

config :billing_commerce,
  repo: BillingCore.Repo,
  vm_resume_waker: BillingCommerce.VMWake.SalixCloudVM,
  cycle_scheduler_enabled: false

config :billing_stripe,
  repo: BillingCore.Repo,
  comma_plans: []

config :billing_core, BillingCore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "billing_core_dev",
  migration_primary_key: [name: :id, type: :binary_id],
  pool_size: 10

# ====================== BridgeForTeams subsystem ======================
# BridgeForTeams uses Ecto/Postgres as its system of record and serves its
# dashboard on a port distinct from salix_web's 4000. Architecture:
# docs/bridge-for-teams/design.md.
config :bridge_for_teams_core,
  ecto_repos: [BridgeForTeams.Repo]

config :bridge_for_teams_core,
  context_lifecycle_purgers: %{
    "slack_history_import" => BridgeForTeams.ContextLifecycle.SlackHistoryPurger
  },
  context_lifecycle_bounds: [
    context_lifecycle_retries: 4,
    context_lifecycle_lease_ms: 180_000,
    read_barrier_transaction_timeout_ms: 125_000,
    lifecycle_request_transaction_timeout_ms: 130_000
  ]

# Bounded sourced-context onboarding remains deny-by-default. Rollback and
# lifecycle recovery deliberately have no kill switch once data exists.
config :bridge_for_teams_core,
  sourced_context_features: [
    # Keep the complete product flow available for deliberate internal review
    # without exposing its entry points or direct route by default.
    onboarding_preview: false,
    discovery: false,
    acquisition: false,
    derivation: false,
    commit: false,
    grounding: false,
    # Knowledge inspection shares the current representative-selection read
    # path. Keep it independent and off until the canonical projection makes
    # request work independent of active import-run count.
    knowledge_inspection: false
  ],
  sourced_context_encryption_key: nil,
  sourced_context_bounds: [
    page_objects: 15,
    run_pages: 2_000,
    run_objects: 1_500,
    run_bytes: 5_242_880,
    stream_retries: 8,
    derivation_artifacts: 100,
    artifact_sources: 20,
    artifact_payload_bytes: 8_000,
    derivation_warnings_bytes: 16_384,
    processor_config_bytes: 1_024,
    derivation_retries: 4,
    derivation_lease_ms: 180_000,
    processor_timeout_ms: 120_000,
    run_derivations: 20,
    run_review_revisions: 50,
    grounding_items: 200,
    grounding_source_refs: 500
  ]

# The persisted run protocol may land before its production processor and Slack
# policy approvals. The background doorbell therefore stays off independently
# from the feature slices; test/local rehearsals drive `run_once/1` explicitly.
config :bridge_for_teams_core, BridgeForTeams.SlackHistoryOnboarding.Reconciler,
  enabled: false,
  interval_ms: 5_000,
  derivation_evidence: nil

# Operations/observability keeps redacted product-delivery facts inside BFT. The
# scheduled pruning worker consumes these explicit windows and the operator task
# can call the same boundary manually when needed.
config :bridge_for_teams_core,
  observability_payload_max_bytes: 16_384,
  observability_freshness: [
    event_history_seconds: 86_400,
    operation_run_history_seconds: 86_400,
    check_result_history_seconds: 86_400,
    integration_check_freshness_seconds: 86_400,
    runner_heartbeat_warning_seconds: 45,
    runner_heartbeat_stale_seconds: 300,
    audit_recent_action_seconds: 86_400
  ],
  observability_retention: [
    observability_events_days: 60,
    operation_runs_days: 180,
    stderr_tail_days: 14,
    check_results_days: 365,
    audit_logs_days: 2_555,
    pruning: :scheduled
  ]

config :bridge_for_teams_core, BridgeForTeams.Observability.Pruner,
  interval_ms: 86_400_000,
  run_on_start: false

# Default BFT Repo settings (UUID primary keys). DATABASE_URL / pool /
# encryption key are applied in runtime.exs under `if :bridge_for_teams in enabled`;
# test.exs overrides for the live Postgres + SQL sandbox.
config :bridge_for_teams_core, BridgeForTeams.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "bridge_for_teams_dev",
  migration_primary_key: [name: :id, type: :binary_id],
  pool_size: 10

# Dashboard i18n (docs/bridge-for-teams/design.md). Gettext compiles only
# these catalogs; the list is mirrored in BridgeForTeamsWeb.I18n and the User
# schema's locale validation. Supported: English (default) + Simplified Chinese.
config :bridge_for_teams_web, BridgeForTeamsWeb.Gettext,
  default_locale: "en",
  locales: ~w(en zh_Hans)

# ---- Dashboard LiveView endpoint (Phoenix on Bandit, port 4101) ----
# Talks to BridgeForTeams.* contexts in-process. secret_key_base/signing_salt
# below are dev defaults; runtime.exs supplies prod secrets.
config :bridge_for_teams_web, BridgeForTeamsWeb.DashboardEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BridgeForTeamsWeb.Dashboard.ErrorHTML],
    layout: false
  ],
  pubsub_server: BridgeForTeamsWeb.PubSub,
  live_view: [signing_salt: "comma4t-dash-salt"],
  secret_key_base: "dev_only_secret_key_base_change_me_000000000000000000000000000000000000",
  http: [
    ip: {127, 0, 0, 1},
    port: 4101,
    http_options: [log_exceptions_with_status_codes: 500..599, log_protocol_errors: false]
  ],
  server: false,
  code_reloader: false

if config_env() != :prod do
  config :bridge_for_teams_web, public_base_url: "http://localhost:4101"
end

config :phoenix, :json_library, Jason

# Platform logs are an operational signal, not a request-payload archive. Keep
# parameter names for diagnosis but redact every value, including query, form,
# LiveView and authentication material.
config :phoenix, :filter_parameters, {:keep, []}

# Standalone tailwind/esbuild for the dashboard assets (bridge_for_teams_web).
config :tailwind,
  version: "3.4.13",
  bridge_for_teams: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/bridge_for_teams_web/assets", __DIR__)
  ]

config :esbuild,
  version: "0.23.0",
  bridge_for_teams: [
    args:
      ~w(app=js/app.js elk-worker=vendor/elk-worker.min.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/bridge_for_teams_web/assets", __DIR__),
    env: %{
      "NODE_PATH" => System.get_env("MIX_DEPS_PATH") || Path.expand("../deps", __DIR__)
    }
  ]

# ---- Salix admin dashboard LiveView endpoint ----
# Served under `/dash` on the SAME Bandit listener as the JSON API (port 4000):
# `server: false` so it opens no listener of its own; SalixWeb.Endpoint invokes
# it as a plug. Talks to Salix.Control in-process. secret_key_base below
# is a dev default; runtime.exs supplies the prod secret.
config :salix_web, SalixWeb.DashboardEndpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SalixWeb.Dashboard.ErrorHTML],
    layout: false
  ],
  pubsub_server: SalixWeb.PubSub,
  live_view: [signing_salt: "salix-dash-salt"],
  secret_key_base: "dev_only_secret_key_base_change_me_111111111111111111111111111111111111",
  server: false,
  code_reloader: false

# Standalone tailwind/esbuild for the Salix dashboard assets (salix_web).
config :tailwind,
  salix: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/salix_web/assets", __DIR__)
  ]

config :esbuild,
  salix: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets),
    cd: Path.expand("../apps/salix_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Default the agent runtime to the protocol dispatcher (anthropic |
# chat-completions | responses, selected per agent template — willow's
# ResolveAgentProviderConfig). Tests override to the scriptable mock.
# There is NO cluster-wide provider fallback (willow parity): agents
# reference their template by id and the provider config is resolved live
# at activation (SalixAgent.LlmResolver, wired to SalixWeb.LlmResolver).
config :salix_agent,
  llm: SalixLlm.Provider,
  recommendation_adapter_mod: CommaWeb.RecommendationRuntime,
  project_knowledge_provider_mod: BridgeForTeams.ProjectKnowledge.AgentProvider,
  project_knowledge_provider_timeout_ms: 250

# schedule_manager tool backend (runtime seam — no compile-time dep/cycle).
config :salix_agent, schedules_mod: SalixCluster.Schedules
config :salix_calendar, task_change_feed_mod: SalixCluster.TaskSchedules
# OAuth control-plane reads for the agent-facing OAuth tools + Exec
# credential_env resolution (contract C3; willow's group bindings / tenant
# provider apps). Tests override per-test with stub modules.
config :salix_agent, oauth_store_mod: SalixWeb.OAuthStore

# Inbound API keys for the Router's own inbound_api.* tools: the credential an
# external system presents to post a message to the Group's Router.
config :salix_agent, inbound_api_key_store_mod: Salix.Bindings.AgentInboundApiKeys

# Tenant Composio settings for the composio.* tools (the direct integrations
# path alongside managed OAuth). Tests override per-test with stub modules.
config :salix_agent, composio_store_mod: Salix.Bindings.AgentComposioStore
# Plugin projection and management control-plane. Runtime reads plugin policy
# through this port so internal, external, and JavaScript runtimes share one
# materialized capability surface.
config :salix_agent, plugin_store_mod: Salix.Bindings.AgentPluginStore
# Durable Task primitives used by the internal IM owner.
config :salix_im, task_create_mod: Salix.Bindings.AgentConversations
config :salix_im, task_execution_owner_mod: CommaWeb.TaskExecutionOwner
config :salix_im, task_schedule_mod: Salix.Bindings.AgentConversations
# Signal product integration (docs/messaging-voice.md): the Signal provider
# reaches accounts through this port, and every account hands its inbound
# messages and calls to the product handler.
config :salix_im, signal_account_mod: SalixSignal.IMPort
config :salix_signal, handler: SalixSignal.IMHandler

config :salix_agent, memory_consultation_source_mod: Salix.Bindings.AgentConversations
config :salix_agent, triage_investigation_authority_mod: SalixIM.Triage.InvestigationAuthority

config :salix_agent, meeting_preparation_mod: SalixMeet.MeetingPreparation
config :salix_im, meeting_preparation_authority_mod: SalixMeet.PreparationAuthority
config :salix_meet, personal_preparation_mod: Salix.Bindings.MeetingPersonalPreparation
config :salix_agent, calendar_mod: Salix.Bindings.AgentCalendar
# Auto session titles after the first assistant reply (SalixAgent.Titles),
# generated with the agent template's analyze model (main LLM fallback).
config :salix_agent, session_titles: true
# L1 heuristic trajectory eval after each settled round (confusion/shortcut
# text markers + stuck-loop structure signals). Zero LLM cost; results land in
# the per-session store (dashboard) and the typed analytics sink.
# The L2 LLM judge (template analyze model) verifies flagged windows on
# signature changes; it spends tenant LLM credit, so it is opt-in per
# deployment. judge_clean_sample_rate additionally samples clean windows for
# false-negative measurement.
# These are the deployment-wide DEFAULTS. config.json can override any of them
# (top-level "trajectory_eval" section, wired in SalixStore.ConfigJson.app_env)
# without a code deploy, and a per-tenant dashboard override still wins over the
# resulting default.
config :salix_agent,
  trajectory_eval: [
    enabled: true,
    sample_rate: 1.0,
    judge_enabled: false,
    judge_clean_sample_rate: 0.0
  ]

# Allowlist of selectable LLM-judge models. The dashboard judge-model dropdown
# offers these by label; the tenant's pick is stored by KEY, and the endpoint +
# credential are resolved server-side (SalixAgent.TrajectoryEval.JudgeProviders)
# so no secret ever reaches the browser or the per-tenant record. Empty by
# default: the dropdown then shows only "Deployment default" and the judge
# keeps inheriting the agent template's analyze model (current behavior).
# config.json (trajectory_eval.judge_providers / .judge_provider) overrides this
# without a deploy. Each entry references its key by api_key_env (an OS env var
# NAME, which MUST be exported on the salix_agent runtime host) — NOT a literal
# secret. Example (fill in real model ids / base_url / env vars per deployment):
#
#     config :salix_agent,
#       trajectory_eval: [..., judge_provider: "haiku"],   # deployment default pick
#       trajectory_eval_judge_providers: %{
#         "haiku" => %{
#           label: "Claude Haiku",
#           protocol: "anthropic",
#           base_url: "https://api.anthropic.com",
#           model: "claude-haiku-4-5-20251001",
#           api_key_env: "SALIX_JUDGE_HAIKU_KEY"
#         },
#         "luna" => %{
#           label: "GPT-5.6 Luna",
#           # A passthrough gateway (e.g. Cloudflare AI Gateway's /openai/
#           # route) forwards the Responses API; an API-normalizing aggregator
#           # usually only speaks chat_completions — match your gateway.
#           protocol: "responses",
#           base_url: "https://<judge-gateway-base-url>",
#           model: "<luna-model-id>",
#           api_key_env: "SALIX_JUDGE_LUNA_KEY",
#           # Judge calls are high-frequency and narrow; cap a reasoning
#           # model's effort so verdicts don't spend full-effort latency/cost.
#           reasoning_effort: "low"
#         }
#       }
config :salix_agent, trajectory_eval_judge_providers: %{}

# Analytics emission seam for trajectory evals (runtime seam — no
# compile-time dep, mirrors llm_metering_mod).
config :salix_agent, trajectory_eval_recorder_mod: SalixAnalytics.TrajectoryEvalRecorder
# Per-tenant trajectory-eval override seam (the dashboard judge on/off switch).
# Runtime seam like composio_store_mod: salix_agent reads the tenant's setting
# through this without depending on salix_web. Unset -> global config applies.
config :salix_agent, trajectory_eval_tenant_mod: Salix.Bindings.AgentTrajectoryEvalSettings
# Self-wake circuit breaker: wait_for fails once this many consecutive wait
# timeouts have woken a session with no new external input in between
# (runaway-polling guard; 0 disables). AsyncPolicy.wait_for_activation_cap/0.
config :salix_agent, wait_for_activation_cap: 20
# Model rounds one input may consume with no fresh input in between before
# the session parks (0 disables). InternalSession.State.input_round_cap/0.
config :salix_agent, input_round_cap: 120
# A wait_for timeout re-arms silently while a Worker on one of the agent's
# active Tasks is still working (runtime seam: Task records live in salix_im).
# SalixAgent.WaitExtension; a wait accumulates at most
# wait_for_extension_ceiling_seconds of silent extension, the safety net
# against runtime faults now that a stopped Worker is pushed to the Router
# (SalixIM.TaskWorkerWatch).
config :salix_agent, wait_extension_mod: SalixIM.RouterWaitProbe
config :salix_agent, wait_for_extension_ceiling_seconds: 1_800
# Wildcard domain for agent-hosted websites (willow defaultSitesDomain).
# {site}-{base32-agent-id}.{sites_domain} is served from the agent VFS by
# SalixWeb.Endpoint; nil/"" disables host-based serving and site URLs.
# Runtime override: config.json web.sites_domain.
config :salix_agent, sites_domain: "salix.localhost"
# Port carried in synthesized site URLs for LOCAL (http/*.localhost) serving —
# the dev endpoint answers on 4000, not 80. URL synthesis ignores this for
# https domains, so hosted deployments are unaffected. Runtime override:
# config.json web.sites_port.
config :salix_agent, sites_port: 4000

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end

# Comma owns Router identity and the database policy. Other surfaces are unchanged.
config :billing_core, llm_billing_policy: Comma.Billing.RouterModels
