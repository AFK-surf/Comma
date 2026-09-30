defmodule SalixIM.Migrations.RetireTaskGraphTest do
  use ExUnit.Case, async: true
  alias SalixIM.Migrations.RetireTaskGraph

  defp record(status) do
    %{
      "kind" => "agent_task",
      "conversation_id" => "unchanged",
      "status" => status,
      "task_worker_agent_id" => "worker",
      "created_by_agent_id" => "router",
      "workflow" => %{"participants" => %{"worker" => %{"participant_id" => "participant"}}},
      "workflow_runtime" => %{"progresses" => %{"work" => %{"state" => "active"}}},
      "metadata" => %{"unrelated" => true},
      "source_refs" => %{"authority" => "original"},
      "message_tail_seq" => 23,
      "archived_from_status" => "completed"
    }
  end

  defp participants, do: Enum.map(["worker", "router"], &%{"agent_id" => &1, "state" => "active"})

  test "conversion retains identity, authority and historical evidence, with a stable handoff" do
    original = record("active")
    assert {:ok, converted} = RetireTaskGraph.convert(original, participants())

    assert Map.take(
             converted,
             ~w(conversation_id status task_worker_agent_id created_by_agent_id source_refs message_tail_seq)
           ) ==
             Map.take(
               original,
               ~w(conversation_id status task_worker_agent_id created_by_agent_id source_refs message_tail_seq)
             )

    assert converted["metadata"]["unrelated"]
    assert converted["metadata"]["retired_task_graph"]["runtime"] == original["workflow_runtime"]
    assert RetireTaskGraph.needs_handoff?(converted)
    assert {:ok, ^converted} = RetireTaskGraph.convert(converted, participants())
    assert RetireTaskGraph.handoff(converted) =~ "remaining work"
  end

  test "completed, cancelled and archived tasks are not reopened" do
    for status <- ~w(completed cancelled failed ready_for_review escalated archived) do
      assert {:ok, converted} = RetireTaskGraph.convert(record(status), participants())
      assert converted["status"] == status
      assert converted["archived_from_status"] == "completed"
      refute RetireTaskGraph.needs_handoff?(converted)
    end
  end

  test "an active task with missing ownership fails instead of selecting a new worker" do
    assert {:error, :task_graph_requires_existing_worker_and_delegator} =
             RetireTaskGraph.convert(record("active"), [])
  end

  test "history conflicts fail without overwriting evidence" do
    record = put_in(record("active"), ["metadata", "retired_task_graph"], %{"prior" => true})

    assert {:error, :task_graph_history_conflict} =
             RetireTaskGraph.convert(record, participants())
  end
end
