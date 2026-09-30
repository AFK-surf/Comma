defmodule Salix.Bindings.IMSessionActivity do
  @moduledoc false

  @behaviour SalixIM.Ports.SessionActivity

  alias SalixIM.ConversationParticipantActivity

  @pubsub SalixWeb.PubSub

  @impl true
  def get(agent_id, session_id) do
    with {:ok, owner_snapshot} <-
           SalixAgent.AgentActor.participant_realtime_snapshot(agent_id, session_id) do
      snapshot =
        ConversationParticipantActivity.session_snapshot(
          owner_snapshot["canonical"],
          owner_snapshot["activity"],
          owner_snapshot["draft"]
        )

      {:ok, snapshot}
    end
  end

  @impl true
  def subscribe(agent_id, session_id) do
    Phoenix.PubSub.subscribe(
      @pubsub,
      SalixWeb.PubSubNotifier.session_activity_topic(agent_id, session_id)
    )
  end

  @impl true
  def unsubscribe(agent_id, session_id) do
    Phoenix.PubSub.unsubscribe(
      @pubsub,
      SalixWeb.PubSubNotifier.session_activity_topic(agent_id, session_id)
    )
  end
end
