defmodule SalixStore.SchedulesStoreTest do
  # Shares the node-global control tables; keep serial.
  use SystemsClock.Case, async: false

  alias SalixStore.{Repo, ScheduleRuns, Schedules}

  setup do
    Repo.query!("TRUNCATE schedules, schedule_runs")
    :ok
  end

  defp rec(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "agent_id" => "agent_a",
        "prompt" => "p",
        "interval_minutes" => 5,
        "created_at" => 1_000,
        "last_run" => nil
      },
      overrides
    )
  end

  test "create is insert-once" do
    assert {:ok, _} = Schedules.create(rec("s1"), 301_000)
    assert {:error, :already_exists} = Schedules.create(rec("s1"), 301_000)
  end

  # Interval next-fire math, as the domain modules derive it.
  defp interval_next_fire(rec),
    do: (rec["last_run"] || rec["created_at"]) + rec["interval_minutes"] * 60_000

  test "advance is monotonic and reports not_found / unchanged distinctly" do
    assert {:error, :not_found} = Schedules.advance("nope", 300_000, &interval_next_fire/1)

    {:ok, _} = Schedules.create(rec("s1"), 301_000)
    assert :ok = Schedules.advance("s1", 301_000, &interval_next_fire/1)
    assert {:ok, %{"last_run" => 301_000}} = Schedules.get("s1")

    # A racing sweeper already advanced past this window: no rollback, and the
    # bound derived from the newer anchor is untouched.
    assert :unchanged = Schedules.advance("s1", 300_000, &interval_next_fire/1)
    assert {:ok, %{"last_run" => 301_000}} = Schedules.get("s1")
    assert {:ok, [_]} = Schedules.due_candidates(301_000 + 5 * 60_000)
    assert {:ok, []} = Schedules.due_candidates(301_000 + 5 * 60_000 - 1)
  end

  test "list_for_owners covers both receiver shapes and nothing else" do
    {:ok, _} = Schedules.create(rec("mine", %{"agent_id" => "agent_a"}), 1)

    {:ok, _} =
      Schedules.create(
        rec("task_mine", %{
          "agent_id" => nil,
          "receiver" => "task",
          "payload" => %{"agent_group_id" => "grp_1", "conversation_id" => "c1"}
        }),
        1
      )

    {:ok, _} =
      Schedules.create(
        rec("task_other", %{
          "agent_id" => nil,
          "receiver" => "task",
          "payload" => %{"agent_group_id" => "grp_z", "conversation_id" => "c2"}
        }),
        1
      )

    {:ok, _} = Schedules.create(rec("other", %{"agent_id" => "agent_z"}), 1)

    assert {:ok, rows} = Schedules.list_for_owners(["agent_a"], "grp_1")
    assert Enum.sort(Enum.map(rows, & &1["id"])) == ["mine", "task_mine"]

    assert {:ok, rows} = Schedules.list_for_owners(["agent_a"], nil)
    assert Enum.map(rows, & &1["id"]) == ["mine"]
  end

  test "owner-scoped point ops are atomic and receiver-fenced" do
    {:ok, _} = Schedules.create(rec("mine", %{"agent_id" => "agent_a"}), 1)

    :ok =
      Schedules.import_record(
        %{
          "id" => "task_with_agent",
          "receiver" => "task",
          "agent_id" => "agent_a",
          "payload" => %{"agent_group_id" => "grp_b", "conversation_id" => "c"},
          "interval_minutes" => 5,
          "created_at" => 1_000
        },
        1_000
      )

    # Agent-owner surface: own row yes; Task row (even bearing this agent_id)
    # and another agent's row are both indistinguishable from missing.
    assert {:ok, %{"id" => "mine"}} = Schedules.get_agent_owned("mine", "agent_a")
    assert {:error, :not_found} = Schedules.get_agent_owned("mine", "agent_z")
    assert {:error, :not_found} = Schedules.get_agent_owned("task_with_agent", "agent_a")
    assert {:error, :not_found} = Schedules.delete_agent_owned("task_with_agent", "agent_a")
    assert {:error, :not_found} = Schedules.delete_agent_owned("mine", "agent_z")
    assert {:ok, _} = Schedules.get("task_with_agent")

    # Task-owner surface: only the bound group deletes it.
    assert {:error, :not_found} = Schedules.delete_task_owned("task_with_agent", "grp_other")
    assert {:error, :not_found} = Schedules.delete_task_owned("mine", "grp_b")
    assert :ok = Schedules.delete_task_owned("task_with_agent", "grp_b")
    assert {:error, :not_found} = Schedules.get("task_with_agent")

    assert :ok = Schedules.delete_agent_owned("mine", "agent_a")
    assert {:error, :not_found} = Schedules.get("mine")
  end

  test "set_status flips the due-scan gate without touching recurrence" do
    {:ok, _} = Schedules.create(rec("s1"), 1_000)
    assert {:ok, [_]} = Schedules.due_candidates(2_000)

    assert {:ok, %{"status" => "paused"}} = Schedules.set_status("s1", "paused", 5_000)
    assert {:ok, []} = Schedules.due_candidates(2_000)

    assert {:ok, %{"status" => "active", "updated_at" => 6_000}} =
             Schedules.set_status("s1", "active", 6_000)

    assert {:ok, [_]} = Schedules.due_candidates(2_000)
    assert {:error, :not_found} = Schedules.set_status("nope", "paused", 1)
  end

  test "run claims: insert-once, durable disposition, retention prune" do
    assert :claimed = ScheduleRuns.claim("s1", 300_000, %{"disposition" => "dispatch"})
    assert :exists = ScheduleRuns.claim("s1", 300_000, %{"disposition" => "skipped_stale"})
    assert {:ok, :dispatch} = ScheduleRuns.disposition("s1", 300_000)

    assert :claimed = ScheduleRuns.claim("s1", 600_000, %{"disposition" => "skipped_stale"})
    assert {:ok, :skipped_stale} = ScheduleRuns.disposition("s1", 600_000)

    assert {:error, :not_found} = ScheduleRuns.disposition("s1", 900_000)

    assert {:ok, runs} = ScheduleRuns.list_for("s1")
    assert length(runs) == 2

    # Fresh rows survive the retention prune.
    assert {:ok, 0} = ScheduleRuns.prune_older_than(30)

    Repo.query!("UPDATE schedule_runs SET inserted_at = now() - interval '31 days'")
    assert {:ok, 2} = ScheduleRuns.prune_older_than(30)
    assert {:ok, []} = ScheduleRuns.list_for("s1")
  end

  describe "pause on archive (#849)" do
    test "pause_for_archived_agent pauses only this agent's active agent-receiver rows, marked" do
      {:ok, _} = Schedules.create(rec("s1"), 301_000)
      # User-paused before the archive: no marker, must not be touched.
      {:ok, _} = Schedules.create(rec("s2", %{"status" => "paused"}), 301_000)
      # Another agent, and a non-agent receiver row: out of scope.
      {:ok, _} = Schedules.create(rec("s3", %{"agent_id" => "agent_b"}), 301_000)
      {:ok, _} = Schedules.create(rec("s4", %{"receiver" => "task"}), 301_000)

      assert {:ok, 1} = Schedules.pause_for_archived_agent("agent_a", 1, 400_000)

      assert {:ok,
              %{
                "status" => "paused",
                "paused_by" => "archive",
                "archive_epoch" => 1,
                "updated_at" => 400_000
              }} = Schedules.get("s1")

      assert {:ok, %{"status" => "paused"} = s2} = Schedules.get("s2")
      refute Map.has_key?(s2, "paused_by")
      assert {:ok, %{"status" => "active"}} = Schedules.get("s3")
      assert {:ok, %{"status" => "active"}} = Schedules.get("s4")

      # Out of the due scan — the whole point.
      assert {:ok, due} = Schedules.due_candidates(301_000)
      refute "s1" in Enum.map(due, & &1["id"])

      # Idempotent.
      assert {:ok, 0} = Schedules.pause_for_archived_agent("agent_a", 1, 400_001)
      assert {:ok, %{"updated_at" => 400_000}} = Schedules.get("s1")
    end

    test "the epoch fence: a row the unarchive of this epoch stamped refuses a late pause" do
      {:ok, _} = Schedules.create(rec("s1", %{"unarchived_epoch" => 1}), 301_000)

      # A pause for epoch 1 is a stale observation of an archive that has
      # since been undone; a pause for epoch 2 is a new archive.
      assert {:ok, 0} = Schedules.pause_for_archived_agent("agent_a", 1, 400_000)
      assert {:ok, %{"status" => "active"}} = Schedules.get("s1")
      assert {:ok, 1} = Schedules.pause_for_archived_agent("agent_a", 2, 400_000)
      assert {:ok, %{"status" => "paused", "archive_epoch" => 2}} = Schedules.get("s1")
    end

    test "resume_archive_paused resumes only archive-paused rows up to the epoch, clearing the marker" do
      {:ok, _} = Schedules.create(rec("s1"), 301_000)
      {:ok, _} = Schedules.create(rec("s2", %{"status" => "paused"}), 301_000)
      assert {:ok, 1} = Schedules.pause_for_archived_agent("agent_a", 2, 400_000)

      # An older epoch's undo does not reach a newer archive's pause.
      assert {:ok, 0} = Schedules.resume_archive_paused("agent_a", 1, 500_000)
      assert {:ok, %{"status" => "paused"}} = Schedules.get("s1")

      assert {:ok, 1} = Schedules.resume_archive_paused("agent_a", 2, 500_000)

      assert {:ok, %{"status" => "active", "updated_at" => 500_000} = s1} = Schedules.get("s1")
      refute Map.has_key?(s1, "paused_by")
      refute Map.has_key?(s1, "archive_epoch")
      refute Map.has_key?(s1, "unarchived_epoch")
      assert {:ok, %{"status" => "paused"}} = Schedules.get("s2")
      assert {:ok, due} = Schedules.due_candidates(301_000)
      assert "s1" in Enum.map(due, & &1["id"])

      assert {:ok, 0} = Schedules.resume_archive_paused("agent_a", 2, 500_001)
    end
  end
end
