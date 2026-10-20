defmodule Salix.Bindings.IMSessionActivityTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias Salix.Bindings.IMSessionActivity
  alias SalixWeb.PubSubNotifier

  test "subscription is scoped to one session and notifications contain no inferred state" do
    agent_id = "agent-session-activity"
    session_id = "session-one"

    assert :ok = IMSessionActivity.subscribe(agent_id, session_id)

    assert :ok = PubSubNotifier.notify(agent_id, {:session_activity_updated, "session-two"})
    settle_refute_receive({:session_activity_updated, ^agent_id, "session-two"})
    assert :ok = PubSubNotifier.notify(agent_id, {:session_activity_updated, session_id})
    settle_receive({:session_activity_updated, ^agent_id, ^session_id})
    assert :ok = IMSessionActivity.unsubscribe(agent_id, session_id)
    assert :ok = PubSubNotifier.notify(agent_id, {:session_activity_updated, session_id})
    settle_refute_receive({:session_activity_updated, ^agent_id, ^session_id})
  end
end
