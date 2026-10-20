defmodule CommaWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = CommaWeb.ClientSurface.validate_configuration!()
    register_notifier(CommaWeb.PubSubNotifier)
    register_im_notifier()
    SystemsRuntime.put_env(:salix_im, :product_activity_observer, Comma.Analytics)
    SystemsRuntime.put_env(:salix_im, :wechat_command_handler, CommaWeb.WeChatCommands)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)

    SystemsRuntime.put_env(
      :salix_agent,
      :telegram_interaction_mod,
      CommaWeb.AgentTelegramInteraction
    )

    SystemsRuntime.put_env(
      :salix_agent,
      :recommendation_adapter_mod,
      CommaWeb.RecommendationRuntime
    )

    SystemsRuntime.put_env(:salix_agent, :proactive_mail_adapter, CommaWeb.ProactiveMail)
    SystemsRuntime.put_env(:salix_agent, :proactive_adapter, CommaWeb.Proactive)
    SystemsRuntime.put_env(:salix_im, :task_status_personal_adapter, CommaWeb.TelegramTaskCards)
    SystemsRuntime.put_env(:salix_im, :linear_agent_session_adapter, CommaWeb.LinearAgentSession)

    SystemsRuntime.put_env(
      :salix_im,
      :origin_provider_participants_adapter,
      CommaWeb.LinearAgentSession
    )

    SystemsRuntime.put_env(:salix_im, :task_status_observer, CommaWeb.ProactiveTask)
    SystemsRuntime.put_env(:salix_env, :device_connect_observer, CommaWeb.DeviceSetupOffers)
    SystemsRuntime.put_env(:salix_agent, :loop_authorization_adapter, CommaWeb.ProactiveWatch)
    SystemsRuntime.put_env(:salix_agent, :stations, CommaWeb.Stations)
    SystemsRuntime.put_env(:salix_env, :station_install, CommaWeb.Stations.DeviceInstall)
    SystemsRuntime.put_env(:salix_web, :station_control_plane, CommaWeb.Stations.CloudStation)
    SalixStore.StationMembers.register(Comma.Stations.Members)

    unless SystemsRuntime.get_env(:comma_web, :station_directory),
      do:
        SystemsRuntime.put_env(
          :comma_web,
          :station_directory,
          CommaWeb.Stations.GroupDirectory
        )

    SystemsRuntime.put_env(
      :comma_core,
      :recommendation_runtime_mod,
      CommaWeb.RecommendationRuntime
    )

    SystemsRuntime.put_env(:salix_web, :comma_oauth_commit_mod, CommaWeb.OAuthCommit)
    SystemsRuntime.put_env(:salix_web, :composio_signal_mod, CommaWeb.MemberSourceTriggers)

    children =
      maybe_pubsub_child(pubsub_server()) ++
        [CommaWeb.StationPresence, CommaWeb.StationReleases] ++
        [{SystemsRuntime.TaskSupervisor, name: CommaWeb.LinearAgent.TaskSupervisor}] ++
        CommaWeb.TelegramOIDC.child_specs() ++
        CommaWeb.IMessageRuntime.child_specs() ++
        CommaWeb.IMessagePhotonRuntime.child_specs() ++
        CommaWeb.NativePushListener.child_specs() ++
        [
          {Bandit,
           plug: CommaWeb.Router,
           port: port(),
           startup_log: false,
           http_options: [
             log_exceptions_with_status_codes: 500..599,
             log_protocol_errors: false
           ],
           thousand_island_options: [supervisor_options: [name: CommaWeb.HTTPServer]]}
        ]

    SystemsRuntime.Supervisor.start_link(children,
      strategy: :one_for_one,
      name: CommaWeb.Supervisor
    )
  end

  defp maybe_pubsub_child(name) when is_atom(name) do
    if SystemsRuntime.Proc.whereis(name) do
      []
    else
      [{Phoenix.PubSub, name: name}]
    end
  end

  defp maybe_pubsub_child(_name), do: []

  defp pubsub_server do
    SystemsRuntime.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)
  end

  defp register_notifier(module) do
    notifiers =
      :salix_agent
      |> SystemsRuntime.get_env(:notifiers, [])
      |> List.wrap()
      |> Kernel.++([module])
      |> Enum.uniq()

    SystemsRuntime.put_env(:salix_agent, :notifiers, notifiers)
  end

  def register_im_notifier(module \\ CommaWeb.IMNotifier) do
    SystemsRuntime.put_env(:salix_im, :conversation_notifier, &module.notify/2)
  end

  def port do
    cond do
      v = SystemsRuntime.get_env(:comma_web, :port) -> v
      v = System.get_env("COMMA_WEB_HTTP_PORT") -> String.to_integer(v)
      true -> 4200
    end
  end

  def http_port do
    case ThousandIsland.listener_info(CommaWeb.HTTPServer) do
      {:ok, {_address, bound_port}} -> bound_port
    end
  end

  def base_url, do: "http://127.0.0.1:#{http_port()}"
end
