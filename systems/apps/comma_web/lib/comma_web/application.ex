defmodule CommaWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = CommaWeb.ClientSurface.validate_configuration!()
    register_notifier(CommaWeb.PubSubNotifier)
    register_im_notifier()
    Application.put_env(:salix_im, :wechat_command_handler, CommaWeb.WeChatCommands)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Application.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)

    Application.put_env(
      :salix_agent,
      :telegram_interaction_mod,
      CommaWeb.AgentTelegramInteraction
    )

    Application.put_env(:salix_agent, :recommendation_adapter_mod, CommaWeb.RecommendationRuntime)
    Application.put_env(:salix_agent, :proactive_mail_adapter, CommaWeb.ProactiveMail)
    Application.put_env(:salix_agent, :proactive_adapter, CommaWeb.Proactive)
    Application.put_env(:salix_im, :task_status_personal_adapter, CommaWeb.TelegramTaskCards)
    Application.put_env(:salix_im, :task_status_observer, CommaWeb.ProactiveTask)
    Application.put_env(:salix_agent, :loop_authorization_adapter, CommaWeb.ProactiveWatch)
    Application.put_env(:comma_core, :recommendation_runtime_mod, CommaWeb.RecommendationRuntime)
    Application.put_env(:salix_web, :comma_oauth_commit_mod, CommaWeb.OAuthCommit)
    Application.put_env(:salix_web, :composio_signal_mod, CommaWeb.MemberSourceTriggers)

    children =
      maybe_pubsub_child(pubsub_server()) ++
        CommaWeb.TelegramOIDC.child_specs() ++
        CommaWeb.IMessageRuntime.child_specs() ++
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

    Supervisor.start_link(children, strategy: :one_for_one, name: CommaWeb.Supervisor)
  end

  defp maybe_pubsub_child(name) when is_atom(name) do
    if Process.whereis(name) do
      []
    else
      [{Phoenix.PubSub, name: name}]
    end
  end

  defp maybe_pubsub_child(_name), do: []

  defp pubsub_server do
    Application.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)
  end

  defp register_notifier(module) do
    notifiers =
      :salix_agent
      |> Application.get_env(:notifiers, [])
      |> List.wrap()
      |> Kernel.++([module])
      |> Enum.uniq()

    Application.put_env(:salix_agent, :notifiers, notifiers)
  end

  def register_im_notifier(module \\ CommaWeb.IMNotifier) do
    Application.put_env(:salix_im, :conversation_notifier, &module.notify/2)
  end

  def port do
    cond do
      v = Application.get_env(:comma_web, :port) -> v
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
