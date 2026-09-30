defmodule BridgeForTeams.StorageMetering.ReconcilerTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Orgs, Projects}
  alias BridgeForTeams.Schema.StorageMeteringScan
  alias BridgeForTeams.StorageMetering.Reconciler

  setup do
    n = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Metering #{n}", "slug" => "metering-#{n}"})

    projects =
      for index <- 1..3 do
        {:ok, project} =
          Projects.create_project(org.id, %{
            "name" => "Metered #{index}",
            "slug" => "metered-#{n}-#{index}"
          })

        project
      end

    %{org: org, projects: projects}
  end

  test "keyset cursor reaches projects beyond one bounded page", %{projects: projects} do
    parent = self()
    now_ms = System.system_time(:millisecond)

    opts = [
      limit: 2,
      now_ms: now_ms,
      list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
      metering_fun: fn fact ->
        send(parent, {:metered, fact.owner_snapshot["project_id"]})
        {:ok, :charged}
      end
    ]

    first = Reconciler.run_once(opts)
    first_projects = drain_metered_projects()

    second = Reconciler.run_once(Keyword.put(opts, :now_ms, now_ms + 3_600_000))
    second_projects = drain_metered_projects()

    assert first.claimed
    assert second.claimed
    assert first.scopes_seen <= 14
    assert second.scopes_seen <= 14

    assert MapSet.subset?(
             MapSet.new(Enum.map(projects, & &1.id)),
             MapSet.union(first_projects, second_projects)
           )
  end

  test "metering failure does not advance the checkpoint and retry reuses the stable key", %{
    projects: [_project | _]
  } do
    parent = self()
    now_ms = System.system_time(:millisecond)

    failed =
      Reconciler.run_once(
        limit: 1,
        now_ms: now_ms,
        list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
        metering_fun: fn fact ->
          send(parent, {:failed_key, fact.source_key})
          {:error, :billing_unavailable}
        end
      )

    failed_keys = drain_keys(:failed_key)
    scan = Repo.get!(StorageMeteringScan, "bridge-storage-metering")

    assert failed.failed > 0
    assert scan.generation == 1
    assert scan.sampled_at

    succeeded =
      Reconciler.run_once(
        limit: 1,
        now_ms: now_ms + 60_000,
        list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
        metering_fun: fn fact ->
          send(parent, {:retried_key, fact.source_key})
          {:ok, :charged}
        end
      )

    retried_keys = drain_keys(:retried_key)

    assert succeeded.failed == 0
    assert MapSet.equal?(failed_keys, retried_keys)
    assert Enum.all?(retried_keys, &String.starts_with?(&1, "storage:bridge:"))
    assert Repo.get!(StorageMeteringScan, "bridge-storage-metering").generation == 2
  end

  test "a second worker cannot sample a claimed page", %{projects: [_ | _]} do
    parent = self()
    now_ms = System.system_time(:millisecond)

    first =
      Task.async(fn ->
        Reconciler.run_once(
          limit: 1,
          now_ms: now_ms,
          lease_ttl_ms: 60_000,
          list_fun: fn _prefix, _opts ->
            if Process.get(:storage_list_released) do
              {:ok, [%{size: 10}]}
            else
              send(parent, {:storage_list_blocked, self()})

              receive do
                :release_storage_list ->
                  Process.put(:storage_list_released, true)
                  {:ok, [%{size: 10}]}
              end
            end
          end,
          metering_fun: fn _fact -> {:ok, :charged} end
        )
      end)

    assert_receive {:storage_list_blocked, blocked_pid}

    assert %{claimed: false, sampled: 0} =
             Reconciler.run_once(
               limit: 1,
               now_ms: now_ms,
               lease_ttl_ms: 60_000,
               list_fun: fn _prefix, _opts ->
                 flunk("losing worker must not reach storage")
               end,
               metering_fun: fn _fact -> {:ok, :charged} end
             )

    send(blocked_pid, :release_storage_list)
    assert %{claimed: true, failed: 0} = Task.await(first, 5_000)
  end

  test "retry only meters scopes whose generation checkpoint is still missing", %{
    projects: [_ | _]
  } do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    now_ms = System.system_time(:millisecond)

    first =
      Reconciler.run_once(
        limit: 1,
        now_ms: now_ms,
        list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
        metering_fun: fn fact ->
          attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
          send(parent, {:first_attempt, fact.source_key})
          if attempt == 2, do: {:error, :billing_unavailable}, else: {:ok, :charged}
        end
      )

    first_keys = drain_keys(:first_attempt)
    assert first.failed == 1

    retried =
      Reconciler.run_once(
        limit: 1,
        now_ms: now_ms + 60_000,
        list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
        metering_fun: fn fact ->
          send(parent, {:second_attempt, fact.source_key})
          {:ok, :charged}
        end
      )

    second_keys = drain_keys(:second_attempt)
    assert retried.failed == 0
    assert MapSet.size(second_keys) == 1
    assert MapSet.subset?(second_keys, first_keys)
  end

  test "kill after billing success is recovered with the same source key", %{projects: [_ | _]} do
    parent = self()
    now_ms = System.system_time(:millisecond)

    first =
      Task.async(fn ->
        Reconciler.run_once(
          limit: 1,
          now_ms: now_ms,
          lease_ttl_ms: 10,
          list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
          metering_fun: fn fact ->
            send(parent, {:charged_before_kill, fact.source_key, self()})

            receive do
              :never -> {:ok, :charged}
            end
          end
        )
      end)

    assert_receive {:charged_before_kill, source_key, blocked_pid}
    assert blocked_pid == first.pid
    _ = Task.shutdown(first, :brutal_kill)

    recovered =
      Reconciler.run_once(
        limit: 1,
        now_ms: now_ms + 20,
        lease_ttl_ms: 10,
        list_fun: fn _prefix, _opts -> {:ok, [%{size: 10}]} end,
        metering_fun: fn fact ->
          send(parent, {:recovered_key, fact.source_key})
          {:ok, :idempotent}
        end
      )

    assert recovered.claimed
    assert_receive {:recovered_key, ^source_key}
  end

  defp drain_metered_projects(acc \\ MapSet.new()) do
    receive do
      {:metered, project_id} -> drain_metered_projects(MapSet.put(acc, project_id))
    after
      0 -> acc
    end
  end

  defp drain_keys(tag, acc \\ MapSet.new()) do
    receive do
      {^tag, key} -> drain_keys(tag, MapSet.put(acc, key))
    after
      0 -> acc
    end
  end
end
