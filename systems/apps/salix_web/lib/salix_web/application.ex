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
    Supervisor.start_link(children(), opts)
  end

  @doc false
  def children do
    [
      {Phoenix.PubSub, name: SalixWeb.PubSub},
      Salix.RemoteShell.Registrations,
      %{
        id: SalixWeb.ComputeRuntimeRPCPG,
        start: {:pg, :start_link, [SalixWeb.ComputeRuntimeRPCPG]}
      },
      {Task.Supervisor,
       name: SalixWeb.ConnectorControlTaskSupervisor,
       max_children: Application.get_env(:salix_web, :connector_control_task_limit, 16)},
      SalixWeb.ConnectorDisconnectQueue,
      SalixWeb.SubscriptionRuntimeWorker,
      {Task.Supervisor,
       name: SalixWeb.ConnectorRequestTaskSupervisor,
       max_children: Application.get_env(:salix_web, :connector_request_task_limit, 64)},
      {Task.Supervisor,
       name: SalixWeb.ConnectorExternalEventTaskSupervisor,
       max_children: Application.get_env(:salix_web, :connector_external_event_task_limit, 64)},
      SalixWeb.ConnectorExternalEventCoordinator,
      {Task.Supervisor,
       name: SalixWeb.ConnectorStreamTaskSupervisor,
       max_children: Application.get_env(:salix_web, :connector_stream_task_limit, 32)},
      {Task.Supervisor, name: SalixWeb.CloudVM.ArchiveDiagnosticsSupervisor, max_children: 4},
      {Task.Supervisor, name: SalixWeb.CloudVM.RuntimeInstallSupervisor, max_children: 4},
      {Task.Supervisor, name: SalixWeb.CloudVM.ImageArchiveSupervisor, max_children: 4},
      SalixWeb.CloudVM.ArchiveGC,
      Salix.Control.PluginCatalogCache,
      # One supervised Redis connection for the global SiteLLM sliding window.
      {SalixWeb.SiteAPI.RateLimit,
       url: Application.fetch_env!(:salix_web, :site_rate_limit_redis_url)},
      # And one for the Router post_message API's per-key / per-group windows.
      {Salix.App.RouterInbox.RateLimit,
       url: Application.fetch_env!(:salix_web, :site_rate_limit_redis_url)},
      # Site-API node-local _api.json config cache.
      SalixWeb.SiteAPI.State,
      # Admin dashboard Phoenix endpoint. Started in every env (so LiveViewTest
      # can drive it) with `server: false` (config) — it opens NO listener of
      # its own and is invoked as a plug by SalixWeb.Endpoint for `/dash/*`,
      # sharing the single Bandit listener below. Reuses SalixWeb.PubSub.
      SalixWeb.DashboardEndpoint
    ] ++ [SalixWeb.MeetingIngressSupervisor] ++ native_triage_children()
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
      review_projection: :slack
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

    [
      SalixIM.Triage.Runtime.child_spec(runtime_opts),
      SalixIM.Triage.ReceiptRecovery.child_spec(recovery_opts),
      SalixIM.Triage.ProductEffectWorker.child_spec(product_effect_opts),
      SalixIM.Triage.ProductEffectWorker.child_spec(companion_reaction_opts)
    ]
  end

  @doc "HTTP listen port (app config / 4000)."
  def port do
    cond do
      v = Application.get_env(:salix_web, :port) -> v
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
    case Application.get_env(:salix_web, :public_base_url) do
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
    Application.put_env(:salix_im, :public_base_url, public_base_url())
  end

  defp sync_configured_im_public_base_url do
    case Application.get_env(:salix_web, :public_base_url) do
      v when is_binary(v) and v != "" ->
        Application.put_env(:salix_im, :public_base_url, String.trim_trailing(v, "/"))

      _ ->
        :ok
    end
  end
end
