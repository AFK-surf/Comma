import Config

if config_env() == :dev do
  config :salix_env,
    device_install_local_artifact_root:
      System.get_env("COMMA_DEVICE_CONNECTOR_DIR") ||
        Path.expand("../../.local/device-install-artifacts", __DIR__)
end

config :salix_agent,
  snapshot_recovery_enabled: System.get_env("COMMA_SNAPSHOT_RECOVERY_ENABLED") == "true"

agent_vmm_gateway = %{
  url_template: System.get_env("SALIX_AGENT_VMM_GATEWAY_URL_TEMPLATE"),
  control_secret: System.get_env("SALIX_AGENT_VMM_GATEWAY_CONTROL_SECRET"),
  ca_file: System.get_env("SALIX_AGENT_VMM_GATEWAY_CA_FILE"),
  cert_file: System.get_env("SALIX_AGENT_VMM_GATEWAY_CERT_FILE"),
  key_file: System.get_env("SALIX_AGENT_VMM_GATEWAY_KEY_FILE")
}

compute_runtime_base_url = System.get_env("SALIX_COMPUTE_RUNTIME_BASE_URL")
compute_workload_credential_secret = System.get_env("SALIX_COMPUTE_WORKLOAD_CREDENTIAL_SECRET")

case System.get_env("SALIX_CONVERSATION_SEARCH_GENERATION") do
  generation when is_binary(generation) and generation != "" ->
    config :salix_store, conversation_search_writer_generation: generation

  _other ->
    :ok
end

if is_binary(compute_runtime_base_url) and compute_runtime_base_url != "" do
  if not (is_binary(compute_workload_credential_secret) and
            byte_size(compute_workload_credential_secret) >= 32) do
    raise "SALIX_COMPUTE_WORKLOAD_CREDENTIAL_SECRET must contain at least 32 bytes when compute runtime is enabled"
  end

  config :salix_store,
    compute_runtime_base_url: String.trim_trailing(compute_runtime_base_url, "/"),
    compute_workload_credential_secret: compute_workload_credential_secret
end

if Enum.any?(agent_vmm_gateway, fn {_key, value} -> is_binary(value) and value != "" end) do
  Enum.each(agent_vmm_gateway, fn {key, value} ->
    if not (is_binary(value) and value != "") do
      raise "incomplete Agent VMM gateway configuration: #{key} is required"
    end
  end)

  if byte_size(agent_vmm_gateway.control_secret) < 32 do
    raise "Agent VMM gateway control_secret must contain at least 32 bytes"
  end

  config :salix_web,
    agent_vmm_gateway_control_secret: agent_vmm_gateway.control_secret

  config :salix_store,
    agent_vmm_gateway_url_template: agent_vmm_gateway.url_template,
    agent_vmm_gateway_tls: [
      verify: :verify_peer,
      cacertfile: String.to_charlist(agent_vmm_gateway.ca_file),
      certfile: String.to_charlist(agent_vmm_gateway.cert_file),
      keyfile: String.to_charlist(agent_vmm_gateway.key_file),
      versions: [:"tlsv1.3"]
    ]
end

# Subsystem selection (one image, per-pod choice): COMMA_SUBSYSTEMS is a
# comma-separated list of subsystem names (e.g. "salix"). Unset/empty = run
# every subsystem in this build, except an explicit release job may select none
# for artifact-only `eval`. Consumed by Comma.Application at boot; in a release
# the unselected subsystems' apps stay loaded-but-not-started. (No effect under
# `mix run`/`mix test`, where Mix starts all umbrella apps.)
#
# Config is loaded PER ENABLED SUBSYSTEM: each subsystem's runtime config — and
# its prod requirement checks — run only when it is enabled, so a node that does
# not run a subsystem needs none of that subsystem's configuration.
known_subsystems =
  if Code.ensure_loaded?(Comma) and function_exported?(Comma, :known_subsystems, 0) do
    Comma.known_subsystems()
  else
    [:alert_router, :salix, :comma_product, :bridge_for_teams]
  end

release_job? = System.get_env("COMMA_RELEASE_JOB") == "1"

enabled =
  case {release_job?, System.get_env("COMMA_SUBSYSTEMS")} do
    {true, value} when value in [nil, ""] ->
      []

    {_, nil} ->
      known_subsystems

    {_, ""} ->
      known_subsystems

    {_, subs} ->
      subs
      |> String.split(",", trim: true)
      |> Enum.map(fn raw_name ->
        name = String.trim(raw_name)

        Enum.find(known_subsystems, &(Atom.to_string(&1) == name)) ||
          raise "unknown COMMA_SUBSYSTEMS entry #{inspect(name)}; known: #{inspect(known_subsystems)}"
      end)
  end

config :comma, enabled_subsystems: enabled

redis_required? = Enum.any?(enabled, &(&1 in [:salix, :comma_product, :bridge_for_teams]))

redis_url =
  if not redis_required? do
    nil
  else
    System.get_env("REDIS_URL") ||
      System.get_env("COMMA_REDIS_URL") ||
      if(config_env() == :prod,
        do: raise("REDIS_URL is required for distributed auth and rate limiting"),
        else: "redis://127.0.0.1:6379/0"
      )
  end

if is_binary(redis_url) do
  config :bridge_for_teams_core, rate_limit_redis_url: redis_url
  config :salix_web, site_rate_limit_redis_url: redis_url

  # OAuth IdP entry-point limiter (docs/identity-security.md): shares the
  # deployment Redis. Configuring the URL is what mounts the limiter child,
  # so only comma_product pods carry the extra Redis connection.
  if :comma_product in enabled do
    config :comma_core, :oauth_idp_rate_limit_redis_url, redis_url
    config :comma_core, :task_share_rate_limit_redis_url, redis_url
  end
end

# Release Jobs boot the same artifact to evaluate a plan or execute an explicitly
# authorized stage. Domain convergence remains owned by serving workers; do not
# start another worker copy as a side effect of a release command.
if System.get_env("COMMA_RELEASE_JOB") == "1" do
  config :billing_core, pending_charge_worker_enabled: false
end

# One release-owned trace SDK. Development/test stays no-op unless an explicit
# collector endpoint is supplied; deployed environments use the dedicated Comma
# trace-only collector. Parent-based sampling preserves upstream decisions.
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
comma_environment = System.get_env("COMMA_ENVIRONMENT") || to_string(config_env())

# Release log level. Nothing set it before, so releases ran at Logger's
# default :debug and Ecto printed every query: the pod log budget covered only
# about two minutes of history, which hid the crash context of the 2026-09-03
# comma-1 loop and the 2026-09-04 stand-up dispatch. Info by default; COMMA_LOG_LEVEL
# (emergency|alert|critical|error|warning|notice|info|debug) opens it back up
# for a diagnosis without a rebuild.
if config_env() == :prod do
  log_level =
    case System.get_env("COMMA_LOG_LEVEL", "") |> String.trim() |> String.downcase() do
      "" ->
        :info

      level ->
        Enum.find(
          [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug],
          &(Atom.to_string(&1) == level)
        ) || raise "unknown COMMA_LOG_LEVEL #{inspect(level)}"
    end

  config :logger, level: log_level
end

allowed_comma_environments = [
  "local",
  "development",
  "dev",
  "test",
  "staging",
  "selfhost",
  "production",
  "prod"
]

if comma_environment not in allowed_comma_environments do
  raise "COMMA_ENVIRONMENT must be one of #{Enum.join(allowed_comma_environments, ", ")}, got: #{inspect(comma_environment)}"
end

local_comma_environment? = comma_environment in ["local", "development", "dev", "test"]
config :comma_core, selfhost: comma_environment == "selfhost", environment: comma_environment

# Enable staging's explicit preview-only Slack-history flow. Publication and
# Agent grounding remain off; production and prod remain deny-by-default, and
# test keeps its dedicated config/test.exs gates.
if config_env() == :prod do
  config :bridge_for_teams_core,
    sourced_context_features: [
      onboarding_preview: comma_environment == "staging",
      discovery: comma_environment == "staging",
      acquisition: comma_environment == "staging",
      derivation: comma_environment == "staging",
      commit: false,
      grounding: false,
      knowledge_inspection: false
    ]
end

# The local Electron launcher persists this bearer in a gitignored file so
# Forge can relaunch Main without another login. Keep ordinary/admin support
# Sessions bounded to their production limits; only an explicitly marked local
# developer Session may use this non-production lifetime.
if local_comma_environment? do
  config :comma_core, local_dev_session_ttl_seconds: 10 * 365 * 24 * 60 * 60
end

config :salix_web,
  local_oauth_mock: false,
  local_recommendation_mock: false,
  # Authenticated meeting replay is an internal deployed-environment ops surface.
  # Local/dev/test remain fail-closed; production keeps the same admin, project,
  # confirmation, idempotency, audit, metering, privacy, and no-delivery gates.
  meeting_notes_online_replay_enabled: comma_environment in ["staging", "production", "prod"]

