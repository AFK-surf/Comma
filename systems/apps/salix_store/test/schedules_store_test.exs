defmodule SalixStore.SchedulesStoreTest do
  # Shares the node-global control tables; keep serial.
  use ExUnit.Case, async: false

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

  test "unknown body keys round-trip through attrs and canonical drops nils" do
    assert {:ok, _} = Schedules.create(rec("s1", %{"custom_flag" => %{"x" => 1}}), 301_000)
    assert {:ok, got} = Schedules.get("s1")
    assert got["custom_flag"] == %{"x" => 1}
    # Explicit nil last_run written by the legacy shape reads back as absent.
    refute Map.has_key?(got, "last_run")
    assert got["status"] == "active"
    assert got["receiver"] == "agent"
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

  test "advance derives the bound from the locked current row, not a stale snapshot" do
    # Reviewer repro: a due 10-minute schedule captured by a sweep at 600_000;
    # a concurrent operator update switches it to 1 minute; the old sweep then
    # resumes its advance. The bound must derive from the CURRENT 1-minute
    # recurrence (660_000), never the stale 10-minute snapshot (1_200_000) —
    # otherwise the due scan misses the 660_000 occurrence entirely.
    {:ok, _} =
      Schedules.create(rec("s1", %{"interval_minutes" => 10, "created_at" => 0}), 600_000)

    assert {:ok, _} =
             Schedules.update("s1", fn current ->
               updated = Map.put(current, "interval_minutes", 1)
               {:ok, updated, interval_next_fire(updated)}
             end)

    assert :ok = Schedules.advance("s1", 600_000, &interval_next_fire/1)

    assert {:ok, %{"last_run" => 600_000, "interval_minutes" => 1}} = Schedules.get("s1")
    assert {:ok, [_]} = Schedules.due_candidates(660_000)
    assert {:ok, []} = Schedules.due_candidates(659_999)
  end

  test "recompute_next_fire rewrites the bound from the locked current row" do
    {:ok, _} = Schedules.create(rec("s1"), 100)

    # A too-low bound (e.g. a cutover-imported anchor) is raised to the truth.
    :ok = Schedules.recompute_next_fire("s1", &interval_next_fire/1)
    assert {:ok, [_]} = Schedules.due_candidates(301_000)
    assert {:ok, []} = Schedules.due_candidates(300_999)

    # A too-high bound (a stale-snapshot casualty) is lowered back to the
    # truth — recompute converges in both directions.
    {:ok, _} =
      Schedules.update("s1", fn current -> {:ok, current, 999_999_999} end)

    assert {:ok, []} = Schedules.due_candidates(301_000)
    :ok = Schedules.recompute_next_fire("s1", &interval_next_fire/1)
    assert {:ok, [_]} = Schedules.due_candidates(301_000)

    # Unknown id is a silent no-op (best-effort heal path).
    :ok = Schedules.recompute_next_fire("nope", &interval_next_fire/1)
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

  test "an imported Task row carrying an agent_id is never selectable through the agent branch" do
    # Validation rejects this shape at create; a pre-existing/imported row
    # must still be receiver-fenced out of both agent-owner surfaces (the
    # reviewer's foreign-Task/project-agent-id authorization-escape repro).
    :ok =
      Schedules.import_record(
        %{
          "id" => "foreign_task",
          "receiver" => "task",
          "agent_id" => "agent_project_a",
          "payload" => %{"agent_group_id" => "group_project_b", "conversation_id" => "conv_b"},
          "interval_minutes" => 5,
          "created_at" => 1_000,
          "last_run" => nil
        },
        1_000
      )

    assert {:ok, []} = Schedules.list_for_owners(["agent_project_a"], "group_project_a")
    assert {:ok, []} = Schedules.list_by_agents(["agent_project_a"])
    # Its true owner still reaches it through the Task branch.
    assert {:ok, [%{"id" => "foreign_task"}]} = Schedules.list_for_owners([], "group_project_b")
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

  test "a foreign Agent row with a look-alike Task payload is never selected" do
    {:ok, _} =
      Schedules.create(
        rec("imposter", %{
          "agent_id" => "agent_foreign",
          "payload" => %{"agent_group_id" => "grp_1"}
        }),
        1
      )

    assert {:ok, []} = Schedules.list_for_owners(["agent_mine"], "grp_1")
  end

  @tag :access_plan
  test "the owner listing never falls back to a scan proportional to the global table" do
    # Reviewer repro shape: enough rows that the planner would prefer a
    # sequential scan if the OR were not fully index-backed.
    Repo.query!("""
    INSERT INTO schedules
      (id, receiver, agent_id, prompt, interval_minutes, status, attrs,
       created_at, next_fire_at)
    SELECT 'probe-' || g, 'agent', 'agent-' || g, 'p', 5, 'active', '{}'::jsonb,
           1000, 301000
    FROM generate_series(1, 100_000) AS g
    """)

    Repo.query!("""
    INSERT INTO schedules
      (id, receiver, payload, prompt, interval_minutes, status, attrs,
       created_at, next_fire_at)
    SELECT 'probe-task-' || g, 'task',
           jsonb_build_object('agent_group_id', 'grp-' || g), 'p', 5, 'active',
           '{}'::jsonb, 1000, 301000
    FROM generate_series(1, 10_000) AS g
    """)

    Repo.query!("ANALYZE schedules")

    plan = Schedules.explain_list_for_owners(["agent-1", "agent-2"], "grp-1")

    refute plan =~ "Seq Scan",
           "owner listing must stay index-backed under load, got plan:\n" <> plan

    assert plan =~ "schedules_task_group_idx"
    assert plan =~ "schedules_agent_id_index"
  end

  test "list_by_agents returns only the owners' rows" do
    {:ok, _} = Schedules.create(rec("mine_a", %{"agent_id" => "agent_a"}), 1)
    {:ok, _} = Schedules.create(rec("mine_b", %{"agent_id" => "agent_b"}), 1)
    {:ok, _} = Schedules.create(rec("other", %{"agent_id" => "agent_z"}), 1)

    assert {:ok, rows} = Schedules.list_by_agents(["agent_a", "agent_b"])
    assert Enum.sort(Enum.map(rows, & &1["id"])) == ["mine_a", "mine_b"]
    assert {:ok, []} = Schedules.list_by_agents([])
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

  test "update serializes read-modify-write and propagates fun errors" do
    assert {:error, :not_found} = Schedules.update("nope", fn r -> {:ok, r, 1} end)

    {:ok, _} = Schedules.create(rec("s1"), 301_000)

    assert {:ok, updated} =
             Schedules.update("s1", fn current ->
               {:ok, Map.put(current, "interval_minutes", 10), 601_000}
             end)

    assert updated["interval_minutes"] == 10

    assert {:error, :invalid_schedule} =
             Schedules.update("s1", fn _ -> {:error, :invalid_schedule} end)

    assert {:ok, %{"interval_minutes" => 10}} = Schedules.get("s1")
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

    test "the unarchive resume (stamp: true) resumes marked rows and stamps every row with the epoch" do
      {:ok, _} = Schedules.create(rec("s1"), 301_000)
      {:ok, _} = Schedules.create(rec("s2", %{"status" => "paused"}), 301_000)
      {:ok, _} = Schedules.create(rec("s3", %{"agent_id" => "agent_b"}), 301_000)
      assert {:ok, 1} = Schedules.pause_for_archived_agent("agent_a", 1, 400_000)

      # Both of agent_a's rows are written: s1 resumed, s2 left user-paused,
      # both stamped.
      assert {:ok, 2} = Schedules.resume_archive_paused("agent_a", 1, 500_000, stamp: true)

      assert {:ok, %{"status" => "active", "unarchived_epoch" => 1} = s1} = Schedules.get("s1")
      refute Map.has_key?(s1, "paused_by")
      assert {:ok, %{"status" => "paused", "unarchived_epoch" => 1} = s2} = Schedules.get("s2")
      refute Map.has_key?(s2, "paused_by")
      assert {:ok, s3} = Schedules.get("s3")
      refute Map.has_key?(s3, "unarchived_epoch")

      # Idempotent for the epoch; a late pause for it is now fenced.
      assert {:ok, 0} = Schedules.resume_archive_paused("agent_a", 1, 500_001, stamp: true)
      assert {:ok, 0} = Schedules.pause_for_archived_agent("agent_a", 1, 600_000)
      assert {:ok, %{"status" => "active"}} = Schedules.get("s1")
    end
  end
end
