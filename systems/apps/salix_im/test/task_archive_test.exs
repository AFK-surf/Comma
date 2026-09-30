defmodule SalixIM.TaskArchiveTest do
  use ExUnit.Case, async: true
  @moduletag :task_archive
  alias SalixIM.TaskArchive

  defp task(status), do: %{"kind" => "agent_task", "status" => status, "updated_at" => 1}

  test "each ended lifecycle round trips without losing its original status" do
    for status <- ~w(ready_for_review completed failed cancelled escalated) do
      assert %{"allowed" => true, "reason" => nil} = TaskArchive.availability(task(status))
      archived = TaskArchive.transition(task(status), :archive, 1, 2)
      assert archived["status"] == "archived"
      assert archived["archived_from_status"] == status
      assert TaskArchive.transition(archived, :archive, 1, 3) == archived

      assert TaskArchive.transition(archived, :unarchive, 2, 4) ==
               Map.put(task(status), "updated_at", 4)
    end
  end

  test "running, recurring and unknown statuses cannot archive" do
    for record <- [
          task("active"),
          task("unknown"),
          Map.put(task("completed"), "schedule", %{"schedule_id" => "schedule"})
        ] do
      assert %{"allowed" => false} = TaskArchive.availability(record)
      assert {:error, {:conflict, _}} = TaskArchive.transition(record, :archive, 1, 2)
    end
  end

  test "late operations cannot undo a newer archive cycle" do
    first = TaskArchive.transition(task("failed"), :archive, 1, 2)
    restored = TaskArchive.transition(first, :unarchive, 2, 3)
    second = TaskArchive.transition(restored, :archive, 3, 4)
    assert {:error, {:conflict, _}} = TaskArchive.transition(second, :unarchive, 2, 5)
    assert {:error, {:conflict, _}} = TaskArchive.transition(restored, :archive, 1, 5)
    assert TaskArchive.transition(restored, :unarchive, 2, 5) == restored
  end

  test "archive cannot be bypassed by generic updates or new user commands" do
    archived = TaskArchive.transition(task("completed"), :archive, 1, 2)
    assert {:error, _} = TaskArchive.ordinary_update(archived, %{"status" => "active"})
    assert {:error, _} = TaskArchive.ordinary_update(task("completed"), %{"status" => "archived"})

    assert {:error, _} =
             TaskArchive.admit_message(archived, %{"actor_type" => "user"}, :uncommitted)

    assert :ok = TaskArchive.admit_message(archived, %{"actor_type" => "user"}, :committed_retry)
    assert :ok = TaskArchive.admit_message(archived, %{"actor_type" => "agent"}, :uncommitted)
    assert {:error, _} = TaskArchive.transition(task("archived"), :unarchive, 1, 2)
  end

  test "late result updates preserve archive list position without freezing the revision" do
    archived = task("archived") |> Map.put("archived_at", 2) |> Map.put("updated_at", 10)
    assert TaskArchive.list_timestamp(archived) == 2
    assert TaskArchive.list_timestamp(task("completed")) == 1
  end
end