case System.get_env("COMMA_SESSION_COOKIE_SECURE") do
  nil ->
    :ok

  "true" ->
    config :comma_web, session_cookie: [secure: true]

  "false" when comma_environment in ["local", "development", "dev", "test"] ->
    config :comma_web, session_cookie: [secure: false]

  "false" when comma_environment == "selfhost" ->
    public_url = URI.parse(System.get_env("COMMA_PUBLIC_URL") || "")

    unless public_url.scheme == "http" and public_url.host in ["localhost", "127.0.0.1", "::1"] do
      raise "Self-hosted HTTP cookies require a loopback COMMA_PUBLIC_URL. Use HTTPS for remote access."
    end

    config :comma_web, session_cookie: [secure: false]

  "false" ->
    raise "COMMA_SESSION_COOKIE_SECURE=false is only allowed in an explicit local/dev/test environment"

  value ->
    raise "COMMA_SESSION_COOKIE_SECURE must be true or false, got: #{inspect(value)}"
end

sample_ratio =
  case Float.parse(System.get_env("COMMA_TRACE_SAMPLE_RATIO") || "") do
    {ratio, ""} when ratio >= 0.0 and ratio <= 1.0 -> ratio
    _ when comma_environment in ["production", "prod"] -> 0.10
    _ -> 1.0
  end

if is_binary(otel_endpoint) and otel_endpoint != "" do
  resource = SystemsObservability.Resource.identity(System.get_env())

  config :opentelemetry,
    sampler: {:parent_based, %{root: {:trace_id_ratio_based, sample_ratio}}},
    resource: SystemsObservability.Resource.otel_resource(resource),
    processors: [
      otel_batch_processor: %{
        max_queue_size: 2_048,
        scheduled_delay_ms: 5_000,
        exporting_timeout_ms: 10_000,
        exporter:
          {:opentelemetry_exporter, %{protocol: :http_protobuf, endpoints: [otel_endpoint]}}
      }
    ]
else
  config :opentelemetry, traces_exporter: :none
end

case System.get_env("SALIX_SNOWFLAKE_WORKER_ID") do
  id when is_binary(id) and id != "" ->
    config :salix_store, snowflake_worker_id: id

  _ ->
    if config_env() != :prod do
      config :salix_store, snowflake_worker_id: 0
    end
end

config_path = SalixStore.ConfigJson.resolve_path()

salix_config =
  case SalixStore.ConfigJson.load(config_path) do
    {:ok, json} ->
      json

    {:error, reason} ->
      raise "failed to load salix config #{inspect(config_path)}: #{inspect(reason)}"
  end

for {app, key, value} <- SalixStore.ConfigJson.synchronicity_env(salix_config) do
  config app, [{key, value}]
end

# ====================== Alert Router subsystem ======================
#
# This is an independently selectable pod from the same Comma release image. It
# uses a dedicated logical Postgres database on the existing Cloud SQL instance
# and owns its own Oban tables. It does not require Redis, Billing, Comma Product,
# or Salix. Provider credentials are mandatory only when delivery is active;
# the default remains fail-closed `disabled`.
if :alert_router in enabled and config_env() != :test do
  nonempty = fn value -> is_binary(value) and String.trim(value) != "" end

  alert_router_mode =
    SalixStore.ConfigJson.string(salix_config, ~w(alert_router mode)) ||
      System.get_env("ALERT_ROUTER_MODE") || "disabled"

  alert_router_mode =
    case String.downcase(String.trim(alert_router_mode)) do
      "disabled" -> :disabled
      "shadow" -> :shadow
      "live" -> :live
      value -> raise "alert_router.mode must be disabled, shadow, or live, got: #{inspect(value)}"
    end

  alert_router_database_url =
    SalixStore.ConfigJson.string(salix_config, ~w(alert_router database url)) ||
      System.get_env("ALERT_ROUTER_DATABASE_URL")

  if config_env() == :prod and not nonempty.(alert_router_database_url) do
    raise "alert_router.database.url is required for the alert_router subsystem"
  end

  alert_router_pool_size =
    if release_job? do
      2
    else
      SalixStore.ConfigJson.integer(salix_config, ~w(alert_router database pool_size)) || 4
    end

  alert_router_port =
    case Integer.parse(System.get_env("ALERT_ROUTER_PORT") || "4300") do
      {port, ""} when port > 0 and port <= 65_535 -> port
      _ -> raise "ALERT_ROUTER_PORT must be an integer from 1 through 65535"
    end

  config :alert_router,
    ecto_repos: [AlertRouter.Repo],
    start_repo: true,
    start_oban: not release_job?,
    start_http: not release_job?,
    mode: alert_router_mode,
    port: alert_router_port

  if nonempty.(alert_router_database_url) do
    config :alert_router, AlertRouter.Repo,
      url: alert_router_database_url,
      pool_size: alert_router_pool_size,
      telemetry_prefix: [:alert_router, :repo]
  end

  if alert_router_mode in [:shadow, :live] do
    slack_bot_token =
      SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack bot_token)) ||
        System.get_env("ALERT_ROUTER_SLACK_BOT_TOKEN")

    route_channel_id =
      case alert_router_mode do
        :shadow ->
          SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack shadow_channel_id)) ||
            System.get_env("ALERT_ROUTER_SHADOW_CHANNEL_ID")

        :live ->
          SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack live_channel_id)) ||
            System.get_env("ALERT_ROUTER_LIVE_CHANNEL_ID")
      end

    gcp_audience =
      SalixStore.ConfigJson.string(salix_config, ~w(alert_router gcp_push audience)) ||
        System.get_env("ALERT_ROUTER_GCP_PUSH_AUDIENCE")

    gcp_service_account_email =
      SalixStore.ConfigJson.string(
        salix_config,
        ~w(alert_router gcp_push service_account_email)
      ) || System.get_env("ALERT_ROUTER_GCP_PUSH_SERVICE_ACCOUNT_EMAIL")

    grafana_secret =
      SalixStore.ConfigJson.string(salix_config, ~w(alert_router grafana_webhook secret)) ||
        System.get_env("ALERT_ROUTER_GRAFANA_WEBHOOK_SECRET")

    github_secret =
      SalixStore.ConfigJson.string(salix_config, ~w(alert_router github_webhook secret)) ||
        System.get_env("ALERT_ROUTER_GITHUB_WEBHOOK_SECRET")

    for {value, path} <- [
          {slack_bot_token, "alert_router.slack.bot_token"},
          {route_channel_id, "alert_router.slack.#{alert_router_mode}_channel_id"},
          {gcp_audience, "alert_router.gcp_push.audience"},
          {gcp_service_account_email, "alert_router.gcp_push.service_account_email"},
          {grafana_secret, "alert_router.grafana_webhook.secret"},
          {github_secret, "alert_router.github_webhook.secret"}
        ] do
      if not nonempty.(value),
        do: raise("#{path} is required when alert_router.mode=#{alert_router_mode}")
    end

    if byte_size(grafana_secret) < 32 do
      raise "alert_router.grafana_webhook.secret must contain at least 32 bytes"
    end

    if byte_size(github_secret) < 32 do
      raise "alert_router.github_webhook.secret must contain at least 32 bytes"
    end

    config :alert_router, :slack,
      bot_token: slack_bot_token,
      routes: %{Atom.to_string(alert_router_mode) => route_channel_id}

    # Optional until the Slack app's Events API subscription is configured.
    config :alert_router, :slack_progress,
      signing_secret:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack signing_secret)) ||
          System.get_env("ALERT_ROUTER_SLACK_SIGNING_SECRET"),
      team_id:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack team_id)) ||
          System.get_env("ALERT_ROUTER_SLACK_TEAM_ID"),
      app_id:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack app_id)) ||
          System.get_env("ALERT_ROUTER_SLACK_APP_ID"),
      investigator_bot_id:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router slack investigator_bot_id)) ||
          System.get_env("ALERT_ROUTER_SLACK_INVESTIGATOR_BOT_ID")

    config :alert_router,
      gcp_projects: %{
        staging:
          SalixStore.ConfigJson.string(salix_config, ~w(alert_router gcp_projects staging)) ||
            System.get_env("ALERT_ROUTER_GCP_STAGING_PROJECT"),
        production:
          SalixStore.ConfigJson.string(salix_config, ~w(alert_router gcp_projects production)) ||
            System.get_env("ALERT_ROUTER_GCP_PRODUCTION_PROJECT")
      },
      gke_cluster:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router gke_cluster)) ||
          System.get_env("ALERT_ROUTER_GKE_CLUSTER")

    config :alert_router, :gcp_push,
      auth_module: AlertRouter.Web.GCPPushAuth.OIDC,
      oidc_provider_enabled: true,
      audience: gcp_audience,
      service_account_email: gcp_service_account_email

    config :alert_router, :grafana_webhook, secret: grafana_secret
    config :alert_router, :github_webhook, secret: github_secret

    # Independently activated, read-only canonical-log consumer. No Agent
    # persistence or ACK path depends on these settings or the alert database.
    runtime_field = fn key, env ->
      SalixStore.ConfigJson.string(salix_config, ["alert_router", "runtime_log", key]) ||
        System.get_env(env)
    end

    runtime_enabled =
      SalixStore.ConfigJson.boolean(salix_config, ~w(alert_router runtime_log enabled)) == true or
        System.get_env("ALERT_ROUTER_RUNTIME_LOG_ENABLED") == "true"

    config :alert_router, :runtime_log,
      enabled: runtime_enabled,
      bucket: runtime_field.("bucket", "ALERT_ROUTER_RUNTIME_LOG_BUCKET"),
      environment: runtime_field.("environment", "ALERT_ROUTER_RUNTIME_LOG_ENVIRONMENT"),
      cluster: runtime_field.("cluster", "ALERT_ROUTER_RUNTIME_LOG_CLUSTER"),
      start_at: runtime_field.("start_at", "ALERT_ROUTER_RUNTIME_LOG_START_AT")

    config :alert_router, :runtime_storage_push,
      audience: runtime_field.("push_audience", "ALERT_ROUTER_RUNTIME_STORAGE_PUSH_AUDIENCE"),
      service_account_email:
        runtime_field.(
          "push_service_account_email",
          "ALERT_ROUTER_RUNTIME_STORAGE_PUSH_SERVICE_ACCOUNT_EMAIL"
        )

    # Dedicated read-only credentials, not the business runtime's write identity.
    # Source configuration failure affects its jobs/ingress, not core readiness.
    if runtime_enabled and :salix not in enabled do
      for {field, env, key} <- [
            {"storage_endpoint", "ALERT_ROUTER_RUNTIME_STORAGE_ENDPOINT", :s3_endpoint},
            {"bucket", "ALERT_ROUTER_RUNTIME_LOG_BUCKET", :s3_bucket},
            {"storage_access_key_id", "ALERT_ROUTER_RUNTIME_STORAGE_ACCESS_KEY_ID",
             :s3_access_key_id},
            {"storage_secret_access_key", "ALERT_ROUTER_RUNTIME_STORAGE_SECRET_ACCESS_KEY",
             :s3_secret_access_key}
          ] do
        config :salix_store, [{key, runtime_field.(field, env)}]
      end
    end

    # Optional, independently activated source. Credentials stay on the server.
    config :alert_router, :posthog_webhook,
      secret:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router posthog_webhook secret)) ||
          System.get_env("ALERT_ROUTER_POSTHOG_WEBHOOK_SECRET"),
      project_id:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router posthog_webhook project_id)) ||
          System.get_env("ALERT_ROUTER_POSTHOG_PROJECT_ID"),
      origin:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router posthog_webhook origin)) ||
          System.get_env("ALERT_ROUTER_POSTHOG_ORIGIN"),
      environment:
        SalixStore.ConfigJson.string(salix_config, ~w(alert_router posthog_webhook environment)) ||
          System.get_env("ALERT_ROUTER_POSTHOG_ENVIRONMENT")
  else
    config :alert_router, :gcp_push,
      auth_module: AlertRouter.Web.GCPPushAuth.DenyAll,
      oidc_provider_enabled: false
  end
