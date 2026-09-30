defmodule Salix.Bindings.IMSessionActivityTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.IMSessionActivity
  alias SalixWeb.PubSubNotifier

  test "subscription is scoped to one session and notifications contain no inferred state" do
    agent_id = "agent-session-activity"
    session_id = "session-one"

    assert :ok = IMSessionActivity.subscribe(agent_id, session_id)

    assert :ok = PubSubNotifier.notify(agent_id, {:session_activity_updated, "session-two"})
    refute_receive {:session_activity_updated, ^agent_id, "session-two"}

    assert :ok = PubSubNotifier.notify(agent_id, {:session_activity_updated, session_id})
    assert_receive {:session_activity_updated, ^agent_id, ^session_id}

    assert :ok = IMSessionActivity.unsubscribe(agent_id, session_id)
    assert :ok = PubSubNotifier.notify(agent_id, {:session_activity_updated, session_id})
    refute_receive {:session_activity_updated, ^agent_id, ^session_id}
  end
end
