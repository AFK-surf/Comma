defmodule SalixStore.ConfigJson do
  @moduledoc """
  willow-style `config.json` loading (mirrors `pkg/config`: one structured
  JSON file, sectioned by domain).

  Resolution (`resolve_path/1`): `SALIX_CONFIG_PATH` when explicitly set →
  `/etc/salix/config.json` → `config.json` when present → none. Runtime values
  come from the file only; absent values are omitted and downstream defaults
  apply. Per-pod BEAM/Kubernetes values such as `RELEASE_NODE` and pod advertise
  host remain environment variables because they cannot be represented by one
  shared config file.

  Sections (see `config/config.example.json`):

      storage    endpoint, region, bucket, access_key_id, secret_access_key,
                 timeouts.{fast_recv_ms,bulk_recv_ms,budget_ms} (positive ms),
                 conditional_delete ("native" | "emulate"),
                 atomic_operations ("s3" | "gcp")
      log        file (JSONL diagnostic log path; default disabled)
      web        port, api_token, sites_domain, api_base_url
      transfer   port, advertise_host, advertise_port
      decide     api_key, endpoint, model (Jev-compatible decisions)
      search     exa_api_key                    (willow SearchConfig)
      email      postmark_server_token, owner_notification_from_email,
                 magic_link_from_email
                 (Postmark: agent owner notifications + BFT magic-link login)
      im         identity_scan_max_concurrency (hard bound on concurrent
                 identity fallback scans; over-bound webhook events get a
                 retryable 503; default 4)
      cluster    strategy ("kubernetes_dns" | "gossip"), k8s_headless_service
      clickhouse url, table, user, password     (willow ClickHouseConfig)
      slack_mirror enabled (default on; false disables ingest and backfill),
                 batch_size, outbox.*, backfill.*
      slack_semantic_search url, client_id, client_secret (connection settings only;
                 activation follows COMMA_ENVIRONMENT, off only in prod/production)
      billing   database.*, stripe.*, storage_metering.*
      comma        database.*, auth.{secret,rate_limit_secret,redis_url},
                 email.from,
                 web.{web_cookie_origin,admin_cookie_origin,allowed_origins},
                 google_auth.{web_client_id,electron_client_id,electron_client_secret},
                 synchronicity.{base_url,provisioning_secret}
      meetings   runtime_url (external meeting runtime), agent_template,
                 summary_template, asr_template, bot_name
                 (default in-meeting display name, fallback "Cirno"),
                 caption_language (fallback subtitle language when the
                 trigger text yields no inference; code default is
                 "Chinese, Mandarin (Simplified)"), calendar_autojoin.*
                 (explicitly enabled, bounded worker settings and a non-empty
                 list of tenant/group ownership pairs)
      salix_dashboard secret_key_base
      e2e_reports session_secret, r2.*
      bridge_for_teams database.*, bft_cli.*, dashboard.* (including
                       impersonator_org_slug; legacy web.public_base_url is
                       accepted), mac_mini.*,
                       sourced_context.background_executor.enabled
      agent_vmm multi_scope_registration_enabled (release gate; default false),
                environment_scoped_bindings_enabled (release gate; default false),
                managed_trust_signing.private_key,
                install_material.remote_enrollment.{gateway_endpoint,trust_bundle}
      vm          default_provider, providers.cloudflare.gateway_base_url,
                 providers.cloudflare.gateway_secret, providers.cloudflare.enabled

  `app_env/1` returns the `{app, key, value}` assignments for
  `config/runtime.exs` to apply. Unknown sections/keys are ignored so configs
  can carry forward-compatible entries — EXCEPT inside sections documented as
  fail-closed (`storage.timeouts`): there an unknown or malformed field
  refuses the load, because a silently inert incident-mitigation override is
  worse than a refused boot.
  """

  @default_paths ["/etc/salix/config.json", "config.json"]
  @config_path_env "SALIX_CONFIG_PATH"

  @calendar_autojoin_bounds [
    {:scan_interval_ms, "scan_interval_ms", 10_000, 3_600_000},
    {:join_interval_ms, "join_interval_ms", 30_000, 60_000},
    {:max_groups_per_pass, "max_groups_per_pass", 1, 100},
    {:max_events_per_group, "max_events_per_group", 1, 250},
    {:max_concurrency, "max_concurrency", 1, 16},
    {:task_timeout_ms, "task_timeout_ms", 1_000, 120_000}
  ]
  @calendar_autojoin_work_budget_ms 180_000
  @calendar_autojoin_max_calendars 10
  @calendar_autojoin_max_mentions 50
  @calendar_autojoin_defaults [
    scan_interval_ms: 120_000,
    join_interval_ms: 60_000,
    max_groups_per_pass: 25,
    max_events_per_group: 50,
    max_concurrency: 5,
    task_timeout_ms: 30_000
  ]

  @doc "Resolve the config file path; nil means empty/default config."
  @spec resolve_path([String.t()]) :: String.t() | nil
  def resolve_path(paths \\ @default_paths) when is_list(paths) do
    case System.get_env(@config_path_env) do
      path when is_binary(path) and path != "" -> path
      _ -> Enum.find(paths, &File.exists?/1)
    end
  end

  @doc "Load and decode the file. A missing path (nil) is an empty config."
  @spec load(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(nil), do: {:ok, %{}}

  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:ok, other} -> {:error, {:not_an_object, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The application-env assignments for file configuration.
  Absent values are omitted (defaults apply).
  """
  @spec app_env(map()) :: [{atom(), atom(), term()}]
  def app_env(json) do
    base =
      [
        # storage (salix_store)
        {:salix_store, :s3_endpoint, str(json, ~w(storage endpoint))},
        {:salix_store, :s3_region, str(json, ~w(storage region))},
        {:salix_store, :s3_bucket, str(json, ~w(storage bucket))},
        {:salix_store, :s3_access_key_id, str(json, ~w(storage access_key_id))},
        {:salix_store, :s3_secret_access_key, str(json, ~w(storage secret_access_key))},
        {:salix_store, :s3_conditional_delete,
         case str(json, ~w(storage conditional_delete)) do
           "emulate" -> :emulate
           "native" -> :native
           nil -> nil
         end},
        {:salix_store, :s3_atomic_operations,
         case str(json, ~w(storage atomic_operations)) do
           "gcp" -> :gcp
           "s3" -> :s3
           nil -> nil
         end},
        {:salix_store, :s3_timeouts, s3_timeouts(json)},
        {:salix_agent, :decide, decide_config(json)},

        # logging (salix_store) — JSONL diagnostic log path; absent = disabled
        {:salix_store, :log_file, str(json, ~w(log file))},

        # Agent VMM registration index contract gate. It remains absent/false
        # through compatible-writer, scoped-index expand, and legacy-index
        # contract rollouts. Product multi-scope attach is enabled only after
        # every old writer and the legacy uniqueness fence are gone.
        {:salix_store, :agent_vmm_multi_scope_registration_enabled,
         boolean(json, ~w(agent_vmm multi_scope_registration_enabled))},
        # Mixed-version rollout gate for Environment-scoped Agent VMM
        # bindings. Keep false while an old writer can still create an
        # unscoped binding; enable only after all writers are current and the
        # unscoped-row preflight is empty.
        {:salix_store, :agent_vmm_environment_scoped_bindings_enabled,
         boolean(json, ~w(agent_vmm environment_scoped_bindings_enabled))},
        {:salix_store, :agent_vmm_managed_trust_signing,
         SalixStore.AgentVMMManagedTrustSigning.from_json(
           json_get(json, ~w(agent_vmm managed_trust_signing))
         )},
        {:salix_store, :agent_vmm_install_material, object(json, ~w(agent_vmm install_material))},

        # web (salix_web)
        {:salix_web, :port, int(json, ~w(web port))},
        {:salix_web, :api_token, str(json, ~w(web api_token))},
        # Externally reachable base URL (willow's server.api_base_url): cloud-VM
        # install links + connector dial-back.
        {:salix_web, :public_base_url, json_get(json, ~w(web api_base_url))},
        {:salix_web, :e2e_reports_session_secret, str(json, ~w(e2e_reports session_secret))},

        # sites (salix_agent — willow server.sites_domain): the wildcard domain
        # for agent-hosted websites. The agent runtime needs it too (system
        # prompt URL template + publish_html_preview), so it lives on salix_agent.
        {:salix_agent, :sites_domain, str(json, ~w(web sites_domain))},
        # Port carried in synthesized LOCAL (http) site URLs — dev serves
        # `*.localhost` sites on salix_web's port, not 80.
        {:salix_agent, :sites_port, int(json, ~w(web sites_port))},

        # transfer (salix_env)
        {:salix_env, :transfer_port, int(json, ~w(transfer port))},
        {:salix_env, :advertise_host, str(json, ~w(transfer advertise_host))},
        {:salix_env, :advertise_port, int(json, ~w(transfer advertise_port))},

        # search (salix_agent tools)
        {:salix_agent, :exa_api_key, str(json, ~w(search exa_api_key))},

        # email (Postmark): one shared server token (SalixStore.Postmark);
        # each sender has its own From address.
        {:salix_store, :postmark_server_token, str(json, ~w(email postmark_server_token))},
        {:salix_agent, :owner_notification_from_email,
         str(json, ~w(email owner_notification_from_email))},
        {:bridge_for_teams_core, :magic_link_from_email,
         str(json, ~w(email magic_link_from_email))},

        # cluster (salix_cluster)
        {:salix_cluster, :strategy, str(json, ~w(cluster strategy))},
        {:salix_cluster, :k8s_headless_service, str(json, ~w(cluster k8s_headless_service))},

        # analytics (salix_analytics)
        {:salix_analytics, :clickhouse_url, str(json, ~w(clickhouse url))},
        {:salix_analytics, :clickhouse_table, str(json, ~w(clickhouse table))},
        {:salix_analytics, :clickhouse_user, str(json, ~w(clickhouse user))},
        {:salix_analytics, :clickhouse_password, str(json, ~w(clickhouse password))},

        # meetings (salix_meet)
        {:salix_meet, :runtime_base_url, str(json, ~w(meetings runtime_url))},
        {:salix_meet, :runtime_driver_mode, str(json, ~w(meetings driver))},
        {:salix_meet, :agent_template, str(json, ~w(meetings agent_template))},
        {:salix_web, :meeting_summary_template, str(json, ~w(meetings summary_template))},
        {:salix_meet, :default_bot_name, str(json, ~w(meetings bot_name))},
        {:salix_meet, :default_caption_language, str(json, ~w(meetings caption_language))},
        {:salix_meet, :meeting_feishu_activation_enabled,
         boolean(json, ~w(meetings feishu_action_activation_enabled))},
        {:salix_web, :meeting_asr_template, str(json, ~w(meetings asr_template))},

        # Salix admin dashboard
        {:salix_web, :dashboard_secret_key_base, str(json, ~w(salix_dashboard secret_key_base))},

        # VM providers. Comma consumes the product-level VM config directly.
        # SalixWeb keeps the same config for tenants that explicitly opt in to
        # platform-managed VM; BFT organizations do not inherit it by default.
        {:comma_core, :salix_vm, vm_config(json)},
        {:salix_web, :platform_vm, vm_config(json)},
        {:salix_web, :cloud_vm_archive_r2, cloud_vm_archive_r2(json)},
        {:salix_env, :cloudflare_vm_gateway, cloudflare_vm_gateway(json)}
      ]

    base
    |> Kernel.++(r2_env(json))
    |> Kernel.++(calendar_autojoin_env(json))
    |> Kernel.++(sourced_context_env(json))
    |> Kernel.++(trajectory_eval_env(json))
    |> Enum.reject(fn {_app, _key, value} -> is_nil(value) end)
  end

  defp decide_config(json) do
    case json_get(json, ["decide"]) do
      %{} = section ->
        # Preserve invalid explicit values so the capability rejects them.
        for key <- [:api_key, :endpoint, :model],
            Map.has_key?(section, Atom.to_string(key)),
            do: {key, Map.get(section, Atom.to_string(key))}

      _ ->
        []
    end
  end

  @doc "Read a value from a nested config path."
  @spec get(map(), [String.t()]) :: term()
  def get(json, path), do: json_get(json, path)

  @doc "Read a string value from a nested config path."
  @spec string(map(), [String.t()]) :: String.t() | nil
  def string(json, path), do: str(json, path)

  @doc "Read an integer value from a nested config path."
  @spec integer(map(), [String.t()]) :: integer() | nil
  def integer(json, path), do: int(json, path)

  @doc "Read a boolean value from a nested config path."
  @spec boolean(map(), [String.t()]) :: boolean() | nil
  def boolean(json, path) do
    case json_get(json, path) do
      v when is_boolean(v) -> v
      "true" -> true
      "false" -> false
      nil -> nil
    end
  end

  @synchronicity_fields ~w(base_url provisioning_secret)

  @doc """
  App env for Comma's Synchronicity provisioning integration.

  The integration is disabled only when the entire section is absent. Once the
  section exists it is one fail-closed unit: both an origin and a secret are
  required, unknown fields are rejected, and the secret must contain at least
  32 bytes. HTTPS is required outside literal loopback development origins.
  """
  @spec synchronicity_env(map()) :: [{:comma_core, :synchronicity, keyword()}]
  def synchronicity_env(json) do
    case synchronicity_section(json) do
      :absent ->
        []

      {:present, %{} = section} ->
        validate_synchronicity_fields!(section)

        base_url = normalize_synchronicity_base_url!(Map.get(section, "base_url"))
        secret = validate_synchronicity_secret!(Map.get(section, "provisioning_secret"))

        [
          {:comma_core, :synchronicity, [base_url: base_url, provisioning_secret: secret]}
        ]

      {:present, malformed} ->
        raise ArgumentError,
              "comma.synchronicity must be an object with base_url and provisioning_secret, " <>
                "got: #{inspect(malformed)}"
    end
  end

  # ---- value resolution: json path > nil ----

  defp synchronicity_section(%{"comma" => %{} = comma}) do
    case Map.fetch(comma, "synchronicity") do
      {:ok, section} -> {:present, section}
      :error -> :absent
    end
  end

  defp synchronicity_section(_json), do: :absent

  defp validate_synchronicity_fields!(section) do
    unknown = Map.keys(section) -- @synchronicity_fields

    cond do
      unknown != [] ->
        raise ArgumentError,
              "comma.synchronicity contains unknown fields #{inspect(Enum.sort(unknown))}; " <>
                "known fields: #{Enum.join(@synchronicity_fields, ", ")}"

      Map.keys(section) |> Enum.sort() != Enum.sort(@synchronicity_fields) ->
        raise ArgumentError,
              "comma.synchronicity requires both base_url and provisioning_secret"

      true ->
        :ok
    end
  end

  defp normalize_synchronicity_base_url!(value) when is_binary(value) do
    value = String.trim(value)

    case URI.new(value) do
      {:ok, uri} ->
        loopback_http? = uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"]

        if (uri.scheme == "https" or loopback_http?) and is_binary(uri.host) and
             uri.host != "" and uri.userinfo == nil and uri.query == nil and
             uri.fragment == nil and uri.path in [nil, "", "/"] do
          String.trim_trailing(value, "/")
        else
          invalid_synchronicity_base_url!(value)
        end

      {:error, _reason} ->
        invalid_synchronicity_base_url!(value)
    end
  end

  defp normalize_synchronicity_base_url!(value) do
    invalid_synchronicity_base_url!(value)
  end

  defp invalid_synchronicity_base_url!(value) do
    raise ArgumentError,
          "comma.synchronicity.base_url must be one HTTPS origin " <>
            "(literal loopback HTTP is allowed for development), got: #{inspect(value)}"
  end

  defp validate_synchronicity_secret!(value)
       when is_binary(value) and byte_size(value) >= 32,
       do: value

  defp validate_synchronicity_secret!(value) do
    detail = if is_binary(value), do: "#{byte_size(value)} bytes", else: inspect(value)

    raise ArgumentError,
          "comma.synchronicity.provisioning_secret must contain at least 32 bytes, " <>
            "got: #{detail}"
  end

  # storage.timeouts — the S3 adapter's incident-mitigation knobs
  # (SalixStore.S3.AWS: per-attempt receive-timeout tiers and the hard
  # whole-call budget), all positive integers in milliseconds. A fully
  # absent section (or an explicitly empty object) keeps the adapter
  # defaults; every other malformation fails the load. Fail-closed means
  # ALL of it: a non-object section (including null), an unknown field
  # (a typo would otherwise be a silently inert override), a non-integer
  # or non-positive value, and a value beyond the sanity ceiling — BEAM
  # timers reject huge integers at call time, so an over-ceiling value
  # would crash every store request instead of tuning it.
  @s3_timeout_fields %{
    "fast_recv_ms" => :fast_recv_ms,
    "bulk_recv_ms" => :bulk_recv_ms,
    "budget_ms" => :budget_ms
  }
  @s3_timeout_max_ms 86_400_000

  defp s3_timeouts(json) do
    storage = json_get(json, ~w(storage))

    if is_map(storage) and Map.has_key?(storage, "timeouts") do
      validate_s3_timeouts!(Map.fetch!(storage, "timeouts"))
    end
  end

  defp validate_s3_timeouts!(section) when not is_map(section) do
    raise ArgumentError,
          "storage.timeouts must be an object with millisecond fields " <>
            "(fast_recv_ms, bulk_recv_ms, budget_ms), got: #{inspect(section)}"
  end

  defp validate_s3_timeouts!(section) do
    case Map.keys(section) -- Map.keys(@s3_timeout_fields) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "storage.timeouts contains unknown fields #{inspect(unknown)}; " <>
                "known fields: #{Enum.join(Map.keys(@s3_timeout_fields), ", ")}"
    end

    timeouts =
      for {name, key} <- @s3_timeout_fields, Map.has_key?(section, name) do
        value = Map.fetch!(section, name)

        unless is_integer(value) and value > 0 and value <= @s3_timeout_max_ms do
          raise ArgumentError,
                "storage.timeouts.#{name} must be a positive integer of milliseconds " <>
                  "(at most #{@s3_timeout_max_ms}), got: #{inspect(value)}"
        end

        {key, value}
      end

    case timeouts do
      [] -> nil
      keyword -> keyword
    end
  end

  defp str(json, path) do
    case json_get(json, path) do
      nil -> nil
      "" -> nil
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp int(json, path) do
    case json_get(json, path) do
      nil -> nil
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
    end
  end

  # Deployment-wide trajectory-eval defaults. Only keys present in config.json
  # are emitted; Elixir Config deep-merges this partial keyword list into the
  # compile-time `:salix_agent, :trajectory_eval` list, so ops can flip e.g.
  # judge_enabled for the whole deployment without a code change. Per-tenant
  # overrides (the dashboard switch) still win over whatever default lands here.
  defp trajectory_eval_env(json) do
    kw =
      [
        enabled: boolean(json, ~w(trajectory_eval enabled)),
        sample_rate: num(json, ~w(trajectory_eval sample_rate)),
        judge_enabled: boolean(json, ~w(trajectory_eval judge_enabled)),
        judge_clean_sample_rate: num(json, ~w(trajectory_eval judge_clean_sample_rate)),
        judge_provider: str(json, ~w(trajectory_eval judge_provider))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    base = if kw == [], do: [], else: [{:salix_agent, :trajectory_eval, kw}]
    base ++ judge_providers_env(json)
  end

  # The judge-model allowlist (`SalixAgent.TrajectoryEval.JudgeProviders`). ops
  # add/remove selectable judge models here without a deploy; entries carry
  # api_key_env (a var NAME) rather than a secret. A whole-map REPLACE (not a
  # deep merge) — config.json is the source of truth for the allowlist when set.
  #
  # Only an ABSENT key preserves the compiled default. Anything explicitly
  # present replaces it: a map verbatim (`{}` = "nothing is selectable" — the
  # revocation statement), and a malformed value (a list, a string, `null`) as
  # `%{}`. This allowlist gates which paid models are callable, so a typo'd
  # revocation must fail CLOSED — treating it as absent would leave the old
  # allowlist live and selectable, which is exactly what the edit tried to end.
  defp judge_providers_env(json) do
    with %{} = json <- json,
         %{} = section <- Map.get(json, "trajectory_eval"),
         {:ok, providers} <- Map.fetch(section, "judge_providers") do
      case providers do
        %{} = providers -> [{:salix_agent, :trajectory_eval_judge_providers, providers}]
        _malformed -> [{:salix_agent, :trajectory_eval_judge_providers, %{}}]
      end
    else
      _ -> []
    end
  end

  defp num(json, path) do
    case json_get(json, path) do
      v when is_number(v) -> v
      v when is_binary(v) -> parse_num(v)
      _ -> nil
    end
  end

  @sourced_context_executor_keys ~w(enabled)

  @doc """
  App env for the sourced-context durable background executor.

  The executor is an operations-owned doorbell over PostgreSQL state. Enabling
  it does not enable Slack discovery, acquisition, model derivation, commit,
  grounding, or create an import run. Those remain independent launch gates.

  An absent section preserves the compile-time default. An explicit malformed
  section fails closed to `enabled: false`, including unknown keys, so a typo
  cannot silently leave the executor running.
  """
  @spec sourced_context_env(map()) :: [{atom(), atom(), term()}]
  def sourced_context_env(json) do
    case json_get(json, ~w(bridge_for_teams sourced_context background_executor)) do
      nil ->
        []

      %{} = section ->
        if Map.keys(section) -- @sourced_context_executor_keys == [] and
             is_boolean(Map.get(section, "enabled")) do
          [
            {:bridge_for_teams_core, BridgeForTeams.SlackHistoryOnboarding.Reconciler,
             enabled: Map.fetch!(section, "enabled")}
          ]
        else
          failed_closed_sourced_context_env()
        end

      _malformed ->
        failed_closed_sourced_context_env()
    end
  end

  defp failed_closed_sourced_context_env do
    [
      {:bridge_for_teams_core, BridgeForTeams.SlackHistoryOnboarding.Reconciler, enabled: false}
    ]
  end

  defp parse_num(v) do
    case Float.parse(v) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp r2_env(json) do
    r2 =
      [
        endpoint: str(json, ~w(e2e_reports r2 endpoint)),
        region: str(json, ~w(e2e_reports r2 region)),
        bucket: str(json, ~w(e2e_reports r2 bucket)),
        access_key_id: str(json, ~w(e2e_reports r2 access_key_id)),
        secret_access_key: str(json, ~w(e2e_reports r2 secret_access_key))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if r2 == [], do: [], else: [{:salix_web, :e2e_reports_r2, r2}]
  end

  # The worker and its ownership scope are one configuration unit. Returning
  # neither entry on any validation failure prevents a partially configured
  # worker from starting with unsafe defaults or an unintended identity scope.
  defp calendar_autojoin_env(json) do
    with %{"enabled" => true} = section <- json_get(json, ~w(meetings calendar_autojoin)),
         true <- calendar_runtime_configured?(json),
         {:ok, opts} <- calendar_autojoin_opts(section),
         {:ok, channels} <- calendar_autojoin_channels(section),
         true <- length(channels) <= Keyword.fetch!(opts, :max_groups_per_pass),
         true <- calendar_autojoin_work_fits_lease?(channels, opts) do
      [
        {:salix_meet, :calendar_autojoin, opts},
        {:salix_meet, :calendar_autojoin_channels, channels},
        {:salix_env, :protocol_timeouts,
         %{"meeting_join" => meeting_join_rpc_timeout_ms(Keyword.fetch!(opts, :task_timeout_ms))}}
      ]
    else
      _ -> []
    end
  end

  @doc """
  The meeting_join RPC timeout derived from the configured autojoin task
  budget. The RPC must return strictly before the outer per-group task is
  killed — otherwise every slow join is pinned as a permanently stuck
  in-doubt dispatch — so the bound is derived from the same configuration
  value instead of assuming the 30s default: the protocol-table ceiling
  (20s), a 5s settle margin under the budget, and never less than half the
  budget. For budgets so small that the connector's own meetnative HTTP
  timeout cannot fit, an RPC-level timeout is an ordinary reclaimable
  in-doubt outcome, not a stuck one.
  """
  @spec meeting_join_rpc_timeout_ms(pos_integer()) :: pos_integer()
  def meeting_join_rpc_timeout_ms(task_timeout_ms)
      when is_integer(task_timeout_ms) and task_timeout_ms > 0 do
    task_timeout_ms
    |> Kernel.-(5_000)
    |> max(div(task_timeout_ms, 2))
    |> min(20_000)
    |> max(1)
  end

  defp calendar_runtime_configured?(json) do
    runtime_url = json_get(json, ~w(meetings runtime_url))
    driver = json_get(json, ~w(meetings driver))

    cond do
      is_binary(runtime_url) and String.trim(runtime_url) != "" ->
        valid_meeting_runtime_url?(runtime_url)

      not is_nil(runtime_url) and runtime_url != "" ->
        false

      true ->
        driver == "connector"
    end
  end

  defp valid_meeting_runtime_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and String.trim(host) != ""

      _ ->
        false
    end
  end

  defp calendar_autojoin_opts(section) do
    Enum.reduce_while(@calendar_autojoin_bounds, {:ok, []}, fn {name, key, minimum, maximum},
                                                               {:ok, acc} ->
      case Map.get(section, key) do
        nil ->
          {:cont, {:ok, [{name, Keyword.fetch!(@calendar_autojoin_defaults, name)} | acc]}}

        value when is_integer(value) and value >= minimum and value <= maximum ->
          {:cont, {:ok, [{name, value} | acc]}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, opts} -> {:ok, Enum.reverse(opts)}
      other -> other
    end
  end

  defp calendar_autojoin_channels(section) do
    case Map.get(section, "channels") do
      channels when is_map(channels) ->
        normalized = Enum.map(channels, &normalize_calendar_autojoin_channel/1)

        if Enum.all?(normalized, &(length(&1) == 1)),
          do: {:ok, Enum.flat_map(normalized, & &1)},
          else: :error

      _ ->
        :error
    end
  end

  defp normalize_calendar_autojoin_channel({connect_id, spec})
       when is_binary(connect_id) and is_map(spec) do
    with connect_id when connect_id != "" <- String.trim(connect_id),
         calendars when calendars != [] <- normalize_calendar_names(Map.get(spec, "calendars")) do
      normalize_calendar_autojoin_target(connect_id, spec, calendars)
    else
      _ -> []
    end
  end

  defp normalize_calendar_autojoin_channel(_entry), do: []

  # The legacy Slack shape remains byte-for-byte stable so existing deployments
  # and cached enrollments need no migration. Provider is inferred later from the
  # connect record; only the Feishu-only fields select notification mode here.
  defp normalize_calendar_autojoin_target(connect_id, %{"channel" => channel} = spec, calendars)
       when is_binary(channel) do
    case String.trim(channel) do
      "" ->
        []

      channel ->
        entry = %{"connect_id" => connect_id, "channel" => channel, "calendars" => calendars}

        with writeback when is_boolean(writeback) <- Map.get(spec, "calendar_writeback", false) do
          [if(writeback, do: Map.put(entry, "calendar_writeback", true), else: entry)]
        else
          _ -> []
        end
    end
  end

  defp normalize_calendar_autojoin_target(connect_id, spec, calendars) do
    with "notify" <- Map.get(spec, "mode"),
         chat_id when is_binary(chat_id) <- Map.get(spec, "chat_id"),
         chat_id when chat_id != "" <- String.trim(chat_id),
         create_calendar when is_binary(create_calendar) <- Map.get(spec, "create_calendar"),
         create_calendar when create_calendar != "" <- String.trim(create_calendar),
         true <- Enum.member?(calendars, create_calendar),
         {:ok, mentions} <- normalize_calendar_mentions(Map.get(spec, "mentions", %{})) do
      [
        %{
          "connect_id" => connect_id,
          "mode" => "notify",
          "chat_id" => chat_id,
          "calendars" => calendars,
          "create_calendar" => create_calendar,
          "mentions" => mentions
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_calendar_mentions(nil), do: {:ok, %{"mode" => "none", "users" => []}}

  defp normalize_calendar_mentions(%{} = mentions) when map_size(mentions) == 0,
    do: {:ok, %{"mode" => "none", "users" => []}}

  defp normalize_calendar_mentions(%{"mode" => "none"}),
    do: {:ok, %{"mode" => "none", "users" => []}}

  defp normalize_calendar_mentions(%{"mode" => "all"}),
    do: {:ok, %{"mode" => "all", "users" => []}}

  defp normalize_calendar_mentions(%{"mode" => "users", "users" => users})
       when is_list(users) do
    normalized =
      users
      |> Enum.flat_map(fn
        %{"user_id" => user_id, "name" => name}
        when is_binary(user_id) and is_binary(name) ->
          case {String.trim(user_id), String.trim(name)} do
            {"", _} -> []
            {_, ""} -> []
            {user_id, name} -> [%{"user_id" => user_id, "name" => name}]
          end

        _ ->
          []
      end)
      |> Enum.uniq_by(& &1["user_id"])

    if normalized != [] and length(normalized) <= @calendar_autojoin_max_mentions and
         length(normalized) == length(users),
       do: {:ok, %{"mode" => "users", "users" => normalized}},
       else: :error
  end

  defp normalize_calendar_mentions(_mentions), do: :error

  defp normalize_calendar_names(names) when is_list(names) do
    normalized =
      names
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if length(normalized) in 1..@calendar_autojoin_max_calendars, do: normalized, else: []
  end

  defp normalize_calendar_names(_names), do: []

  @doc false
  def calendar_autojoin_work_fits_lease?(groups, opts) do
    concurrency = Keyword.fetch!(opts, :max_concurrency)
    waves = div(length(groups) + concurrency - 1, concurrency)
    waves * Keyword.fetch!(opts, :task_timeout_ms) < @calendar_autojoin_work_budget_ms
  end

  defp vm_config(json) do
    case json_get(json, ~w(vm)) do
      vm when is_map(vm) and map_size(vm) > 0 -> stringify_keys(vm)
      _ -> nil
    end
  end

  defp cloudflare_vm_gateway(json) do
    section = json_get(json, ~w(vm providers cloudflare))

    cond do
      not is_map(section) ->
        nil

      true ->
        base_url =
          str(%{"section" => section}, ~w(section gateway_base_url)) ||
            str(%{"section" => section}, ~w(section base_url))

        secret =
          str(%{"section" => section}, ~w(section gateway_secret)) ||
            str(%{"section" => section}, ~w(section secret))

        if is_binary(base_url) and is_binary(secret) do
          [base_url: base_url, secret: secret]
        end
    end
  end

  defp cloud_vm_archive_r2(json) do
    section = json_get(json, ~w(cloud_vm_archives r2))

    if is_map(section) do
      required = ~w(endpoint bucket access_key_id secret_access_key)
      values = Map.new(required, fn key -> {key, Map.get(section, key)} end)

      if Enum.all?(values, fn {_key, value} -> is_binary(value) and value != "" end) do
        if is_boolean(Map.get(section, "zstd_enabled")),
          do: Map.put(values, "zstd_enabled", section["zstd_enabled"]),
          else: values
      end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        if is_map(value) do
          stringify_keys(value)
        else
          value
        end

      {to_string(key), value}
    end)
  end

  defp object(json, path) do
    case json_get(json, path) do
      value when is_map(value) -> stringify_keys(value)
      _ -> nil
    end
  end

  defp json_get(json, path) do
    Enum.reduce_while(path, json, fn key, acc ->
      case acc do
        %{^key => value} when not is_nil(value) -> {:cont, value}
        _ -> {:halt, nil}
      end
    end)
  end
end