end

default_comma_allowed_origins =
  case comma_environment do
    environment when environment in ["production", "prod"] ->
      ["https://app.comma.surf", "https://admin.comma.surf"]

    "staging" ->
      ["https://app-staging.comma.surf", "https://admin-staging.comma.surf"]

    _local_or_test ->
      Application.get_env(:comma_web, :allowed_origins, [])
  end

default_comma_web_cookie_origin =
  case comma_environment do
    environment when environment in ["production", "prod"] ->
      "https://app.comma.surf"

    "staging" ->
      "https://app-staging.comma.surf"

    _local_or_test ->
      Application.fetch_env!(:comma_web, :web_cookie_origin)
  end

default_comma_admin_cookie_origin =
  case comma_environment do
    environment when environment in ["production", "prod"] ->
      "https://admin.comma.surf"

    "staging" ->
      "https://admin-staging.comma.surf"

    _local_or_test ->
      Application.fetch_env!(:comma_web, :admin_cookie_origin)
  end

comma_allowed_origins =
  case SalixStore.ConfigJson.get(salix_config, ~w(comma web allowed_origins)) do
    nil ->
      default_comma_allowed_origins

    origins when is_list(origins) ->
      Enum.map(origins, fn
        origin when is_binary(origin) ->
          origin = String.trim(origin)
          uri = URI.parse(origin)

          if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
               is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and
               is_nil(uri.fragment) do
            origin
          else
            raise "comma.web.allowed_origins contains an invalid origin: #{inspect(origin)}"
          end

        origin ->
          raise "comma.web.allowed_origins must contain only strings, got: #{inspect(origin)}"
      end)
      |> Enum.uniq()

    value ->
      raise "comma.web.allowed_origins must be a list, got: #{inspect(value)}"
  end

comma_web_cookie_origin =
  case SalixStore.ConfigJson.get(salix_config, ~w(comma web web_cookie_origin)) do
    nil ->
      default_comma_web_cookie_origin

    origin when is_binary(origin) ->
      origin = String.trim(origin)
      uri = URI.parse(origin)

      if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
           is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and
           is_nil(uri.fragment) do
        origin
      else
        raise "comma.web.web_cookie_origin contains an invalid origin: #{inspect(origin)}"
      end

    value ->
      raise "comma.web.web_cookie_origin must be exactly one origin string, got: #{inspect(value)}"
  end

comma_admin_cookie_origin =
  case SalixStore.ConfigJson.get(salix_config, ~w(comma web admin_cookie_origin)) do
    nil ->
      default_comma_admin_cookie_origin

    origin when is_binary(origin) ->
      origin = String.trim(origin)
      uri = URI.parse(origin)

      if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
           is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and
           is_nil(uri.fragment) do
        origin
      else
        raise "comma.web.admin_cookie_origin contains an invalid origin: #{inspect(origin)}"
      end

    value ->
      raise "comma.web.admin_cookie_origin must be exactly one origin string, got: #{inspect(value)}"
  end

if Enum.count(comma_allowed_origins, &(&1 == comma_web_cookie_origin)) != 1 do
  raise "comma.web.web_cookie_origin must appear exactly once in comma.web.allowed_origins, got: #{inspect(comma_web_cookie_origin)}"
end

if Enum.count(comma_allowed_origins, &(&1 == comma_admin_cookie_origin)) != 1 do
  raise "comma.web.admin_cookie_origin must appear exactly once in comma.web.allowed_origins, got: #{inspect(comma_admin_cookie_origin)}"
end

if comma_admin_cookie_origin == comma_web_cookie_origin do
  raise "comma.web.admin_cookie_origin must differ from comma.web.web_cookie_origin"
end

config :comma_web,
  allowed_origins: comma_allowed_origins,
  web_cookie_origin: comma_web_cookie_origin,
  admin_cookie_origin: comma_admin_cookie_origin

# The Routine generation job renders a briefing from server-collected facts.
# Unset, a member briefing uses the workspace Router's template and a generic
# briefing the worker's; set, it uses this template regardless of either, so
# the briefing model and its provider quota are chosen for that task alone.
comma_recommendation_template_id =
  case System.get_env("COMMA_RECOMMENDATION_TEMPLATE_ID") ||
         SalixStore.ConfigJson.string(salix_config, ~w(comma recommendations template_id)) do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> nil
  end

config :comma_web, recommendation_template_id: comma_recommendation_template_id

# Comma product Telegram DM ingress is opt-in. Webhook registration remains an
# explicit release operation (`mix comma.telegram.webhook --apply`); boot and
# migrations only validate configuration and never mutate Telegram state.
comma_telegram_enabled? =
  System.get_env("COMMA_TELEGRAM_ENABLED") == "true" or
    SalixStore.ConfigJson.get(salix_config, ~w(comma telegram enabled)) == true

