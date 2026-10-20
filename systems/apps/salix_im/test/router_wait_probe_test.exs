defmodule SalixIM.RouterWaitProbeTest do
  use SystemsClock.Case, async: true

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
end
