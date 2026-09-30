defmodule SalixWeb.PubSubNotifier do
  @moduledoc """
  Bridges `SalixAgent.Notifier` events onto `Phoenix.PubSub` so subscribers on
  any node refresh. Agent events use `agent:{id}`; Session Activity
  invalidations also use an exact session topic.
  """
  @behaviour SalixAgent.Notifier

  @pubsub SalixWeb.PubSub

  @impl true
  def notify(agent_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(agent_id), {:salix_agent_event, agent_id, event})
    notify_session_activity(agent_id, event)
    :ok
  end

  @doc "PubSub topic for an agent's stream."
  def topic(agent_id), do: "agent:" <> agent_id

  @doc "PubSub topic for one session's canonical activity invalidations."
  def session_activity_topic(agent_id, session_id),
    do: "session-activity:#{agent_id}:#{session_id}"

  defp notify_session_activity(agent_id, {:session_activity_updated, session_id}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      session_activity_topic(agent_id, session_id),
      {:session_activity_updated, agent_id, session_id}
    )
  end

  defp notify_session_activity(_agent_id, _event), do: :ok
end
