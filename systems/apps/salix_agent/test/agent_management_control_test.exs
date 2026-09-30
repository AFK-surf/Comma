defmodule SalixAgent.AgentManagementControlTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Control
  alias SalixStore.{Ids, Keys, S3}

  setup do
    old = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, old)
    end)

    %{tenant: tenant, group: group}
  end

  test "worker enumeration reaches beyond 100 records using one bounded storage page", ctx do
    workers = Enum.map(1..105, fn n -> worker(ctx, %{"name" => "worker #{n}"}) end)

    {seen, calls} =
      Enum.reduce(1..3, {[], nil}, fn _, {seen, cursor} ->
        S3.Fake.reset_read_log()

        assert {:ok, page} =
                 Control.page_workers(ctx.tenant, ctx.group, limit: 50, cursor: cursor)

        reads = S3.Fake.read_log()
        assert Enum.count(reads, &match?({:list, _, _}, &1)) == 1
        assert Enum.count(reads, &match?({:get, _}, &1)) <= 50
        assert page.returned_count == length(page.items)
        {seen ++ Enum.map(page.items, & &1["agent_id"]), page.next_cursor}
      end)

    assert calls == nil
    assert Enum.sort(seen) == Enum.sort(Enum.map(workers, & &1["agent_id"]))
  end

  test "filtered empty pages preserve progress and cursors cannot change scope or filters", ctx do
    Enum.each(1..3, fn _ -> worker(ctx) end)

    assert {:ok, %{items: [], next_cursor: cursor}} =
             Control.page_workers(ctx.tenant, ctx.group, limit: 1, runtime_source: "connected")

    assert is_binary(cursor)

    assert {:error, :invalid_cursor} =
             Control.page_workers(ctx.tenant, ctx.group, limit: 1, cursor: cursor)

    assert {:error, :invalid_cursor} =
             Control.page_workers(ctx.tenant, Ids.new_group_id(ctx.tenant),
               cursor: cursor,
               runtime_source: "connected"
             )
  end

  test "a failed record read cannot masquerade as an empty successful page", ctx do
    agent = worker(ctx)
    S3.Fake.set_fault({:fail, 503, :get, Keys.ctl_agent(agent["agent_id"])})
    assert {:error, :read_unavailable} = Control.page_workers(ctx.tenant, ctx.group)
  end

  test "ambiguous configuration writes expose their actual state to caller recovery", ctx do
    agent = worker(ctx)
    S3.Fake.set_fault({:ambiguous_after, :put, Keys.ctl_agent(agent["agent_id"])})

    assert {:error, _} =
             Control.configure(
               agent["agent_id"],
               %{"name" => "Reviewer", "purpose" => "Review"},
               ctx.tenant
             )

    assert {:ok, record} = Control.get(agent["agent_id"])
    assert record["name"] == "Reviewer"
    assert record["management_purpose"] == "Review"
  end

  test "permanent archive survives restore, stale metadata, same-id create and repeated archive",
       ctx do
    agent = worker(ctx)
    id = agent["agent_id"]
    schedule_id = "permanent-" <> id
    stale_admission = %{"kind" => "migration", "operation_id" => "archive-test-migration"}

    assert {:ok, _} =
             S3.put(
               Keys.ctl_agent(id),
               Jason.encode!(Map.put(agent, "session_admission", stale_admission))
             )

    assert {:ok, _} =
             SalixStore.Schedules.create(
               %{
                 "id" => schedule_id,
                 "agent_id" => id,
                 "prompt" => "p",
                 "interval_minutes" => 5,
                 "created_at" => 1_000
               },
               301_000
             )

    assert {:ok, archived} = Control.archive_permanently(id, ctx.tenant)
    assert {:ok, paused} = SalixStore.Schedules.get(schedule_id)
    assert paused["status"] == "paused"
    assert paused["paused_by"] == "archive"
    assert archived["permanent_archive"] == true
    refute Map.has_key?(archived, "session_admission")

    assert {:ok, _} =
             S3.put(
               Keys.ctl_agent(id),
               Jason.encode!(Map.put(archived, "session_admission", stale_admission))
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.RoundConfig.build_round_config(id, "worker", %{})

    assert {:error, {:bad_request, "agent is archived"}} = SalixAgent.Fleet.ensure_started(id)
    assert {:ok, ^archived} = Control.archive_permanently(id, ctx.tenant)
    assert {:error, :agent_permanently_archived} = Control.unarchive(id, ctx.tenant)
    assert {:ok, ^paused} = SalixStore.Schedules.get(schedule_id)
    assert {:error, :agent_permanently_archived} = Control.configure(id, %{"status" => "idle"})

    assert {:error, :agent_permanently_archived} =
             Control.configure(id, %{"name" => "resurrected"})

    assert {:error, :agent_permanently_archived} =
             Control.create_preallocated(%{"group_id" => ctx.group}, ctx.tenant, id)

    assert {:error, _} = Control.wake(id)
    assert {:error, _} = Control.force_recover(id)
    assert {:ok, ^archived} = Control.get_including_archived(id, ctx.tenant)
  end

  test "a reversible archive is not silently made permanent", ctx do
    agent = worker(ctx)
    assert {:ok, _} = Control.delete(agent["agent_id"], ctx.tenant)
    assert {:error, :agent_archived} = Control.archive_permanently(agent["agent_id"], ctx.tenant)
    assert {:ok, _} = Control.unarchive(agent["agent_id"], ctx.tenant)
  end

  test "warm router configuration does not reread catalogs or control", ctx do
    agent = worker(ctx, %{"role" => "router"})
    id = agent["agent_id"]
    assert {:ok, snapshot} = SalixAgent.RoundConfig.build_round_snapshot(id, %{platform: "slack"})
    S3.Fake.reset_read_log()

    assert {:ok, config} =
             SalixAgent.RoundConfig.materialize_round_snapshot(id, snapshot, %{
               platform: "slack",
               source_message_ids: ["new-source"],
               trusted_origins: [%{"source_message_id" => "new-source"}]
             })

    assert config.session_config == snapshot.session_config
    assert S3.Fake.read_log() == []
  end

  defp worker(ctx, attrs \\ %{}) do
    SalixAgent.TestSupport.create_control_agent_in_group!(ctx.tenant, ctx.group, attrs)
  end
end
