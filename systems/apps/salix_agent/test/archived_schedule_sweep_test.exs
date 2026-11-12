defmodule SalixAgent.ArchivedScheduleSweepTest do
  # Shares the node-global schedules table; keep serial.
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{AgentControl, ArchivedScheduleSweep, ArchivedSchedules}
  alias SalixStore.{AgentPGStore, Repo, S3, Schedules}

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs, salix_agents CASCADE")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if is_nil(prev),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
    end)

    :ok
  end

  defp agent!(archived?) do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{})

    # Archive by writing the record directly: the pre-#849 shape the sweep
    # exists for (archived, no epoch, schedules never paused).
    if archived? do
      {:ok, %{record: record, revision: revision}} = AgentPGStore.read_config(agent_id)
      {:ok, _} = AgentPGStore.put_config(agent_id, Map.put(record, "archived_at", 1), revision)
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
    schedule!("s1", agent_id)
    parent = SystemsRuntime.Proc.self()
    assert {:ok, _} = AgentControl.delete(agent_id)
    assert {:ok, %{"status" => "paused", "archive_epoch" => 1}} = Schedules.get("s1")

    assert {:ok, u1} =
             Repo.transaction(fn ->
               Repo.query!("SELECT agent_id FROM salix_agents WHERE agent_id = $1 FOR UPDATE", [
                 agent_id
               ])

               delayed =
                 SystemsRuntime.Task.async(fn ->
                   Repo.checkout(fn ->
                     %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                     SystemsRuntime.Proc.send(parent, {:unarchive_backend, backend_pid})
                     AgentControl.unarchive(agent_id, tenant_id)
                   end)
                 end)

               settle_receive({:unarchive_backend, backend_pid})
               assert wait_for_lock(backend_pid)

               assert {:ok, %{"status" => "active", "unarchived_epoch" => 1}} =
                        Schedules.get("s1")

               # The holder of the Agent lock completes the old unarchive and archives
               # again before the delayed conditional clear can acquire that lock.
               assert {:ok, _} = AgentControl.unarchive(agent_id, tenant_id)
               assert {:ok, again} = AgentControl.delete(agent_id)
               assert ArchivedSchedules.archive_epoch(again) == 2
               assert {:ok, %{"status" => "paused", "archive_epoch" => 2}} = Schedules.get("s1")
               delayed
             end)

    assert {:error, :conflict} = settled_await(u1)

    {:ok, current} = AgentControl.get_record(agent_id)
    assert ArchivedSchedules.archived?(current)
    assert ArchivedSchedules.archive_epoch(current) == 2
    assert {:ok, %{"status" => "paused", "archive_epoch" => 2}} = Schedules.get("s1")

    # The epoch-2 unarchive still works and resumes the row.
    assert {:ok, _} = AgentControl.unarchive(agent_id, tenant_id)
    assert {:ok, %{"status" => "active", "unarchived_epoch" => 2}} = Schedules.get("s1")
  end

  defp wait_for_lock(backend_pid) do
    settle_until(fn ->
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid]).rows ==
        [["Lock"]]
    end)
  end
end
