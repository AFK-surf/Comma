defmodule SalixIM.TaskManualStatusTest do
  use SystemsClock.Case, async: true
  alias SalixIM.TaskManualStatus

  defp task(attrs \\ %{}) do
    Map.merge(
      %{
        "kind" => "agent_task",
        "created_by_agent_id" => "router",
        "status" => "active",
        "updated_at" => 10
      },
      attrs
    )
  end

  defp transition(task, status \\ "cancelled", version \\ 10),
    do: TaskManualStatus.transition(task, status, version, "user-1", 11)

  test "a user ends in-progress and in-review Tasks as Done or Cancelled" do
    for from <- ~w(active ready_for_review escalated), to <- ~w(completed cancelled) do
      ended = transition(task(%{"status" => from}), to)

      assert ended["status"] == to
      assert ended["updated_at"] == 11

      assert ended["manual_status_change"] == %{
               "status" => to,
               "from_status" => from,
               "user_id" => "user-1",
               "at" => 11
             }
    end
  end

  test "a stale version, a non-Task and product-owned Tasks are rejected" do
    assert {:error, {:conflict, "Task changed; refresh and try again"}} =
             transition(task(), "completed", 9)

    for attrs <- [
          %{"kind" => "user_chat"},
          %{"workflow" => %{}},
          %{"source_refs" => %{"triage_investigation" => %{}}},
          %{"schedule" => %{"schedule_id" => "schedule-1"}}
        ] do
      assert {:error, {:conflict, _}} = transition(task(attrs))
    end

    assert %{"status" => "cancelled"} = transition(task(%{"schedule" => %{"schedule_id" => nil}}))
  end

  describe "Router status updates after a manual end" do
    setup do
      %{ended: transition(task(), "completed")}
    end

    test "need a human Message sent after the end to change the status", %{ended: ended} do
      for status <- ~w(active ready_for_review cancelled) do
        for turn_at <- [nil, 10, 11] do
          assert {:error, {:forbidden, _}} =
                   TaskManualStatus.router_update(ended, %{"status" => status}, "router", turn_at)
        end

        assert :ok = TaskManualStatus.router_update(ended, %{"status" => status}, "router", 12)
      end
    end
  end
end