if comma_telegram_enabled? do
  telegram_value = fn env_name, config_path ->
    case System.get_env(env_name) || SalixStore.ConfigJson.string(salix_config, config_path) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> raise "#{env_name} is required when Comma Telegram is enabled"
    end
  end

  telegram_bot_token = telegram_value.("COMMA_TELEGRAM_BOT_TOKEN", ~w(comma telegram bot_token))

  telegram_bot_username =
    telegram_value.("COMMA_TELEGRAM_BOT_USERNAME", ~w(comma telegram bot_username))
    |> String.trim_leading("@")

  telegram_public_base_url =
    telegram_value.("COMMA_TELEGRAM_PUBLIC_BASE_URL", ~w(comma telegram public_base_url))

  telegram_webhook_secret =
    telegram_value.("COMMA_TELEGRAM_WEBHOOK_SECRET", ~w(comma telegram webhook_secret))

  telegram_api_base_url =
    case System.get_env("COMMA_TELEGRAM_API_BASE_URL") do
      value when value in [nil, ""] ->
        "https://api.telegram.org"

      value when local_comma_environment? ->
        value = String.trim(value)
        uri = URI.parse(value)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
             is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and
             is_nil(uri.fragment) do
          String.trim_trailing(value, "/")
        else
          raise "COMMA_TELEGRAM_API_BASE_URL must be a bare http/https origin in local environments"
        end

      _value ->
        raise "COMMA_TELEGRAM_API_BASE_URL is only supported in local environments"
    end

  unless Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]{1,28}[Bb][Oo][Tt]$/, telegram_bot_username) do
    raise "COMMA_TELEGRAM_BOT_USERNAME must be a valid Telegram bot username ending in bot"
  end

  unless byte_size(telegram_webhook_secret) >= 32 and byte_size(telegram_webhook_secret) <= 256 and
           Regex.match?(~r/^[A-Za-z0-9_-]+$/, telegram_webhook_secret) do
    raise "COMMA_TELEGRAM_WEBHOOK_SECRET must contain 32-256 ASCII letters, digits, underscores, or hyphens"
  end

  telegram_base_uri = URI.parse(telegram_public_base_url)
  telegram_schemes = if local_comma_environment?, do: ["http", "https"], else: ["https"]

  unless telegram_base_uri.scheme in telegram_schemes and is_binary(telegram_base_uri.host) and
           telegram_base_uri.host != "" and is_nil(telegram_base_uri.userinfo) and
           telegram_base_uri.path in [nil, ""] and is_nil(telegram_base_uri.query) and
           is_nil(telegram_base_uri.fragment) do
    raise "COMMA_TELEGRAM_PUBLIC_BASE_URL must be a bare #{Enum.join(telegram_schemes, "/")} origin"
  end

  telegram_client_id =
    System.get_env("COMMA_TELEGRAM_CLIENT_ID") ||
      SalixStore.ConfigJson.string(salix_config, ~w(comma telegram client_id))

  telegram_client_secret =
    System.get_env("COMMA_TELEGRAM_CLIENT_SECRET") ||
      SalixStore.ConfigJson.string(salix_config, ~w(comma telegram client_secret))

  if (is_binary(telegram_client_id) and telegram_client_id != "") !=
       (is_binary(telegram_client_secret) and telegram_client_secret != "") do
    raise "COMMA_TELEGRAM_CLIENT_ID and COMMA_TELEGRAM_CLIENT_SECRET must be configured together"
  end

  telegram_oidc_enabled? =
    is_binary(telegram_client_id) and telegram_client_id != "" and
      is_binary(telegram_client_secret) and telegram_client_secret != ""

  config :comma_web, :telegram,
    enabled: true,
    oidc_enabled: telegram_oidc_enabled?,
    bot_token: telegram_bot_token,
    bot_username: telegram_bot_username,
    public_base_url: String.trim_trailing(telegram_public_base_url, "/"),
    webhook_secret: telegram_webhook_secret,
    client_id: telegram_client_id,
    client_secret: telegram_client_secret,
    api_base_url: telegram_api_base_url,
    bot_adapter: CommaWeb.TelegramBot.Req,
    oidc_adapter: CommaWeb.TelegramOIDC.Oidcc

  # Comma sends lifecycle messages directly while Salix sends Agent replies.
  # Keep both clients on the same endpoint in local deterministic acceptance.
  config :salix_im, telegram_api_base_url: telegram_api_base_url
end

# One shared iMessage relay, disabled until its operator selects an identity.
comma_imessage_enabled? =
  System.get_env("COMMA_IMESSAGE_ENABLED") == "true" or
    SalixStore.ConfigJson.get(salix_config, ~w(comma imessage enabled)) == true

if comma_imessage_enabled? do
  imessage_value = fn name, key ->
    case System.get_env(name) ||
           SalixStore.ConfigJson.string(salix_config, ["comma", "imessage", key]) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> raise "#{name} is required when Comma iMessage is enabled"
    end
  end

  imessage_base = imessage_value.("COMMA_IMESSAGE_RELAY_BASE_URL", "relay_base_url")
  imessage_uri = URI.parse(imessage_base)
  imessage_schemes = if local_comma_environment?, do: ["http", "https"], else: ["https"]

  unless imessage_uri.scheme in imessage_schemes and is_binary(imessage_uri.host) and
           imessage_uri.host != "" and is_nil(imessage_uri.userinfo) and
           imessage_uri.path in [nil, ""] and is_nil(imessage_uri.query) and
           is_nil(imessage_uri.fragment) do
    raise "COMMA_IMESSAGE_RELAY_BASE_URL must be a bare permitted HTTP origin"
  end

  config :salix_im, :imessage,
    enabled: true,
    relay_id: imessage_value.("COMMA_IMESSAGE_RELAY_ID", "relay_id"),
    base_url: imessage_base,
    bearer_token: imessage_value.("COMMA_IMESSAGE_RELAY_BEARER_TOKEN", "relay_bearer_token"),
    shared_handle: imessage_value.("COMMA_IMESSAGE_SHARED_HANDLE", "shared_handle"),
    shared_identity:
      System.get_env("COMMA_IMESSAGE_SHARED_IDENTITY") ||
        SalixStore.ConfigJson.string(salix_config, ~w(comma imessage shared_identity)) || "Comma"
end

# OAuth/OIDC IdP endpoint flag (docs/identity-security.md). Off by
# default everywhere; enabling requires the public API origin as issuer so a
# misconfigured deployment fails at boot instead of publishing a discovery
# document with wrong endpoints.
comma_oauth_idp_enabled? =
  System.get_env("COMMA_OAUTH_IDP_ENABLED") == "true" or
    SalixStore.ConfigJson.get(salix_config, ~w(comma web oauth_idp enabled)) == true

if comma_oauth_idp_enabled? do
  comma_oauth_idp_issuer =
    System.get_env("COMMA_OAUTH_IDP_ISSUER") ||
      SalixStore.ConfigJson.string(salix_config, ~w(comma web oauth_idp issuer)) ||
      raise(
        "comma.web.oauth_idp.issuer (or COMMA_OAUTH_IDP_ISSUER) is required when the OAuth IdP is enabled"
      )

  issuer_uri = URI.parse(comma_oauth_idp_issuer)

  # OIDC Discovery §3: the issuer is an HTTPS URL, and every URL the
  # discovery document derives from it inherits the scheme. http stays
  # available only for explicit local/dev/test environments.
  allowed_issuer_schemes = if local_comma_environment?, do: ["http", "https"], else: ["https"]

  unless issuer_uri.scheme in allowed_issuer_schemes and is_binary(issuer_uri.host) and
           issuer_uri.host != "" and is_nil(issuer_uri.userinfo) and
           issuer_uri.path in [nil, ""] and is_nil(issuer_uri.query) and
           is_nil(issuer_uri.fragment) do
    raise "comma.web.oauth_idp.issuer must be a bare #{Enum.join(allowed_issuer_schemes, "/")} origin without credentials, got: #{inspect(comma_oauth_idp_issuer)}"
  end

  config :comma_web, :oauth_idp_enabled, true
  config :boruta, Boruta.Oauth, issuer: comma_oauth_idp_issuer
end

bridge_public_base_url =
  SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams dashboard public_base_url)) ||
    SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams web public_base_url))

if default_template = SalixStore.ConfigJson.get(salix_config, ~w(llm default_template)) do
  config :comma_core, :default_agent_template, default_template
  config :salix_agent, llm: SalixLlm.Provider

  template_id = default_template["template_id"]
  model_id = default_template["model"]
  model_provider = default_template["provider"]

  if comma_environment == "staging" and :salix in enabled and :bridge_for_teams in enabled and
       Enum.all?([template_id, model_id, model_provider], &(is_binary(&1) and &1 != "")) do
    # Readiness seed only. The production Processor replaces this with the actual
    # project Router/template evidence before the reconciler persists a request.
    # Credentials stay outside even this diagnostic fingerprint.
    revision_template =
      default_template
      |> Map.take(["template_id", "name", "model", "provider", "max_tokens", "context_tokens"])
      |> Map.put(
        "provider_config",
        default_template
        |> Map.get("provider_config", %{})
        |> Map.take(["protocol", "base_url"])
      )

    template_revision =
      revision_template
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    derivation_evidence = %{
      model_provider: model_provider,
      model_id: model_id,
      model_revision: "template-sha256:" <> template_revision,
      prompt_template_id: "bft-history-extraction",
      prompt_revision: "bft-history-extraction-v1",
      policy_revision: "bft-sourced-context-policy-v1",
      schema_revision: "people-project-decision-context-v1",
      processor_config: %{
        "temperature_millis" => 0,
        "max_output_tokens" => 4_096
      }
    }

    config :bridge_for_teams_core,
      sourced_context_processor: Salix.Bindings.SourcedContextProcessor,
      sourced_context_processor_evidence: derivation_evidence

    config :bridge_for_teams_core, BridgeForTeams.SlackHistoryOnboarding.Reconciler,
      derivation_evidence: derivation_evidence
  end
end

billing_enabled? = Enum.any?(enabled, &(&1 in [:salix, :comma_product, :bridge_for_teams]))

billing_database_url =
  if billing_enabled? and config_env() != :test do
    SalixStore.ConfigJson.string(salix_config, ~w(billing database url)) ||
      (config_env() == :prod and
         raise "billing.database.url is required for billing-capable subsystems")
  end

