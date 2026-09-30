defmodule SalixAgent.ArchivedScheduleSweepTest do
  # Shares the node-global schedules table; keep serial.
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentControl, ArchivedScheduleSweep, ArchivedSchedules}
  alias SalixStore.{Keys, S3, Schedules}

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if is_nil(prev),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, prev)
    end)

    :ok
  end

  defp agent!(archived?) do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{})

    # Archive by writing the record directly: the pre-#849 shape the sweep
    # exists for (archived, no epoch, schedules never paused).
    if archived? do
      key = Keys.ctl_agent(agent_id)
      {:ok, %{body: body, etag: etag}} = S3.get(key)
      rec = body |> Jason.decode!() |> Map.put("archived_at", 1)
      {:ok, _} = S3.put(key, Jason.encode!(rec), if_match: etag)
    end

    agent_id
  end

  defp schedule!(id, agent_id, overrides \\ %{}) do
    {:ok, _} =
      Schedules.create(
        Map.merge(
          %{
            "id" => id,
            "agent_id" => agent_id,
            "prompt" => "p",
            "interval_minutes" => 5,
            "created_at" => 1_000
          },
          overrides
        ),
        301_000
      )
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  test "reconciles both directions, once: archived agents' rows paused, stale pauses on live agents resumed" do
    archived = agent!(true)
    live = agent!(false)
    schedule!("arch-1", archived)
    schedule!("arch-2", archived)
    schedule!("arch-user-paused", archived, %{"status" => "paused"})
    schedule!("live-1", live)
    # A stale pause whose re-validation never ran: live agent, archive-paused row.
    schedule!("live-stranded", live, %{"status" => "paused", "paused_by" => "archive"})

    # Dry run: the counts, and nothing written.
    assert {:ok,
            %{archived_agents: 1, schedules_paused: 2, schedules_resumed: 1, dry_run: true} = dry} =
             ArchivedScheduleSweep.run(dry_run: true)

    assert dry.failed == []
    assert dry.agents_scanned >= 2
    assert {:ok, %{"status" => "active"}} = Schedules.get("arch-1")
    assert {:ok, %{"status" => "paused"}} = Schedules.get("live-stranded")

    assert {:ok, %{archived_agents: 1, schedules_paused: 2, schedules_resumed: 1, failed: []}} =
             ArchivedScheduleSweep.run(now_ms: 400_000)

    for id <- ["arch-1", "arch-2"] do
      assert {:ok,
              %{
                "status" => "paused",
                "paused_by" => "archive",
                "archive_epoch" => 1,
                "updated_at" => 400_000
              }} = Schedules.get(id)
    end

    assert {:ok, %{"status" => "paused"} = user_paused} = Schedules.get("arch-user-paused")
    refute Map.has_key?(user_paused, "paused_by")
    assert {:ok, %{"status" => "active"}} = Schedules.get("live-1")
    assert {:ok, %{"status" => "active"} = healed} = Schedules.get("live-stranded")
    refute Map.has_key?(healed, "paused_by")

    # Idempotent: a second pass finds nothing left to do.
    assert {:ok, %{archived_agents: 1, schedules_paused: 0, schedules_resumed: 0}} =
             ArchivedScheduleSweep.run()
  end

  # The #1509 review blocker: the sweep materializes "archived" from S3 and
  # acts on it later. If an unarchive completes in between, an unfenced pause
  # would leave a LIVE agent with archive-paused schedules — and nothing would
  # ever resume them. Reproduced by parking the sweep's record GET.
  test "a sweep acting on a stale archived read does not strand an unarchived agent" do
    archived = agent!(true)
    {:ok, rec} = AgentControl.get_record(archived)
    schedule!("old-1", archived)

    :ok = S3.Fake.set_fault({:pause, :get, Keys.ctl_agent(archived)})
    sweep = Task.async(fn -> ArchivedScheduleSweep.run(now_ms: 400_000) end)
    wait_until(fn -> S3.Fake.paused?() end)

    # The unarchive runs to completion while the sweep holds its archived
    # observation, and the live agent then gains a schedule the unarchive
    # could not have stamped.
    assert {:ok, _} = AgentControl.unarchive(archived, rec["tenant_id"])
    assert {:ok, %{"status" => "active", "unarchived_epoch" => 1}} = Schedules.get("old-1")
    schedule!("new-1", archived)

    :ok = S3.Fake.release_pause()
    assert {:ok, summary} = Task.await(sweep, 5_000)

    # old-1 was fenced by the unarchive's stamp; new-1 was paused on the stale
    # read and resumed by the re-validation. Neither is stranded.
    assert summary.schedules_paused == 1
    assert summary.schedules_resumed == 1

    for id <- ["old-1", "new-1"] do
      assert {:ok, %{"status" => "active"} = row} = Schedules.get(id)
      refute Map.has_key?(row, "paused_by")
    end

    {:ok, live} = AgentControl.get_record(archived)
    refute ArchivedSchedules.archived?(live)
    assert ArchivedSchedules.archive_epoch(live) == 1
  end

  test "archive bumps the epoch; a re-archive after unarchive pauses again despite the old stamp" do
    agent_id = agent!(false)
    {:ok, rec} = AgentControl.get_record(agent_id)
    tenant_id = rec["tenant_id"]
    schedule!("s1", agent_id)

    assert {:ok, archived} = AgentControl.delete(agent_id)
    assert ArchivedSchedules.archive_epoch(archived) == 1
    assert {:ok, %{"status" => "paused", "archive_epoch" => 1}} = Schedules.get("s1")

    assert {:ok, _} = AgentControl.unarchive(agent_id, tenant_id)
    assert {:ok, %{"status" => "active", "unarchived_epoch" => 1}} = Schedules.get("s1")

    assert {:ok, archived_again} = AgentControl.delete(agent_id)
    assert ArchivedSchedules.archive_epoch(archived_again) == 2
    assert {:ok, %{"status" => "paused", "archive_epoch" => 2}} = Schedules.get("s1")

    # Re-deleting an archived agent keeps its epoch.
    assert {:ok, still} = AgentControl.delete(agent_id)
    assert ArchivedSchedules.archive_epoch(still) == 2
  end

  # #1509 round-2 review: the unarchive's record clear must be conditional
  # on the epoch it resumed for. `update_record/2` re-applies its function
  # after a 412; a function that cleared whatever it found — writing back
  # the captured epoch — would clear a NEWER archive and regress the epoch,
  # leaving a live agent with rows paused for the archive it just erased.
  test "a delayed unarchive clear does not erase a newer archive (exact-epoch conditional write)" do
    agent_id = agent!(false)
    {:ok, rec} = AgentControl.get_record(agent_id)
    tenant_id = rec["tenant_id"]
    key = Keys.ctl_agent(agent_id)
    schedule!("s1", agent_id)

    assert {:ok, _} = AgentControl.delete(agent_id)
    assert {:ok, %{"status" => "paused", "archive_epoch" => 1}} = Schedules.get("s1")

    # U1 reads epoch 1, resumes and stamps, and its clear PUT is parked.
    :ok = S3.Fake.set_fault({:pause, :put, key})
    u1 = Task.async(fn -> AgentControl.unarchive(agent_id, tenant_id) end)
    wait_until(fn -> S3.Fake.paused?() end)
    assert {:ok, %{"status" => "active", "unarchived_epoch" => 1}} = Schedules.get("s1")

    # U2 completes epoch 1's unarchive; the agent is archived again at epoch
    # 2 and its schedule is paused for epoch 2.
    assert {:ok, _} = AgentControl.unarchive(agent_id, tenant_id)
    assert {:ok, again} = AgentControl.delete(agent_id)
    assert ArchivedSchedules.archive_epoch(again) == 2
    assert {:ok, %{"status" => "paused", "archive_epoch" => 2}} = Schedules.get("s1")

    # U1's parked PUT takes a 412; the retry finds epoch 2 and must refuse.
    :ok = S3.Fake.release_pause()
    assert {:error, :conflict} = Task.await(u1, 5_000)

    {:ok, current} = AgentControl.get_record(agent_id)
    assert ArchivedSchedules.archived?(current)
    assert ArchivedSchedules.archive_epoch(current) == 2
    assert {:ok, %{"status" => "paused", "archive_epoch" => 2}} = Schedules.get("s1")

    # The epoch-2 unarchive still works and resumes the row.
    assert {:ok, _} = AgentControl.unarchive(agent_id, tenant_id)
    assert {:ok, %{"status" => "active", "unarchived_epoch" => 2}} = Schedules.get("s1")
  end

  test "a duplicate unarchive of the same epoch that lost the write still succeeds" do
    agent_id = agent!(false)
    {:ok, rec} = AgentControl.get_record(agent_id)
    tenant_id = rec["tenant_id"]
    key = Keys.ctl_agent(agent_id)
    schedule!("s1", agent_id)
    assert {:ok, _} = AgentControl.delete(agent_id)

    :ok = S3.Fake.set_fault({:pause, :put, key})
    u1 = Task.async(fn -> AgentControl.unarchive(agent_id, tenant_id) end)
    wait_until(fn -> S3.Fake.paused?() end)
    assert {:ok, _} = AgentControl.unarchive(agent_id, tenant_id)
    :ok = S3.Fake.release_pause()

    # Its epoch's unarchive landed: the desired end state holds, nothing to write.
    assert {:ok, _} = Task.await(u1, 5_000)
    {:ok, current} = AgentControl.get_record(agent_id)
    refute ArchivedSchedules.archived?(current)
    assert ArchivedSchedules.archive_epoch(current) == 1
    assert {:ok, %{"status" => "active", "unarchived_epoch" => 1}} = Schedules.get("s1")
  end
end
