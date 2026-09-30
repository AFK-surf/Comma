defmodule SalixIM.TaskCompletionTest do
  use ExUnit.Case, async: true
  alias SalixIM.TaskCompletion

  defp task(attrs \\ %{}) do
    Map.merge(
      %{"kind" => "agent_task", "created_by_agent_id" => "router", "status" => "active"},
      attrs
    )
  end

  defp complete(task, router \\ "router"),
    do: TaskCompletion.router_update(task, %{"status" => "completed"}, router)

  test "own Router completes active and review Tasks, including an idempotent repeat" do
    for status <- ~w(active ready_for_review completed),
        schedule <- [nil, %{"schedule_id" => nil}] do
      assert :ok = complete(task(%{"status" => status, "schedule" => schedule}))
    end
  end

  test "another Router cannot complete the Task" do
    assert {:error, {:forbidden, _}} = complete(task(), "other-router")
  end

  test "Workflow Tasks cannot bypass any gate or terminal" do
    for status <- ~w(active ready_for_review failed cancelled escalated completed) do
      assert {:error, {:forbidden, _}} = complete(task(%{"workflow" => %{}, "status" => status}))
    end
  end

  test "scheduled and product-assigned Triage Tasks retain their completion owners" do
    assert {:error, {:forbidden, _}} =
             complete(task(%{"schedule" => %{"schedule_id" => "schedule"}}))

    assert {:error, {:forbidden, _}} =
             complete(task(%{"source_refs" => %{"triage_investigation" => %{}}}))
  end

  test "failed, cancelled, escalated and archived Tasks must not silently become Done" do
    for status <- ~w(failed cancelled escalated archived) do
      assert {:error, {:forbidden, _}} = complete(task(%{"status" => status}))
    end
  end

  test "non-Tasks and simultaneous kind changes cannot enter Done" do
    assert {:error, {:forbidden, _}} = complete(task(%{"kind" => "user_chat"}))

    assert {:error, {:forbidden, _}} =
             TaskCompletion.router_update(
               task(),
               %{"status" => "completed", "kind" => "user_chat"},
               "router"
             )
  end

  test "other updates and product-owned transitions are unchanged" do
    assert :ok =
             TaskCompletion.router_update(
               task(%{"status" => "completed"}),
               %{"status" => "active"},
               "router"
             )

    assert :ok =
             TaskCompletion.router_update(
               task(%{"workflow" => %{}}),
               %{"status" => "completed"},
               nil
             )
  end
end