comma_database_url =
  if :comma_product in enabled and config_env() != :test do
    SalixStore.ConfigJson.string(salix_config, ~w(comma database url)) ||
      (config_env() == :prod and raise "comma.database.url is required for comma_product")
  end

if is_binary(comma_database_url) do
  comma_pool_size =
    if System.get_env("COMMA_RELEASE_JOB") == "1" do
      2
    else
      SalixStore.ConfigJson.integer(salix_config, ~w(comma database pool_size)) || 8
    end

  config :comma_core,
    ecto_repos: [Comma.Repo],
    start_repo: true,
    start_oban: System.get_env("COMMA_RELEASE_JOB") != "1"

  config :comma_core, Comma.Repo,
    url: comma_database_url,
    pool_size: comma_pool_size,
    telemetry_prefix: [:comma, :repo]
end

comma_google_web_client_id =
  SalixStore.ConfigJson.string(salix_config, ~w(comma google_auth web_client_id))

if is_binary(comma_google_web_client_id) and comma_google_web_client_id != "" do
  config :comma_core, :google_auth, web_client_id: comma_google_web_client_id
end

comma_google_electron_client_id =
  SalixStore.ConfigJson.string(salix_config, ~w(comma google_auth electron_client_id))

if is_binary(comma_google_electron_client_id) and comma_google_electron_client_id != "" do
  config :comma_core, :google_auth, electron_client_id: comma_google_electron_client_id
end

comma_google_android_client_ids =
  case SalixStore.ConfigJson.get(salix_config, ~w(comma google_auth android_client_ids)) do
    nil ->
      []

    ids when is_list(ids) ->
      Enum.map(ids, fn
        id when is_binary(id) and id != "" -> id
        _invalid -> raise("comma.google_auth.android_client_ids must contain nonempty strings")
      end)

    _invalid ->
      raise("comma.google_auth.android_client_ids must be a list")
  end

if comma_google_android_client_ids != [] do
  config :comma_core, :google_auth, android_client_ids: comma_google_android_client_ids
end

comma_google_electron_client_secret =
  SalixStore.ConfigJson.string(salix_config, ~w(comma google_auth electron_client_secret)) ||
    System.get_env("COMMA_GOOGLE_ELECTRON_CLIENT_SECRET")

if is_binary(comma_google_electron_client_secret) and comma_google_electron_client_secret != "" do
  config :comma_core, :google_auth, electron_client_secret: comma_google_electron_client_secret
end

signup_cap =
  SalixStore.ConfigJson.integer(salix_config, ~w(comma billing signup_credit_daily_cap_usd)) ||
    2_000

if signup_cap < 0, do: raise("comma.billing.signup_credit_daily_cap_usd must be nonnegative")
config :comma_core, signup_credit_daily_cap_usd: signup_cap

if domains =
     SalixStore.ConfigJson.get(salix_config, ~w(comma billing signup_credit_excluded_domains)) do
  unless is_list(domains) and Enum.all?(domains, &(is_binary(&1) and &1 != "")),
    do: raise("comma.billing.signup_credit_excluded_domains must be a list of domains")

  config :comma_core, signup_credit_excluded_domains: Enum.map(domains, &String.downcase/1)
end

# OAuth IdP key-encryption key (docs/identity-security.md, D3 as revised
# 2026-08-25): signing key pairs live in the shared comma_oauth_signing_keys
# table; this KEK (32 bytes, base64) only unwraps their encrypted private
# halves at read time. It arrives from the content-addressed comma-secrets
# Secret like every other Comma credential and participates in no rotation
# protocol. Absent KEK leaves the IdP unconfigured (valid while no IdP
# endpoint is routed); a malformed value fails the boot.
# Operator-owned identities that differ per deployment: the Google Workspace
# domain whose accounts may administer Comma, the support mailbox, the Stripe
# price lookup-key prefix, and the billing-account id prefix for new workspaces.
for {key, path} <- [
      admin_email_domain: ~w(comma admin email_domain),
      support_email: ~w(comma email support),
      stripe_lookup_key_prefix: ~w(comma billing stripe_lookup_key_prefix),
      billing_account_prefix: ~w(comma billing account_prefix)
    ],
    value = SalixStore.ConfigJson.string(salix_config, path),
    is_binary(value) and value != "" do
  config :comma_core, [{key, value}]
end

case System.get_env("COMMA_OAUTH_IDP_KEK") do
  nil ->
    :ok

  "" ->
    :ok

  encoded ->
    case Base.decode64(encoded) do
      {:ok, kek} when byte_size(kek) == 32 ->
        config :comma_core, :oauth_idp, kek: kek

      _other ->
        raise "COMMA_OAUTH_IDP_KEK must be exactly 32 bytes, base64-encoded"
    end
end

