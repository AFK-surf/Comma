defmodule SalixStore.SchedulesCutoverTest do
  # Shares the node-global Fake bucket and control tables; keep serial.
  use ExUnit.Case, async: false

  alias SalixStore.{Keys, Repo, S3, Schedules, SchedulesCutover}

  setup do
    S3.Fake.reset()
    Repo.query!("TRUNCATE schedules, schedule_runs")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'schedules_v1'")

    on_exit(fn ->
      S3.Fake.reset()

      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('schedules_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    :ok
  end

  defp seed(id, body) do
    body = Map.put_new(body, "id", id)
    {:ok, _} = S3.put(Keys.schedule(id), Jason.encode!(body), [])
    body
  end

  test "imports every legacy writer shape, verifies equality, persists the marker, re-runs" do
    # SalixCluster interval shape (explicit nil last_run, task receiver payload).
    seed("sch_interval", %{
      "receiver" => "agent",
      "agent_id" => "agent_a",
      "prompt" => "check in",
      "interval_minutes" => 5,
      "created_at" => 1_753_300_000_000,
      "last_run" => nil
    })

    # Cron shape with timezone.
    seed("sch_cron", %{
      "receiver" => "agent",
      "agent_id" => "agent_b",
      "prompt" => "daily",
      "cron" => "0 9 * * *",
      "timezone" => "Asia/Shanghai",
      "created_at" => 1_753_300_000_000,
      "last_run" => 1_753_500_000_000
    })

    # Task receiver shape.
    seed("sch_task", %{
      "receiver" => "task",
      "payload" => %{"agent_group_id" => "grp_1", "conversation_id" => "conv_1"},
      "interval_minutes" => 60,
      "created_at" => 1_753_300_000_000,
      "last_run" => nil
    })

    # SalixAgent heartbeat shape: kind/name/cron_expr/status ride attrs; the
    # decorative-status history and result echoes must round-trip verbatim.
    seed("sch_heartbeat", %{
      "agent_id" => "agent_c",
      "kind" => "heartbeat",
      "name" => "Heartbeat",
      "prompt" => "hb",
      "cron_expr" => "0 */12 * * *",
      "timezone" => "UTC",
      "interval_minutes" => 720,
      "status" => "active",
      "created_at" => 1_753_300_000_000,
      "updated_at" => 1_753_300_000_000,
      "last_run" => nil,
      "last_result" => "ok",
      "template_id" => "tpl_1"
    })

    assert :ok = SchedulesCutover.run()
    assert SchedulesCutover.marker_present?()

    assert {:ok, cron} = Schedules.get("sch_cron")
    assert cron["timezone"] == "Asia/Shanghai"
    assert cron["last_run"] == 1_753_500_000_000

    assert {:ok, task} = Schedules.get("sch_task")
    assert task["payload"] == %{"agent_group_id" => "grp_1", "conversation_id" => "conv_1"}
    assert task["receiver"] == "task"

    assert {:ok, hb} = Schedules.get("sch_heartbeat")
    assert hb["kind"] == "heartbeat"
    assert hb["cron_expr"] == "0 */12 * * *"
    assert hb["last_result"] == "ok"
    assert hb["template_id"] == "tpl_1"
    assert hb["status"] == "active"

    # Idempotent: the exact step retries cleanly.
    assert :ok = SchedulesCutover.run()
  end

  test "imported anchors are valid due-scan lower bounds" do
    # last_run in the past: the candidate scan must surface it even though the
    # true next fire (anchor + interval) is derived only by the domain sweep.
    seed("sch_bound", %{
      "agent_id" => "agent_a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "created_at" => 1_753_300_000_000,
      "last_run" => 1_753_500_000_000
    })

    assert :ok = SchedulesCutover.run()

    assert {:ok, [%{"id" => "sch_bound"}]} =
             Schedules.due_candidates(1_753_500_000_001)

    # Strictly before the anchor: not a candidate.
    assert {:ok, []} = Schedules.due_candidates(1_753_499_999_999)
  end

  test "a paused legacy record imports verbatim and is excluded from the due scan" do
    seed("sch_paused", %{
      "agent_id" => "agent_a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "status" => "paused",
      "created_at" => 1_753_300_000_000,
      "last_run" => nil
    })

    assert :ok = SchedulesCutover.run()

    assert {:ok, %{"status" => "paused"}} = Schedules.get("sch_paused")
    # Pause is real now: the due scan never surfaces it.
    assert {:ok, []} = Schedules.due_candidates(1_999_999_999_999)
  end

  test "an empty control store cuts over to a trivially-equal marker" do
    assert :ok = SchedulesCutover.run()
    assert SchedulesCutover.marker_present?()
    assert {:ok, %{"schedules" => 0}} = SchedulesCutover.importable_count()
  end

  test "a re-run after a PG-only delete does not resurrect the record (terminal fence)" do
    seed("sch_del", %{
      "agent_id" => "agent_a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "created_at" => 1_753_300_000_000,
      "last_run" => nil
    })

    assert :ok = SchedulesCutover.run()
    assert {:ok, _} = Schedules.get("sch_del")

    assert :ok = Schedules.delete("sch_del")
    assert {:error, :not_found} = Schedules.get("sch_del")
    # S3 object is deliberately still present (PR-B clears it later).
    assert {:ok, _} = S3.get(Keys.schedule("sch_del"))

    assert :ok = SchedulesCutover.run()
    assert {:error, :not_found} = Schedules.get("sch_del")
  end

  test "an unreadable marker aborts the run without importing" do
    seed("sch_x", %{
      "agent_id" => "a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "created_at" => 1,
      "last_run" => nil
    })

    Repo.query!("ALTER TABLE salix_cutover_markers RENAME TO salix_cutover_markers_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE salix_cutover_markers_tmp RENAME TO salix_cutover_markers")
    end)

    assert {:error, {:marker_unreadable, _}} = SchedulesCutover.run()
    assert {:error, :not_found} = Schedules.get("sch_x")
  end

  test "a body whose id does not round-trip to its key aborts the cutover" do
    key = Keys.schedule("sch_actual")

    {:ok, _} =
      S3.put(
        key,
        Jason.encode!(%{
          "id" => "sch_other",
          "agent_id" => "a",
          "prompt" => "p",
          "interval_minutes" => 5,
          "created_at" => 1
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^key, :record_address_mismatch}} = SchedulesCutover.run()
  end

  test "a missing created_at aborts run/0 before any PG write, even sorting after a valid record" do
    # sch_a sorts before sch_z: the valid record is enumerated first; the whole
    # enumeration must still abort with zero PG writes (no partial import).
    seed("sch_a", %{
      "agent_id" => "a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "created_at" => 1_753_300_000_000,
      "last_run" => nil
    })

    bad_key = Keys.schedule("sch_z")

    {:ok, _} =
      S3.put(
        bad_key,
        Jason.encode!(%{"agent_id" => "a", "prompt" => "p", "interval_minutes" => 5}),
        []
      )

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} =
             SchedulesCutover.importable_count()

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} = SchedulesCutover.run()
    refute SchedulesCutover.marker_present?()
    assert {:error, :not_found} = Schedules.get("sch_a")
  end

  test "an int8-overflow timestamp fails closed with no partial import" do
    seed("sch_a", %{
      "agent_id" => "a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "created_at" => 1_753_300_000_000,
      "last_run" => nil
    })

    bad_key = Keys.schedule("sch_z")

    {:ok, _} =
      S3.put(
        bad_key,
        Jason.encode!(%{
          "agent_id" => "a",
          "prompt" => "p",
          "interval_minutes" => 5,
          # One past the largest value a Postgres bigint column materializes;
          # the insert would raise mid-import.
          "created_at" => 9_223_372_036_854_775_808
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} =
             SchedulesCutover.importable_count()

    assert {:error, {:enumerate_failed, ^bad_key, :invalid_record}} = SchedulesCutover.run()
    refute SchedulesCutover.marker_present?()
    assert {:error, :not_found} = Schedules.get("sch_a")
  end

  test "a non-string column value (list prompt) fails closed as invalid_record" do
    key = Keys.schedule("sch_badcol")

    {:ok, _} =
      S3.put(
        key,
        Jason.encode!(%{
          "agent_id" => "a",
          "prompt" => ["not", "a", "string"],
          "interval_minutes" => 5,
          "created_at" => 1
        }),
        []
      )

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} = SchedulesCutover.run()
  end

  test "a non-map (top-level array) body fails closed as enumerate_failed, not a raise" do
    key = Keys.schedule("sch_arr")
    {:ok, _} = S3.put(key, Jason.encode!([1, 2, 3]), [])

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} =
             SchedulesCutover.importable_count()

    assert {:error, {:enumerate_failed, ^key, :invalid_record}} = SchedulesCutover.run()
    refute SchedulesCutover.marker_present?()
  end

  test "enumeration is fail-closed on a GET fault" do
    key = Keys.schedule("sch_i")

    seed("sch_i", %{
      "agent_id" => "a",
      "prompt" => "p",
      "interval_minutes" => 5,
      "created_at" => 1,
      "last_run" => nil
    })

    S3.Fake.set_fault({:fail, 503, :get, key})
    assert {:error, {:enumerate_failed, ^key, _}} = SchedulesCutover.run()
    refute SchedulesCutover.marker_present?()
  end

  test "a PG-only row fails the equality gate" do
    :ok =
      Schedules.import_record(
        %{
          "id" => "sch_pg_only",
          "agent_id" => "a",
          "prompt" => "p",
          "interval_minutes" => 5,
          "created_at" => 1,
          "last_run" => nil
        },
        1
      )

    # S3 is empty, PG has one row -> mismatch.
    assert {:error, {:mismatch, :schedules}} = SchedulesCutover.run()
    refute SchedulesCutover.marker_present?()
  end
end
