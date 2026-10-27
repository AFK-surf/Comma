defmodule SalixWeb.StationPlaceTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  require SystemsRuntime.Proc
  import Ecto.Query
  alias SalixEnv.{Bridge, Registry}
  alias SalixStore.{Compute, Repo, Stations}
  alias SalixStore.Stations.Events

  defmodule Product do
    @behaviour SalixStore.StationMembers
    def role(_, _, _), do: {:ok, "owner"}
    def manager_role?(_), do: true
    def read_only_role?(_), do: false
    def workspace_name(_, _), do: {:ok, "Placement"}
    def workspace_active?(_, _), do: true
  end

  setup do
    previous =
      for {app, key} <- [
            {:salix_web, :station_control_plane},
            {:salix_store, :station_members},
            {:salix_store, :stations},
            {:comma_core, :stations}
          ],
          do: {app, key, SystemsRuntime.fetch_env(app, key)}

    SystemsRuntime.put_env(:salix_web, :station_control_plane, CommaWeb.Stations.CloudStation)
    SystemsRuntime.put_env(:salix_store, :station_members, [Product])
    SystemsRuntime.put_env(:salix_store, :stations, kek: String.duplicate("p", 32))
    SystemsRuntime.put_env(:comma_core, :stations, origin: "http://localhost")

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> SystemsRuntime.put_env(app, key, value)
        {app, key, :error} -> SystemsRuntime.delete_env(app, key)
      end)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Station placement"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Placement"}, tenant["tenant_id"])

    {:ok, record, :created} =
      Compute.ensure_group_workload(%{
        "tenant_id" => tenant["tenant_id"],
        "group_id" => group["group_id"],
        "provider" => "cloudflare",
        "provider_resource_id" => "cf-place",
        "provider_resource_name" => "cf-place",
        "provider_spec" => %{"profile_key" => "station.default"},
        "device_id" => SalixStore.RuntimeIds.cloud_vm_device_id(group["group_id"]),
        "connector_id" => "conn-place-" <> group["group_id"],
        "env_id" => "place-" <> group["group_id"],
        "status" => "ready"
      })

    %{tenant: tenant["tenant_id"], group: group["group_id"], record: record}
  end

  test "a delayed identity from an old generation cannot replace the current roster key", f do
    current = key(f, "current")
    old = key(f, "old")
    admit!(f, current)
    {:ok, _, _} = Compute.update_group_workload(f.group, &Map.put(&1, "station_id", current))
    {context, peer} = connect(f, old, hold_identity: true)
    task = Task.async(fn -> SalixWeb.StationPlace.push(context) end)
    settle_receive({:identity_requested, ^peer})
    advance!(f)
    send(peer, :continue_identity)

    assert {:error, _} = settled_await(task)
    assert {:ok, _station} = Stations.active_station(current)
    assert {:error, :station_removed} = Stations.active_station(old)
    assert {:ok, %{"station_id" => ^current}} = Compute.group_workload(f.group)
    refute_received {:placed, _}
  end

  test "a lost placement ACK keeps the admitted key for exact replacement after a new generation",
       f do
    first = key(f, "first")
    second = key(f, "second")
    unrelated = key(f, "unrelated")
    admit!(f, unrelated)
    {old_context, _peer} = connect(f, first, placement: {:error, :timeout})

    assert {:error, _} = SalixWeb.StationPlace.push(old_context)
    assert {:ok, %{"station_id" => ^first}} = Compute.group_workload(f.group)
    assert {:ok, _station} = Stations.active_station(first)
    advance!(f)
    {current_context, _peer} = connect(f, second)

    assert :ok = SalixWeb.StationPlace.push(current_context)
    assert {:ok, %{"station_id" => ^second}} = Compute.group_workload(f.group)
    assert {:error, :station_removed} = Stations.active_station(first)
    assert {:ok, _station} = Stations.active_station(second)
    assert {:ok, _station} = Stations.active_station(unrelated)
  end

  test "a failed owner write rolls back real roster admission without publishing removal", f do
    previous = key(f, "previous")
    next = key(f, "next")
    admit!(f, previous)
    {:ok, _, _} = Compute.update_group_workload(f.group, &Map.put(&1, "station_id", previous))
    :ok = Events.subscribe(Events.station_topic(previous))
    :ok = Events.subscribe(Events.station_topic(next))
    :ok = Events.subscribe(Events.group_topic(f.group))

    constraint =
      "station_place_" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

    Repo.query!(
      "ALTER TABLE compute_workloads ADD CONSTRAINT #{constraint} CHECK " <>
        "(id <> '#{f.record["workload_id"]}' OR " <>
        "spec->'device'->>'station_id' IS DISTINCT FROM '#{next}')"
    )

    on_exit(fn -> Repo.query!("ALTER TABLE compute_workloads DROP CONSTRAINT #{constraint}") end)
    {context, _peer} = connect(f, next)

    result =
      try do
        SalixWeb.StationPlace.push(context)
      rescue
        _ -> {:error, :owner_write_failed}
      end

    assert {:error, _} = result
    assert {:ok, _station} = Stations.active_station(previous)
    assert {:error, :station_removed} = Stations.active_station(next)
    assert {:ok, %{"station_id" => ^previous}} = Compute.group_workload(f.group)
    refute_received {:comma_station, :removed}
    refute_received {:comma_station, :changed}
    refute_received {:comma_station_ws, :roster}
    refute_received {:placed, _}
  end

  defp connect(f, station, opts \\ []) do
    {:ok, record} = Compute.group_workload(f.group)
    transport = "place-" <> SystemsRuntime.Proc.uuid()

    {:ok, ^transport, device} =
      Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => f.tenant,
          "group_id" => f.group,
          "device_id" => record["device_id"],
          "connector_id" => record["connector_id"],
          "managed_compute" => true,
          "workload_id" => record["workload_id"],
          "workload_generation" => record["generation"]
        },
        transport_id: transport
      )

    context = %{
      tenant_id: f.tenant,
      group_id: f.group,
      device_id: record["device_id"],
      connector_id: record["connector_id"],
      connector_run_id: device["connector_run_id"],
      workload_id: record["workload_id"],
      workload_generation: record["generation"]
    }

    owner = self()

    peer =
      spawn_link(fn ->
        :ok = Bridge.register_owner(transport, :unmanaged)
        send(owner, {:peer_ready, self()})
        peer(owner, station, opts)
      end)

    settle_receive({:peer_ready, ^peer})
    on_exit(fn -> if Process.alive?(peer), do: Process.exit(peer, :kill) end)
    {context, peer}
  end

  defp peer(owner, station, opts) do
    SystemsRuntime.Proc.receive do
      {:env_rpc, ref, from, %{"method" => "station_identity"}} ->
        send(owner, {:identity_requested, self()})

        if opts[:hold_identity] do
          SystemsRuntime.Proc.receive do
            :continue_identity -> :ok
          end
        end

        send(from, {:env_rpc_reply, ref, {:ok, %{"station" => station, "version" => "test"}}})
        peer(owner, station, opts)

      {:env_rpc, ref, from, %{"method" => "station_place", "params" => place}} ->
        send(owner, {:placed, place})
        send(from, {:env_rpc_reply, ref, opts[:placement] || {:ok, %{"placed" => true}}})
        peer(owner, station, opts)

      {:env_owner_takeover, _transport, _replacement} ->
        :ok

      _ ->
        peer(owner, station, opts)
    end
  end

  defp advance!(f) do
    Repo.transaction(fn ->
      workload = Repo.get!(Compute.Workload, f.record["workload_id"])
      allocation = Repo.get!(Compute.Allocation, workload.allocation_id)

      for {schema, id} <- [
            {Compute.Workload, workload.id},
            {Compute.Environment, workload.environment_id},
            {Compute.Allocation, allocation.id},
            {Compute.ProviderBinding, allocation.provider_binding_id}
          ] do
        Repo.update_all(from(row in schema, where: row.id == ^id), inc: [generation: 1])
      end
    end)
  end

  defp admit!(f, station) do
    assert {:ok, _place} =
             Comma.Stations.admit_cloud_station(
               f.tenant,
               f.group,
               station,
               nil,
               "test",
               "http://localhost"
             )
  end

  defp key(f, name) do
    :crypto.hash(:sha256, f.group <> ":" <> name)
    |> Base.encode16(case: :lower)
  end
end