if :comma_product in enabled do
  comma_profile_avatar_bucket =
    System.get_env("COMMA_PROFILE_AVATAR_BUCKET") ||
      SalixStore.ConfigJson.string(salix_config, ~w(comma profile_avatar bucket)) ||
      if(comma_environment == "local", do: "comma-user-avatar-dev")

  # Hosted bucket names are live GCS resources and come from the environment's
  # configuration. Production must never write avatars into a staging or dev bucket.
  if comma_environment in ["staging", "production", "prod"] and
       not (is_binary(comma_profile_avatar_bucket) and comma_profile_avatar_bucket != "") do
    raise "Comma profile avatars need comma.profile_avatar.bucket in #{comma_environment}"
  end

  if comma_environment in ["production", "prod"] and is_binary(comma_profile_avatar_bucket) and
       String.match?(comma_profile_avatar_bucket, ~r/(^|[-_.])(staging|dev)([-_.]|$)/) do
    raise "production Comma profile avatars cannot use the non-production bucket #{comma_profile_avatar_bucket}"
  end

  comma_profile_avatar_config =
    if comma_environment in ["local", "selfhost"] do
      [
        adapter: Comma.ProfileAvatar.Storage.S3,
        bucket: comma_profile_avatar_bucket,
        endpoint:
          System.get_env("COMMA_PROFILE_AVATAR_S3_ENDPOINT") ||
            SalixStore.ConfigJson.string(salix_config, ~w(storage endpoint)) ||
            "http://127.0.0.1:19000",
        region:
          System.get_env("COMMA_PROFILE_AVATAR_S3_REGION") ||
            SalixStore.ConfigJson.string(salix_config, ~w(storage region)) || "us-east-1",
        access_key_id:
          System.get_env("COMMA_PROFILE_AVATAR_S3_ACCESS_KEY_ID") ||
            SalixStore.ConfigJson.string(salix_config, ~w(storage access_key_id)) ||
            "minioadmin",
        secret_access_key:
          System.get_env("COMMA_PROFILE_AVATAR_S3_SECRET_ACCESS_KEY") ||
            SalixStore.ConfigJson.string(salix_config, ~w(storage secret_access_key)) ||
            "minioadmin"
      ]
    else
      [adapter: Comma.ProfileAvatar.Storage.GCS, bucket: comma_profile_avatar_bucket]
    end

  config :comma_core, :profile_avatar, comma_profile_avatar_config

  comma_auth_secret =
    case SalixStore.ConfigJson.string(salix_config, ~w(comma auth secret)) do
      value when is_binary(value) -> String.trim(value)
      nil -> nil
    end

  comma_rate_limit_secret =
    case SalixStore.ConfigJson.string(salix_config, ~w(comma auth rate_limit_secret)) do
      value when is_binary(value) -> String.trim(value)
      nil -> nil
    end

  comma_redis_url =
    SalixStore.ConfigJson.string(salix_config, ~w(comma auth redis_url)) ||
      System.get_env("COMMA_REDIS_URL")

  comma_login_from = SalixStore.ConfigJson.string(salix_config, ~w(comma email from))

  comma_postmark_token =
    SalixStore.ConfigJson.string(salix_config, ~w(email postmark_server_token))

  if comma_environment == "selfhost" do
    config :comma_core, :auth,
      auto_create_users:
        SalixStore.ConfigJson.boolean(salix_config, ~w(comma auth auto_create_users)) == true

    config :comma_core,
           :selfhost_owner_email,
           SalixStore.ConfigJson.string(salix_config, ~w(comma selfhost owner_email))
  end

  comma_email_provider =
    SalixStore.ConfigJson.string(salix_config, ~w(comma email provider)) ||
      if(local_comma_environment?, do: "smtp", else: "postmark")

  unless comma_email_provider in ["smtp", "postmark"],
    do: raise("comma.email.provider must be smtp or postmark")

  if comma_email_provider == "smtp" do
    smtp = SalixStore.ConfigJson.get(salix_config, ~w(comma email smtp)) || %{}
    tls = Map.get(smtp, "tls", if(local_comma_environment?, do: "never", else: "always"))
    unless tls in ["always", "never"], do: raise("comma.email.smtp.tls must be always or never")

    if Map.get(smtp, "username", "") != "" and tls == "never" and
         Map.get(smtp, "ssl", false) != true do
      raise "Authenticated SMTP requires TLS or SSL"
    end

    config :comma_core, :mail,
      host: Map.get(smtp, "host", "localhost"),
      port: Map.get(smtp, "port", 1025),
      username: Map.get(smtp, "username", ""),
      password: Map.get(smtp, "password", ""),
      tls: if(tls == "always", do: :always, else: :never),
      ssl: Map.get(smtp, "ssl", false)
  end

  if not local_comma_environment? do
    required_email =
      if comma_email_provider == "postmark",
        do: [{comma_postmark_token, "email.postmark_server_token"}],
        else: []

    for {value, path} <-
          required_email ++
            [
              {comma_auth_secret, "comma.auth.secret"},
              {comma_rate_limit_secret, "comma.auth.rate_limit_secret"},
              {comma_redis_url, "comma.auth.redis_url"},
              {comma_login_from, "comma.email.from"}
            ] do
      if not is_binary(value) or String.trim(value) == "" do
        raise "#{path} is required for production Comma email authentication"
      end
    end

    if byte_size(comma_auth_secret) < 32 or byte_size(comma_rate_limit_secret) < 32 do
      raise "comma.auth secrets must each contain at least 32 bytes"
    end

    if comma_auth_secret == comma_rate_limit_secret do
      raise "comma.auth.secret and comma.auth.rate_limit_secret must be different"
    end

    redis_uri = URI.parse(comma_redis_url)

    if redis_uri.scheme not in ["redis", "rediss"] or not is_binary(redis_uri.host) or
         redis_uri.host == "" do
      raise "comma.auth.redis_url must be an absolute redis:// or rediss:// URL"
    end
  end

  comma_auth_runtime =
    [
      secret: comma_auth_secret,
      rate_limit_secret: comma_rate_limit_secret,
      redis_url: comma_redis_url
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

  comma_auth_runtime =
    if config_env() == :prod do
      [
        challenge_store: Comma.AuthChallengeStore.Redis,
        email_delivery:
          if(comma_email_provider == "smtp",
            do: Comma.EmailDelivery.SMTP,
            else: Comma.EmailDelivery.Postmark
          ),
        expose_codes: false
      ] ++ comma_auth_runtime
    else
      comma_auth_runtime
    end

  config :comma_core, :auth, comma_auth_runtime

  if is_binary(comma_login_from) do
    config :comma_core, :mail, from: comma_login_from
  end

  if is_binary(comma_postmark_token) do
    # Comma-only pods do not execute the Salix app-env mapping below, but the
    # shared Postmark adapter still owns this provider credential.
    config :salix_store, postmark_server_token: comma_postmark_token
  end
end

if is_binary(billing_database_url) do
  config :billing_core,
    ecto_repos: [BillingCore.Repo],
    start_repo: true,
    repo: BillingCore.Repo,
    typed_sink: SalixAnalytics.Sink.Noop,
    llm_typed_sink: SalixAnalytics.Sink.Noop,
    charge_typed_sink: SalixAnalytics.Sink.Noop,
    fee_control_typed_sink: SalixAnalytics.Sink.Noop

  config :billing_commerce,
    repo: BillingCore.Repo,
    cycle_scheduler_enabled: config_env() != :test,
    cycle_scheduler: [interval_ms: 60_000, limit: 50]

  config :salix_agent,
    llm_metering_mod: BillingCore.LLMMetering

  config :salix_web, vm_metering_mod: BillingCore.ResourceMetering
  config :salix_voice, metering_mod: BillingCore.VoiceMetering
  config :salix_store, storage_metering_mod: BillingCore.ResourceMetering

  config :billing_stripe,
    repo: BillingCore.Repo,
    secret_key: SalixStore.ConfigJson.string(salix_config, ~w(billing stripe secret_key)),
    webhook_secret: SalixStore.ConfigJson.string(salix_config, ~w(billing stripe webhook_secret)),
    portal_configuration_id:
      SalixStore.ConfigJson.string(salix_config, ~w(billing stripe portal_configuration_id))

  if SalixStore.ConfigJson.boolean(salix_config, ~w(billing stripe force_http1)) == true do
    config :stripity_stripe,
      hackney_opts: [protocols: [:http1]]
  end

  config :billing_core, BillingCore.Repo,
    url: billing_database_url,
    pool_size: SalixStore.ConfigJson.integer(salix_config, ~w(billing database pool_size)) || 10
end

# ====================== Salix subsystem ======================
#
# willow-style config.json (SalixStore.ConfigJson): one structured JSON file —
# `/etc/salix/config.json` when present — applied here at boot, in every env.
# See config/config.example.json for the sections.
if :salix in enabled do
  merged = SalixStore.ConfigJson.app_env(salix_config)

  for {app, key, value} <- merged do
    config app, [{key, value}]
  end

  # Control-plane Postgres repo (docs/storage-search.md).
  # Tenant API keys are served from it, so a salix-capable prod node without
  # the DSN cannot authenticate tenant requests — fail the boot loudly.
  salix_database_url =
    if config_env() != :test do
      SalixStore.ConfigJson.string(salix_config, ~w(salix database url)) ||
        (config_env() == :prod and
           raise "salix.database.url is required for the salix subsystem")
    end

  if is_binary(salix_database_url) do
    salix_pool_size =
      if System.get_env("COMMA_RELEASE_JOB") == "1" do
        2
      else
        SalixStore.ConfigJson.integer(salix_config, ~w(salix database pool_size)) || 8
      end

    config :salix_store,
      ecto_repos: [SalixStore.Repo],
      start_repo: true

    config :salix_store, SalixStore.Repo,
      url: salix_database_url,
      pool_size: salix_pool_size
  end

  # Browser OAuth starts in the Bridge for Teams dashboard but completes on
  # Salix's callback listener. Keep the cross-origin return explicit and
  # configuration-backed so remote MCP OAuth never becomes an open redirect.
  if is_binary(bridge_public_base_url) do
    config :salix_web, oauth_return_base_urls: [bridge_public_base_url]
  end

  # Per-pod advertise host is derived from Kubernetes status.podIP and cannot be
  # represented by the shared config secret.
  if advertise_host = System.get_env("SALIX_ADVERTISE_HOST") do
    config :salix_env, advertise_host: advertise_host
  end

  lookup = fn app, key ->
    Enum.find_value(merged, fn {a, k, v} -> if a == app and k == key, do: v end)
  end

  # Derived/structured settings -------------------------------------------

  # Salix cluster discovery uses Kubernetes headless-service DNS or gossip.
  case lookup.(:salix_cluster, :strategy) do
    "kubernetes_dns" ->
      service =
        lookup.(:salix_cluster, :k8s_headless_service) ||
          raise "cluster.k8s_headless_service is required with kubernetes_dns"

      config :salix_cluster,
        topologies: [
          salix: [
            strategy: Cluster.Strategy.Kubernetes.DNS,
            config: [service: service, application_name: "salix"]
          ]
        ]

    "gossip" ->
      config :salix_cluster, topologies: [salix: [strategy: Cluster.Strategy.Gossip]]

    _ ->
      :ok
  end

  # IM provider public base URL. SalixIM builds the Slack/Feishu webhook,
  # OAuth-callback, and App-Manifest URLs from `:salix_im, :public_base_url`,
  # which must match the externally-reachable Salix API host that serves
  # `/v1/im/*` (config.json `web.api_base_url` → `:salix_web, :public_base_url`).
  # The salix_web router keeps it fresh on IM requests, but the BridgeForTeams
  # dashboard builds the Slack manifest over `:erpc` — bypassing that lazy sync —
  # so seed it here at boot to avoid the `http://127.0.0.1:4000` fallback.
  if im_base = lookup.(:salix_web, :public_base_url) do
    config :salix_im, public_base_url: im_base
  end

  # Concurrency bound for the IM identity fallback scan: unknown app_ids
  # walk the whole connect prefix, and the webhook routes reach that walk
  # pre-authentication, so requests over the bound get a retryable 503
  # instead of stacking more full-prefix scans. Default 4 (in code); see
  # docs/identity-security.md.
  if im_scan_cap =
       SalixStore.ConfigJson.integer(salix_config, ~w(im identity_scan_max_concurrency)) do
    config :salix_im, identity_scan_max_concurrency: im_scan_cap
  end

  # Encrypted agent event archive — needs BOTH age recipients and a ClickHouse
  # endpoint. Only PUBLIC keys appear here; no private half is ever configured,
  # which is what makes the archive write-only from the cluster's side.
  # docs/observability.md
  archive_recipients =
    case SalixStore.ConfigJson.get(salix_config, ~w(archive agent_events recipients)) do
      list when is_list(list) ->
        Enum.map(list, fn entry ->
          %{key_id: entry["key_id"], public_key: entry["public_key"]}
        end)

      _ ->
        []
    end

  archive_enabled? =
    archive_recipients != [] and
      SalixStore.ConfigJson.boolean(salix_config, ~w(archive agent_events enabled)) != false

  # Recipients without a ClickHouse endpoint is a misconfiguration that would
  # otherwise fail QUIETLY and expensively: every sealed row would be buffered
  # and then dropped. Refusing to enable the archive and saying so is the honest
  # outcome — the loop is unaffected either way.
  if archive_enabled? and is_nil(lookup.(:salix_analytics, :clickhouse_url)) do
    IO.warn(
      "archive.agent_events has recipients but no ClickHouse endpoint is configured; " <>
        "the encrypted agent event archive stays DISABLED",
      []
    )
  end

  if archive_enabled? and not is_nil(lookup.(:salix_analytics, :clickhouse_url)) do
    config :salix_analytics,
      event_archive: [
        enabled: true,
        recipients: archive_recipients,
        # Batching is load-bearing against ClickHouse, not just an optimization:
        # every INSERT creates a part, and single-row inserts at loop frequency
        # bury the merge scheduler.
        batch_size:
          SalixStore.ConfigJson.integer(salix_config, ~w(archive agent_events batch_size)) || 200,
        flush_ms:
          SalixStore.ConfigJson.integer(salix_config, ~w(archive agent_events flush_ms)) || 2_000,
        max_buffer:
          SalixStore.ConfigJson.integer(salix_config, ~w(archive agent_events max_buffer)) ||
            5_000,
        batch_bytes:
          SalixStore.ConfigJson.integer(salix_config, ~w(archive agent_events batch_bytes)) ||
            4_194_304
      ]

    config :salix_agent, event_archive_mod: SalixAnalytics.EventArchive
  end

  # Analytics ClickHouse sink — enabled when a URL is configured.
  if ch = lookup.(:salix_analytics, :clickhouse_url) do
    clickhouse_database = lookup.(:salix_analytics, :clickhouse_database)
    typed_database = lookup.(:salix_analytics, :clickhouse_typed_database) || clickhouse_database

    config :salix_analytics,
      sink: SalixAnalytics.Sink.ClickHouse,
      typed_sink: SalixAnalytics.Sink.ClickHouseTyped,
      typed_sink_worker: true,
      metering_enabled: true,
      clickhouse: [
        base_url: ch,
        table: lookup.(:salix_analytics, :clickhouse_table) || "salix_analytics.events",
        database: clickhouse_database,
        typed_database: typed_database,
        user: lookup.(:salix_analytics, :clickhouse_user),
        password: lookup.(:salix_analytics, :clickhouse_password)
      ]

    # Activation follows the deployment environment, never a JSON toggle.
    # Missing connection credentials fail semantic calls, not Comma startup.
    config :salix_im, slack_semantic_reader: SalixAnalytics.SlackSemanticIndex
    config :salix_im, slack_message_search_reader: SalixAnalytics.SlackMessageSearch
    config :salix_analytics, slack_semantic_file_source: SalixIM.SlackSemanticFiles
    config :salix_analytics, slack_semantic_scope_source: SalixIM.SlackSemanticScopes

    config :salix_analytics,
      slack_semantic_search: [
        environment: comma_environment,
        url: SalixStore.ConfigJson.string(salix_config, ~w(slack_semantic_search url)),
        client_id:
          SalixStore.ConfigJson.string(salix_config, ~w(slack_semantic_search client_id)),
        client_secret:
          SalixStore.ConfigJson.string(salix_config, ~w(slack_semantic_search client_secret))
      ]

    # Slack message mirror. Default on wherever ClickHouse is configured.
    # `slack_mirror.enabled: false` is the kill switch. Tenant/channel
    # coverage is still the bot's membership. Design: docs/tools-integrations.md
    slack_mirror_enabled? =
      SalixStore.ConfigJson.boolean(salix_config, ~w(slack_mirror enabled)) != false

    config :salix_analytics,
      slack_mirror: [
        # Largest single INSERT into ClickHouse. Batching is load-bearing:
        # every INSERT creates a part, and a busy workspace's message rate
        # would bury the merge scheduler in single-row parts.
        batch_size:
          SalixStore.ConfigJson.integer(salix_config, ~w(slack_mirror batch_size)) || 200
      ]

    # Triage already reads ClickHouse independently of the mirror enable gate.
    config :salix_im,
      slack_triage_clickhouse_reader_mod: SalixAnalytics.SlackMirror.Reader

    if slack_mirror_enabled? do
      config :salix_im, slack_message_mirror_mod: SalixAnalytics.SlackMirror
    end

    config :salix_im,
      slack_triage_clickhouse_patrol: [],
      slack_message_mirror_outbox_drainer: [
        batch_size:
          SalixStore.ConfigJson.integer(salix_config, ~w(slack_mirror outbox batch_size)) || 200,
        # How often an idle Pod looks for rows; also the live path's latency.
        drain_ms:
          SalixStore.ConfigJson.integer(salix_config, ~w(slack_mirror outbox drain_ms)) || 2_000
      ],
      slack_message_mirror_backfill: [
        # One Slack request per this many milliseconds per installation.
        # conversations.history is special-tier (~50+/min per workspace+bot).
        # 1.5s is ~40/min, more than half of that budget, with room left for
        # live tool calls. Retry-After is still the ceiling.
        pace_ms:
          SalixStore.ConfigJson.integer(salix_config, ~w(slack_mirror backfill pace_ms)) || 1_500,
        # Installations walked at once on one Pod. Each is a separate Slack
        # budget, so this is parallelism, not pressure on one token.
        max_concurrent_passes:
          SalixStore.ConfigJson.integer(
            salix_config,
            ~w(slack_mirror backfill max_concurrent_passes)
          ) ||
            4,
        # How far back to index, as a Slack ts in microseconds. 0 means to the
        # beginning of every channel; lowering it later resumes the walk.
        floor_ts_us:
          SalixStore.ConfigJson.integer(salix_config, ~w(slack_mirror backfill floor_ts_us)) || 0,
        # How often a fully indexed installation is revisited. A channel join
        # and going live kick due now; this is the idle revisit, not discovery.
        pass_interval_ms:
          SalixStore.ConfigJson.integer(salix_config, ~w(slack_mirror backfill pass_interval_ms)) ||
            3_600_000
      ]

    config :billing_core,
      typed_sink: SalixAnalytics.TypedSinkWorker,
      llm_typed_sink: SalixAnalytics.TypedSinkWorker,
      charge_typed_sink: SalixAnalytics.TypedSinkWorker,
      fee_control_typed_sink: SalixAnalytics.TypedSinkWorker,
      agent_observability_typed_sink: SalixAnalytics.TypedSinkWorker,
      agent_observability_typed_sink_server: SalixAnalytics.AgentObservabilitySinkWorker

    config :salix_agent,
      agent_observability_mod: BillingCore.AgentObservability

    config :bridge_for_teams_core,
      storage_metering: [
        enabled: true,
        interval_ms:
          SalixStore.ConfigJson.integer(salix_config, ~w(billing storage_metering interval_ms)) ||
            3_600_000,
        sample_window_seconds:
          SalixStore.ConfigJson.integer(
            salix_config,
            ~w(billing storage_metering sample_window_seconds)
          ) || 3_600,
        provider:
          SalixStore.ConfigJson.string(salix_config, ~w(billing storage_metering provider)) ||
            "gcs",
        sku:
          SalixStore.ConfigJson.string(salix_config, ~w(billing storage_metering sku)) ||
            "regional",
        storage_tier:
          SalixStore.ConfigJson.string(salix_config, ~w(billing storage_metering storage_tier)) ||
            "regional",
        max_objects:
          SalixStore.ConfigJson.integer(salix_config, ~w(billing storage_metering max_objects)) ||
            25_000
      ]
  end

  if config_env() != :test do
    # Router IM tools (`im.connects_list`, `im.provider_apis_list`, and dynamic
    # `im_api.*` operations). The provider backend lives in the independent IM
    # domain; salix_agent reaches it through this runtime seam.
    config :salix_agent, im_provider_mod: SalixIM.Provider

    # Information-flow facts (docs/verification.md).
    # Labels, membership and placements are provider facts, so salix_agent
    # reaches them through this seam instead of depending on the IM domain.
    # Every Group is `off` until its control record opts in.
    config :salix_agent, ifc_facts_mod: SalixIM.IFC.Facts

    # Manual meeting intent is owned by the Router's meeting.join tool. Keep
    # the legacy provider interceptor unconfigured so Slack and Feishu human
    # messages always continue through normal Router ingress.
    config :salix_im, meeting_provider_handler: nil

    meeting_runtime_url = lookup.(:salix_meet, :runtime_base_url)
    meeting_driver_mode = lookup.(:salix_meet, :runtime_driver_mode)

    salix_meet_config = [
      provider_mod: SalixMeet.ProviderDispatcher,
      delivery: [],
      # Kept for diagnostics: the effective driver below is derived with
      # runtime_url taking precedence, and the raw mode lets boot-time and
      # status checks surface a runtime_url/driver conflict.
      runtime_driver_mode: meeting_driver_mode
    ]

    salix_meet_config =
      cond do
        is_binary(meeting_runtime_url) and String.trim(meeting_runtime_url) != "" ->
          salix_meet_config ++
            [
              runtime_driver: SalixMeet.RuntimeDriver.HTTP,
              runtime_base_url: meeting_runtime_url
            ]

        is_binary(meeting_driver_mode) and String.trim(meeting_driver_mode) == "connector" ->
          salix_meet_config ++ [runtime_driver: SalixMeet.RuntimeDriver.SalixConnect]

        true ->
          salix_meet_config
      end

    config :salix_meet, salix_meet_config
  end

  # Admin dashboard endpoint (LiveView under /dash, shared listener). `server`
  # stays false in all envs — SalixWeb.Endpoint invokes it as a plug. In prod a
  # real secret_key_base is required (signs the admin session cookie). The
  # endpoint :url is the externally-reachable base URL (config.json
  # `web.api_base_url` → `:salix_web, :public_base_url`), so the LiveView
  # websocket origin check passes in prod; outside prod it is relaxed
  # (`check_origin: false`) since the listener is reached via 127.0.0.1.
  dash_secret =
    lookup.(:salix_web, :dashboard_secret_key_base) ||
      (config_env() == :prod and
         raise "salix_dashboard.secret_key_base is required for the admin dashboard endpoint")

  dash_url_config =
    case lookup.(:salix_web, :public_base_url) |> then(&(&1 && URI.parse(&1))) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        [url: [scheme: scheme, host: host, port: uri.port || URI.default_port(scheme)]]

      _ ->
        []
    end

  config :salix_web,
         SalixWeb.DashboardEndpoint,
         [server: false] ++
           dash_url_config ++
           if(is_binary(dash_secret), do: [secret_key_base: dash_secret], else: []) ++
           if(config_env() != :prod, do: [check_origin: false], else: []) ++
           if(config_env() == :prod,
             do: [cache_static_manifest: "priv/static/cache_manifest.json"],
             else: []
           )

  # Prod hard requirements — validated on the effective config view. Only
  # enforced when Salix runs on this node.
  if config_env() == :prod do
    for {label, app, key} <- [
          {"storage.endpoint", :salix_store, :s3_endpoint},
          {"storage.bucket", :salix_store, :s3_bucket},
          {"storage.access_key_id", :salix_store, :s3_access_key_id},
          {"storage.secret_access_key", :salix_store, :s3_secret_access_key}
        ] do
      lookup.(app, key) || raise "required configuration missing: #{label}"
    end

    lookup.(:salix_web, :api_token) ||
      raise "required configuration missing: web.api_token"
  end
end

# ====================== BridgeForTeams subsystem ======================
#
# Config is loaded only when this node runs the bridge_for_teams subsystem (design
# §8). In :test the Repo + fakes come from config/test.exs, so this block does
# nothing there. S3 is reused from salix_store (already configured).
bridge_database_url =
  SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams database url)) ||
    (:bridge_for_teams in enabled and config_env() == :prod and
       raise "bridge_for_teams.database.url is required for the bridge_for_teams subsystem")

