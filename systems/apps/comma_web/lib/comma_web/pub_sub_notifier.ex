defmodule CommaWeb.PubSubNotifier do
  @moduledoc """
  Bridges Salix runtime stream hints onto the Comma product PubSub.
  """
  @behaviour SalixAgent.Notifier

  @impl true
  def notify(agent_id, event) do
    Phoenix.PubSub.broadcast(
      pubsub_server(),
      topic(agent_id),
      {:salix_agent_event, agent_id, event}
    )

    :ok
  end

  def topic(agent_id), do: "agent:" <> agent_id

  defp pubsub_server do
    Application.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)
  end
end
