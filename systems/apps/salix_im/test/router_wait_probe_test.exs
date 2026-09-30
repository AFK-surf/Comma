defmodule SalixIM.RouterWaitProbeTest do
  use ExUnit.Case, async: true

  alias SalixIM.RouterWaitProbe

  @router "agt1_2075863631777492992_2075863631844601856_2075863631903322113"
  @worker "agt1_2075863631777492992_2075863631844601856_2098061512420622336"

  test "only the agent's own active Tasks with an assigned Worker count" do
    task = %{
      "status" => "active",
      "created_by_agent_id" => @router,
      "task_worker_agent_id" => @worker
    }

    assert RouterWaitProbe.own_active_task?(task, @router)
    refute RouterWaitProbe.own_active_task?(%{task | "status" => "ready_for_review"}, @router)
    refute RouterWaitProbe.own_active_task?(%{task | "created_by_agent_id" => @worker}, @router)
    refute RouterWaitProbe.own_active_task?(Map.delete(task, "task_worker_agent_id"), @router)
    refute RouterWaitProbe.own_active_task?(nil, @router)
  end

  test "the most recently updated Tasks are checked first" do
    records = [
      %{"conversation_id" => "old", "updated_at" => 1},
      %{"conversation_id" => "unknown"},
      %{"conversation_id" => "new", "updated_at" => 3},
      %{"conversation_id" => "mid", "updated_at" => 2}
    ]

    assert Enum.map(RouterWaitProbe.recent_first(records), & &1["conversation_id"]) ==
             ["new", "mid", "old", "unknown"]
  end

  test "only an active Worker session counts as busy" do
    assert RouterWaitProbe.busy_activity?(%{"state" => "active", "status" => "is working..."})
    refute RouterWaitProbe.busy_activity?(%{"state" => "stopped", "status" => ""})
    refute RouterWaitProbe.busy_activity?(%{"state" => "error"})
    refute RouterWaitProbe.busy_activity?(nil)
  end

  test "an agent id that names no group answers false instead of raising" do
    refute RouterWaitProbe.delegates_busy?("not-an-agent-id", "ses1_1", %{})
    refute RouterWaitProbe.delegates_busy?(nil, "ses1_1", %{})
  end
end