if config_env() != :test and is_binary(bridge_database_url) do
  config :bridge_for_teams_core, BridgeForTeams.Repo,
    url: bridge_database_url,
    pool_size:
      SalixStore.ConfigJson.integer(salix_config, ~w(bridge_for_teams database pool_size)) ||
        10
end

if :bridge_for_teams in enabled and config_env() != :test do
  if is_binary(bridge_database_url) do
    config :bridge_for_teams_core, BridgeForTeams.Repo,
      url: bridge_database_url,
      pool_size:
        SalixStore.ConfigJson.integer(salix_config, ~w(bridge_for_teams database pool_size)) ||
          10
  end

  # The sourced-context executor is BFT-owned and must also be configured on a
  # future BFT-only node. Today's colocated nodes receive the same tuple through
  # the Salix app-env mapping above; Config deep-merges the identical value.
  for {app, key, value} <- SalixStore.ConfigJson.sourced_context_env(salix_config),
      app == :bridge_for_teams_core do
    config app, [{key, value}]
  end

  # Public base URL (OIDC redirect URIs and the dashboard endpoint URL used by
  # Phoenix origin checks). Prefer the dashboard key; keep the old web key as a
  # compatibility fallback for existing config secrets.
  if base = bridge_public_base_url do
    config :bridge_for_teams_web, public_base_url: base
  end

  # Dashboard-hosted admin CLI installer. Prefer the product bft_cli section;
  # keep dashboard.* compatibility keys for one-off existing deployment config.
  if base_url =
       SalixStore.ConfigJson.string(
         salix_config,
         ~w(bridge_for_teams bft_cli artifact_base_url)
       ) ||
         SalixStore.ConfigJson.string(
           salix_config,
           ~w(bridge_for_teams dashboard bft_cli_artifact_base_url)
         ) do
    config :bridge_for_teams_web, bft_cli_artifact_base_url: String.trim_trailing(base_url, "/")
  end

  if release_id =
       SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams bft_cli release_id)) ||
         SalixStore.ConfigJson.string(
           salix_config,
           ~w(bridge_for_teams dashboard bft_cli_release_id)
         ) do
    config :bridge_for_teams_web, bft_cli_release_id: release_id
  end

  if artifact_url =
       SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams bft_cli artifact_url)) ||
         SalixStore.ConfigJson.string(
           salix_config,
           ~w(bridge_for_teams dashboard bft_cli_artifact_url)
         ) do
    config :bridge_for_teams_web, bft_cli_artifact_url: artifact_url
  end

  if sha256 =
       SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams bft_cli sha256)) ||
         SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams dashboard bft_cli_sha256)) do
    config :bridge_for_teams_web, bft_cli_sha256: sha256
  end

  # Dashboard LiveView endpoint (port 4101). Boots only in prod or when
  # bridge_for_teams.dashboard.server=true; needs a real secret_key_base in prod.
  dash_port =
    SalixStore.ConfigJson.integer(salix_config, ~w(bridge_for_teams dashboard port)) || 4101

  dash_secret =
    SalixStore.ConfigJson.string(salix_config, ~w(bridge_for_teams dashboard secret_key_base)) ||
      (config_env() == :prod and
         raise "bridge_for_teams.dashboard.secret_key_base is required for the dashboard endpoint")

  dash_server? =
    case SalixStore.ConfigJson.boolean(salix_config, ~w(bridge_for_teams dashboard server)) do
      nil -> config_env() == :prod
      value -> value
    end

  # Dev/e2e: the listener is reached via 127.0.0.1 while :url host is
  # "localhost", so the LiveView socket's origin check would 403. Relax it
  # outside prod; prod keeps Phoenix's default (checked against :url host).
  # Prod: serve the fingerprinted assets written by `mix phx.digest`
  # (assets.deploy) so ~p"/assets/*" resolves to digested, far-future-
  # cacheable URLs. Manifest path is relative to the app's priv/ in the
  # release; absent outside prod (no digest there).
  dash_url_config =
    case bridge_public_base_url && URI.parse(bridge_public_base_url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        [url: [scheme: scheme, host: host, port: uri.port || URI.default_port(scheme)]]

      _ ->
        []
    end

  dash_config =
    [
      http: [
        ip: {0, 0, 0, 0},
        port: dash_port,
        http_options: [log_exceptions_with_status_codes: 500..599, log_protocol_errors: false]
      ],
      server: dash_server?
    ] ++
      dash_url_config ++
      if(is_binary(dash_secret), do: [secret_key_base: dash_secret], else: []) ++
      if(config_env() != :prod, do: [check_origin: false], else: []) ++
      if(config_env() == :prod,
        do: [cache_static_manifest: "priv/static/cache_manifest.json"],
        else: []
      )

  config :bridge_for_teams_web, BridgeForTeamsWeb.DashboardEndpoint, dash_config

  if slug =
       SalixStore.ConfigJson.string(
         salix_config,
         ~w(bridge_for_teams dashboard impersonator_org_slug)
       ) do
    config :bridge_for_teams_web, impersonator_org_slug: slug
  end

  # Dev/e2e-only login bypass (browser end-to-end tests). NEVER honored in prod:
  # the gate is both config_env() and an explicit config value, and the
  # controller 404s when the flag is off. Used by the Playwright suite to obtain
  # a real session without driving an external IdP.
  if config_env() != :prod and
       SalixStore.ConfigJson.boolean(salix_config, ~w(bridge_for_teams dashboard dev_login)) ==
         true do
    config :bridge_for_teams_web, dev_login: true

    # Dev-login bypasses only the external IdP; Salix remains real. Browser SSO
    # smokes can still drive callback/session behavior through provider fakes.
    config :bridge_for_teams_core,
      oidc_provider: BridgeForTeams.Auth.OIDC.Fake,
      feishu_provider: BridgeForTeams.Auth.Feishu.Fake
  end
end

subscription_key =
  SalixStore.ConfigJson.string(salix_config, ~w(subscription_proxy storage_key)) ||
    System.get_env("SALIX_SUBSCRIPTION_STORAGE_KEY")

if subscription_key do
  config :salix_agent, :subscription_storage_key, Base.decode64!(subscription_key)
end

# Kubernetes injects COMMA_SSH_PORT for the comma-ssh Service as a tcp:// URL.
# Use a distinct application setting, and ignore it on non-product nodes.
if :comma_product in enabled do
  if port = System.get_env("COMMA_SSH_LISTEN_PORT") do
    config :comma_ssh, port: String.to_integer(port)
  end
end
