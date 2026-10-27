defmodule SalixWeb.Application do
  @moduledoc """
  Web-layer supervision. Starts `Phoenix.PubSub` (the
  `agent.stream:*` fan-out), wires the agent runtime's notifier to broadcast over
  it, and serves the HTTP API on Bandit.
  """

  use Application

  @native_triage_runtime Salix.Bindings.TriageReviewRuntime
  @native_triage_receipt_recovery Salix.Bindings.TriageReceiptRecovery
  @native_triage_product_effect_worker SalixIM.Triage.ProductEffectWorker
  @native_triage_companion_reaction_worker SalixIM.Triage.CompanionReactionEffectWorker
  # Release builds use the production Conversation/Slack adapter. Development
  # and test builds are deliberately zero-write rehearsals; this is a build
  # safety boundary, not a user-facing or environment business switch.
  @native_triage_product_effect_adapter if(Mix.env() == :prod,
                                          do: SalixIM.Triage.SlackEffectAdapter,
                                          else: SalixIM.Triage.AuditSink
                                        )
  # BridgeForTeams is a downstream app; naming the module as a literal atom
  # keeps the composition root free of a compile-time dependency on it.
  @native_triage_context_port {:"Elixir.BridgeForTeams.TriageContext", []}
  @native_triage_evaluator_port {
    Salix.Bindings.TriageEvaluator,
    [
      provider: SalixLlm.Provider,
      provider_config: :agent_template,
      transport_receipt: :single_attempt
    ]
  }

  @impl true
  def start(_type, _args) do
    sync_configured_im_public_base_url()
    :ok = SalixWeb.LocalOAuthMock.configure!()
    Salix.App.configure()
    SalixWeb.ConnectorTaskAdmission.initialize()

    opts = [strategy: :one_for_one, name: SalixWeb.Supervisor]
    SystemsRuntime.Supervisor.start_link(children(), opts)
  end

  @doc false
  def children do
    [
      {Phoenix.PubSub, name: SalixWeb.PubSub},
      {SystemsRuntime.Registry, keys: :unique, name: SalixWeb.VoiceHTTP.Registry},
      Salix.RemoteShell.Registrations,
      {SystemsRuntime.TaskSupervisor,
       name: SalixWeb.ConnectorControlTaskSupervisor,
       max_children: SystemsRuntime.get_env(:salix_web, :connector_control_task_limit, 16)},
      SalixWeb.ConnectorDisconnectQueue,
      SalixWeb.StationRelay,
      SalixWeb.StationTaskIndex,
      background(SalixWeb.SubscriptionRuntimeWorker, :subscription_runtime_worker),
      {SystemsRuntime.TaskSupervisor,
       name: SalixWeb.ConnectorRequestTaskSupervisor,
       max_children: SystemsRuntime.get_env(:salix_web, :connector_request_task_limit, 64)},
      # Tasks kept here with Sessions of other stations taking part: one giver per Task and station on a node, and
      # once started, each given what it has not had (SalixWeb.StationTasks).
      {SystemsRuntime.Registry, keys: :unique, name: SalixWeb.StationTasks.Registry},
      {SystemsRuntime.TaskSupervisor, name: SalixWeb.StationTasks.Supervisor},
      Supervisor.child_spec({Task, &give_station_tasks/0},
        id: :give_station_tasks,
        restart: :temporary
      ),
      {SystemsRuntime.TaskSupervisor,
       name: SalixWeb.ConnectorStreamTaskSupervisor,
       max_children: SystemsRuntime.get_env(:salix_web, :connector_stream_task_limit, 32)},
      {SystemsRuntime.TaskSupervisor, name: SalixWeb.OAuthMCPRefreshSupervisor, max_children: 16},
      {SystemsRuntime.TaskSupervisor,
       name: SalixWeb.CloudVM.ImageArchiveSupervisor, max_children: 4},
      background(SalixWeb.CloudVM.ArchiveGC, :cloud_vm_archive_gc),
      # What this node recently made true in L4ES workspaces.
      background(SalixWeb.L4ESRecent, :l4es_recent),
      # Coding Tasks' sandboxes: a bounded check of the due ones on a timer.
      background(SalixWeb.CodingSandboxes, :coding_sandboxes),
      Salix.Control.PluginCatalogCache,
      # One supervised Redis connection for the global SiteLLM sliding window.
      {SalixWeb.SiteAPI.RateLimit,
       url: SystemsRuntime.fetch_env!(:salix_web, :site_rate_limit_redis_url)},
      # And one for the Router post_message API's per-key / per-group windows.
      {Salix.App.RouterInbox.RateLimit,
       url: SystemsRuntime.fetch_env!(:salix_web, :site_rate_limit_redis_url)},
      # Site-API node-local _api.json config cache.
      SalixWeb.SiteAPI.State,
      # Admin dashboard Phoenix endpoint. Started in every env (so LiveViewTest
      # can drive it) with `server: false` (config) — it opens NO listener of
      # its own and is invoked as a plug by SalixWeb.Endpoint for `/dash/*`,
      # sharing the single Bandit listener below. Reuses SalixWeb.PubSub.
      SalixWeb.DashboardEndpoint
    ]
    |> List.flatten()
    |> Kernel.++([SalixWeb.MeetingIngressSupervisor] ++ native_triage_children())
  end

  # A worker that does its work on a timer starts unless its switch is off.
  # The test configuration turns each one off: a test calls the worker's work
  # itself, or starts the worker under its own supervisor.
  defp background(child, switch),
    do: if(SystemsRuntime.get_env(:salix_web, switch, true), do: [child], else: [])

  defp give_station_tasks do
    if Keyword.get(SystemsRuntime.get_env(:salix_web, :station_tasks, []), :give_at_start, true),
      do: SalixWeb.StationTasks.give_all()
  end

  @doc false
  def native_triage_children do
    namespace = SalixStore.TriageKeys.default_namespace()

    runtime_opts = [
      id: @native_triage_runtime,
      name: @native_triage_runtime,
      mode: :review,
      namespace: namespace,
      context_port: @native_triage_context_port,
      evaluator_port: @native_triage_evaluator_port,
      review_projection: :slack,
      draining?: &SalixCluster.NodeLifecycle.draining?/0
    ]

    recovery_opts = [
      id: @native_triage_receipt_recovery,
      name: @native_triage_receipt_recovery,
      runtime: @native_triage_runtime,
      lease_key: SalixStore.TriageKeys.ctl_im_triage_receipt_recovery_lease(namespace)
    ]

    product_effect_opts = [
      id: @native_triage_product_effect_worker,
      name: @native_triage_product_effect_worker,
      adapter: @native_triage_product_effect_adapter
    ]

    companion_reaction_opts = [
      id: @native_triage_companion_reaction_worker,
      name: @native_triage_companion_reaction_worker,
      adapter: @native_triage_product_effect_adapter,
      claim_fun: &SalixStore.TriageProductRuntime.claim_companion_reactions/2,
      settle_fun: &SalixStore.TriageProductRuntime.settle_companion_reaction/2
    ]

    if SystemsRuntime.get_env(:salix_web, :native_triage, true) do
      [
        SalixIM.Triage.Runtime.child_spec(runtime_opts),
        SalixIM.Triage.ReceiptRecovery.child_spec(recovery_opts),
        SalixIM.Triage.ProductEffectWorker.child_spec(product_effect_opts),
        SalixIM.Triage.ProductEffectWorker.child_spec(companion_reaction_opts)
      ]
    else
      []
    end
  end

  @doc "HTTP listen port (app config / 4000)."
  def port do
    cond do
      v = SystemsRuntime.get_env(:salix_web, :port) -> v
      true -> 4000
    end
  end

  @doc "Actual HTTP listen port, including test runs configured with port 0."
  def http_port do
    case ThousandIsland.listener_info(SalixWeb.HTTPServer) do
      {:ok, {_address, bound_port}} -> bound_port
    end
  end

  @doc "Base URL for the running HTTP server."
  def base_url do
    "http://127.0.0.1:#{http_port()}"
  end

  @doc """
  Externally reachable base URL (willow's `server.api_base_url`): the
  `:salix_web, :public_base_url` app config, set from config.json `web.api_base_url`
  (`SalixStore.ConfigJson`). Falls back to the local listener when unset. Used
  for cloud-VM install links and the connector dial-back URL.
  """
  def public_base_url do
    case SystemsRuntime.get_env(:salix_web, :public_base_url) do
      v when is_binary(v) and v != "" -> String.trim_trailing(v, "/")
      _ -> base_url()
    end
  end

  @doc false
  def calendar_autojoin_children do
    SalixWeb.MeetingIngressSupervisor.calendar_autojoin_children()
  end

  @doc false
  def sync_im_public_base_url do
    SystemsRuntime.put_env(:salix_im, :public_base_url, public_base_url())
  end

  defp sync_configured_im_public_base_url do
    case SystemsRuntime.get_env(:salix_web, :public_base_url) do
      v when is_binary(v) and v != "" ->
        SystemsRuntime.put_env(:salix_im, :public_base_url, String.trim_trailing(v, "/"))

      _ ->
        :ok
    end
  end
end
