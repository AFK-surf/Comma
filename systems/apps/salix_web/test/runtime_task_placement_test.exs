defmodule SalixWeb.RuntimeTaskPlacementTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  import Ecto.Query
  require SystemsClock
  alias SalixStore.{AgentVMM, Compute, Repo, StationDeviceLookup, StationTaskSessions}
  alias SalixEnv.Registry
  alias SalixIM.TaskPlacement

  defmodule Product do
    @behaviour SalixStore.StationMembers
    def role(_, _, user) when user in ~w(alice bob), do: {:ok, "member"}
    def role(_, _, _), do: :none
    def manager_role?(_), do: false
    def read_only_role?(_), do: false
    def workspace_name(_, _), do: {:ok, "Test"}
    def workspace_active?(_, _), do: true
  end

  defmodule Station do
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{lost: true, invites: [], sessions: %{}} end, name: __MODULE__)

    def state, do: Agent.get(__MODULE__, & &1)

    def request(run, "task.invite", params, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        session = Map.get(state.sessions, params["task"], "session:" <> params["task"])

        next = %{
          state
          | lost: false,
            invites: state.invites ++ [{run, params["task"]}],
            sessions: Map.put(state.sessions, params["task"], session)
        }

        {if(state.lost, do: {:error, :timeout}, else: {:ok, %{"session" => session}}), next}
      end)
    end

    def request(_, "task.put", params, _), do: {:ok, %{"through" => params["through"]}}

    def request(_, "task.status", _, _),
      do: {:ok, %{"state" => "running", "pending" => 0, "for_ms" => 0}}
  end

  setup do
    previous_members = SystemsRuntime.get_env(:salix_store, :station_members)
    previous_station = SystemsRuntime.get_env(:salix_web, :station_tasks)
    SystemsRuntime.put_env(:salix_store, :station_members, [Product])
    SystemsRuntime.put_env(:salix_web, :station_tasks, connector: Station)
    start_supervised!(Station)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :station_members, previous_members)

      if previous_station,
        do: SystemsRuntime.put_env(:salix_web, :station_tasks, previous_station),
        else: SystemsRuntime.delete_env(:salix_web, :station_tasks)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Runtime placement"})

    {:ok, group} =
      Salix.Control.Groups.create(%{"name" => "Runtime placement"}, tenant["tenant_id"])

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "role" => "router", "name" => "Router"},
        tenant["tenant_id"]
      )

    {:ok, _} =
      Salix.Control.Groups.update(group["group_id"], %{"router_agent_id" => router["agent_id"]})

    scope = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      agent_id: router["agent_id"]
    }

    %{scope: scope}
  end

  test "a lost invitation reply pins the same Station across automatic candidate changes", %{
    scope: scope
  } do
    {device, run} = physical(scope, "z-original", "alice")

    attrs = %{
      "content" => "Build the project",
      "client_request_id" => "lost-reply",
      "model" => %{"kind" => "runtime", "provider" => "codex"}
    }

    trusted = %{requester_user_id: "alice"}
    repo = %{"owner" => "acme", "name" => "api"}

    for request <- [
          attrs,
          Map.put(attrs, "runs_on", %{"kind" => "station", "device_id" => device})
        ] do
      assert {:error, {:runs_on, :repo_requires_sandbox, :requested}} =
               TaskPlacement.create_task_conversation(
                 scope.group_id,
                 scope.agent_id,
                 Map.put(request, "repo", repo),
                 trusted
               )
    end

    assert Station.state().invites == []

    assert {:error, _} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               attrs,
               trusted
             )

    assert %{invites: [{^run, conversation}], sessions: sessions} = Station.state()
    assert map_size(sessions) == 1

    assert {:error, {:runs_on, :repo_requires_sandbox, :requested}} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               Map.put(attrs, "repo", repo),
               trusted
             )

    assert length(Station.state().invites) == 1

    # A fresh selection would choose this earlier device. This is the same
    # request, so the existing creation receipt owns its prior target.
    {_other, other_run} = physical(scope, "a-new-preferred", "alice")
    physical(scope, "0-another-user", "bob")
    {:ok, _} = SalixAgent.TaskPlace.put(scope.tenant_id, scope.group_id, %{"kind" => "salix"})

    assert {:ok, result} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               attrs,
               trusted
             )

    assert result["conversation_id"] == conversation

    assert {:ok, stored} =
             SalixIM.Conversations.get_group_conversation(scope.group_id, conversation)

    assert stored["runs_on"] == %{"kind" => "station", "device_id" => device}

    assert {:ok, [%{device_id: ^device, session: session}]} =
             StationTaskSessions.of_task(scope.group_id, conversation)

    assert sessions[conversation] == session

    assert %{invites: [{^run, ^conversation}, {^run, ^conversation}], sessions: ^sessions} =
             Station.state()

    refute Enum.any?(Station.state().invites, &(elem(&1, 0) == other_run))

    {:ok, _} = Registry.mark_disconnected(run)

    assert {:ok, replay} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               attrs,
               trusted
             )

    assert replay["conversation_id"] == conversation

    assert length(Station.state().invites) == 2
  end

  test "automatic placement uses only the requesting member's opted-in source; explicit and internal choices stay explicit",
       %{scope: scope} do
    {bob, _} = physical(scope, "bob-only", "bob")
    runtime = %{"kind" => "runtime", "provider" => "codex"}
    request = Map.put(scope, :requester_user_id, "alice")
    assert {:error, :cloud_vm_disabled} = SalixWeb.TaskStations.resolve(request, runtime)
    {none, _} = physical(scope, "alice-none", "alice", %{"codex" => []})
    assert {:error, :cloud_vm_disabled} = SalixWeb.TaskStations.resolve(request, runtime)
    {alice, _} = physical(scope, "alice-allowed", "alice")

    assert {:ok, %{"kind" => "station", "device_id" => ^alice}} =
             SalixWeb.TaskStations.resolve(request, runtime)

    assert {:ok, %{"device_id" => ^bob}} =
             Salix.Bindings.AgentConversations.runs_on(request, %{
               "kind" => "station",
               "device_id" => bob
             })

    assert {:ok, %{runs_on: nil}} = TaskPlacement.resolve(request, scope.agent_id, %{}, false)

    assert {:ok, %{runs_on: nil}} =
             TaskPlacement.resolve(
               request,
               scope.agent_id,
               %{"runs_on" => %{"kind" => "salix"}},
               false
             )

    assert {:error, :invalid_requester_parameter} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               %{"content" => "x", "requester_user_id" => "bob"},
               %{}
             )

    refute none == alice
  end

  test "concurrent automatic creates invite only the winning receipt's Station", %{scope: scope} do
    {a, run_a} = physical(scope, "concurrent-a", "alice")
    {b, run_b} = physical(scope, "concurrent-b", "alice")
    {:ok, worker} = SalixAgent.TaskAgent.ensure(scope)

    attrs = %{
      "content" => "Build once",
      "client_request_id" => "concurrent-auto",
      "automatic_task_place" => true,
      "session_model" => %{"kind" => "runtime", "provider" => "codex"}
    }

    results =
      [a, b]
      |> Task.async_stream(
        fn device ->
          SalixCluster.TaskSchedules.create_task_conversation(
            scope.group_id,
            scope.agent_id,
            worker,
            Map.put(attrs, "runs_on", %{"kind" => "station", "device_id" => device})
          )
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.any?(results, &match?({:ok, {:ok, _}}, &1))
    assert %{invites: [first | _] = invites, sessions: sessions} = Station.state()
    assert elem(first, 0) in [run_a, run_b]
    assert Enum.all?(invites, &(&1 == first))
    assert map_size(sessions) == 1
  end

  test "authenticated Host observations prepare one reusable Station without changing Host authority",
       %{scope: scope} do
    {registration, _, _} = host(scope, "observed")
    hello = %{"connectionEpoch" => "2", "inventoryWatermark" => 0, "inventory" => []}
    assert {:ok, :ok} = AgentVMM.observe_registration(registration.id, "gateway", hello)
    assert {:ok, first} = Compute.group_station(scope.tenant_id, scope.group_id)

    assert {:ok, :ok} =
             AgentVMM.observe_registration(
               registration.id,
               "gateway",
               Map.put(hello, "connectionEpoch", "3")
             )

    assert {:ok, again} = Compute.group_station(scope.tenant_id, scope.group_id)
    assert first["workload_id"] == again["workload_id"]

    assert Repo.aggregate(
             from(w in Compute.Workload, where: w.id == ^first["workload_id"]),
             :count
           ) == 1

    {_other, _, _} = host(scope, "second-observed")

    assert {:error, :ambiguous_vmm_hosts} =
             Compute.group_vmm_placement(scope.tenant_id, scope.group_id)

    assert {:error, :ambiguous_vmm_hosts} =
             SalixStore.ComputeGroupStation.prepare_registration(registration.id)

    assert AgentVMM.connected?(registration.id)
  end

  test "a bounded personal candidate page does not claim later Stations are unavailable", %{
    scope: scope
  } do
    for n <- 1..8, do: physical(scope, "limited-#{n}", "alice", %{"codex" => []})
    {later, _} = physical(scope, "z-later", "alice")

    assert {:error, :station_candidate_page_exhausted} =
             SalixWeb.TaskStations.resolve(Map.put(scope, :requester_user_id, "alice"), %{
               "kind" => "runtime",
               "provider" => "codex"
             })

    assert {:ok, %{"device_id" => ^later}} =
             Salix.Bindings.AgentConversations.runs_on(scope, %{
               "kind" => "station",
               "device_id" => later
             })
  end

  test "VMM Station coexists with Cloudflare and keeps exact registration authority", %{
    scope: scope
  } do
    {:ok, cloud, :created} =
      Compute.ensure_group_workload(%{
        "tenant_id" => scope.tenant_id,
        "group_id" => scope.group_id,
        "provider" => "cloudflare",
        "provider_resource_id" => "cf",
        "provider_resource_name" => "cf",
        "device_id" => SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id),
        "provider_migration" => %{
          "phase" => "committed",
          "archive_hold" => "awaiting_durable_archive"
        },
        "status" => "archived",
        "archive" => %{"key" => "kept"}
      })

    {registration, environment, binding} = host(scope, "host-one")
    assert {:ok, station} = Compute.ensure_group_station(scope.tenant_id, scope.group_id)
    assert station.kind == "service"
    assert station.owner_ref == %{"kind" => "group", "id" => scope.group_id}
    assert station.environment_id == environment.id

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^station.allocation_id),
      set: [status: "ready"]
    )

    assert {:ok, %{id: same}} = Compute.ensure_group_station(scope.tenant_id, scope.group_id)
    assert same == station.id
    assert {:ok, ^cloud} = Compute.group_workload(scope.group_id)
    assert {:ok, record} = Compute.group_station(scope.tenant_id, scope.group_id)
    assert record["device_id"] != cloud["device_id"]

    assert :ok =
             Compute.group_provider_mutation_admission(
               scope.tenant_id,
               scope.group_id,
               record["device_id"]
             )

    assert {:error, :provider_cutover_archive_pending} =
             Compute.group_provider_mutation_admission(
               scope.tenant_id,
               scope.group_id,
               cloud["device_id"]
             )

    assert :ok =
             SalixStore.ComputeGroupStation.admit_device(
               scope.tenant_id,
               scope.group_id,
               record["device_id"]
             )

    {:ok, _, runtime_device} =
      Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => scope.tenant_id,
          "group_id" => scope.group_id,
          "device_id" => record["device_id"],
          "connector_id" => record["connector_id"],
          "managed_compute" => true,
          "workload_id" => station.id,
          "workload_generation" => station.generation
        },
        transport_id: record["env_id"]
      )

    {:ok, token} =
      SalixWeb.StationLLM.token(
        scope.tenant_id,
        scope.group_id,
        record["device_id"],
        runtime_device["connector_run_id"]
      )

    refute SalixWeb.StationLLM.admit(Plug.Test.conn(:post, "/v1/station-llm/responses"), token).halted

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
      set: [desired_enabled: false]
    )

    assert {:error, :vmm_station_not_authorized} =
             SalixStore.ComputeGroupStation.admit_device(
               scope.tenant_id,
               scope.group_id,
               record["device_id"]
             )

    assert SalixWeb.StationLLM.admit(Plug.Test.conn(:post, "/v1/station-llm/responses"), token).status ==
             401

    assert {:error, :not_found} = Compute.group_vmm_environment(scope.tenant_id, scope.group_id)

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
      set: [desired_enabled: true]
    )

    allocation = Repo.get!(Compute.Allocation, station.allocation_id)

    for status <- ~w(allocating draining released failed) do
      Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
        set: [status: status]
      )

      assert {:error, :vmm_station_not_authorized} =
               SalixStore.ComputeGroupStation.admit_device(
                 scope.tenant_id,
                 scope.group_id,
                 record["device_id"]
               )

      assert {:error, :managed_provider_changed} =
               SalixStore.ComputeGroupStation.with_connection(
                 station.id,
                 station.generation,
                 fn -> flunk("inactive allocation cannot reconnect") end
               )
    end

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [status: allocation.status]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^station.id),
      set: [desired_state: "stopped"]
    )

    assert {:ok, %{id: ^same, desired_state: "stopped"}} =
             Compute.ensure_group_station(scope.tenant_id, scope.group_id)

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
      set: [status: "revoked"]
    )

    {_replacement, _new_environment, _new_binding} = host(scope, "host-replacement")
    assert {:ok, replacement} = Compute.ensure_group_station(scope.tenant_id, scope.group_id)
    refute replacement.id == station.id
    assert Repo.get!(Compute.ProviderBinding, binding.id).provider_ref == registration.id
    assert {:ok, ^cloud} = Compute.group_workload(scope.group_id)
  end

  test "legacy VMM Group Station keeps its identity and exact Host authority", %{scope: scope} do
    {registration, _, _} = host(scope, "legacy")

    assert {:ok, legacy, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => scope.tenant_id,
               "group_id" => scope.group_id,
               "provider" => "agent_vmm",
               "provider_resource_id" => registration.id,
               "provider_resource_name" => "legacy-container",
               "provider_spec" => %{"profile_key" => "station.default"},
               "device_id" => SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id),
               "status" => "ready"
             })

    assert {:ok, %{id: workload_id}} =
             Compute.ensure_group_station(scope.tenant_id, scope.group_id)

    assert workload_id == legacy["workload_id"]

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^legacy["allocation_id"]),
      set: [status: "ready"]
    )

    assert :ok =
             SalixStore.ComputeGroupStation.admit_device(
               scope.tenant_id,
               scope.group_id,
               legacy["device_id"]
             )

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
      set: [desired_enabled: false]
    )

    assert {:error, :vmm_station_not_authorized} =
             Compute.group_provider_mutation_admission(
               scope.tenant_id,
               scope.group_id,
               legacy["device_id"]
             )

    assert {:error, :managed_provider_changed} =
             SalixStore.ComputeGroupStation.with_connection(
               workload_id,
               legacy["generation"],
               fn -> flunk("revoked legacy VMM cannot reconnect") end
             )

    assert {:ok, ^legacy} = Compute.group_workload(scope.group_id)
  end

  test "Allocation release while connection admission waits cannot admit a stale ready target", %{
    scope: scope
  } do
    host(scope, "connection-release")
    assert {:ok, station} = Compute.ensure_group_station(scope.tenant_id, scope.group_id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^station.allocation_id),
      set: [status: "ready"]
    )

    allocation = Repo.get!(Compute.Allocation, station.allocation_id)
    handler = {__MODULE__, :connection_release, make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, owner ->
          if Process.get(:connection_release_barrier) == true and
               String.contains?(meta.query, "FROM \"compute_provider_bindings\"") do
            Process.delete(:connection_release_barrier)
            send(owner, {:connection_owner_nominated, self()})

            SystemsClock.vreceive do
              :continue_connection -> :ok
            after
              5_000 -> raise "connection barrier timed out"
            end
          end
        end,
        self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        Process.put(:connection_release_barrier, true)

        SalixStore.ComputeGroupStation.with_connection(station.id, station.generation, fn ->
          :connected
        end)
      end)

    settle_receive({:connection_owner_nominated, caller})

    assert {:ok, %{status: "released"}} =
             Compute.observe_allocation(
               allocation.id,
               allocation.revision,
               allocation.generation,
               "released",
               "succeeded"
             )

    send(caller, :continue_connection)
    assert {:error, :managed_provider_changed} = settled_await(task)
  end

  defp physical(scope, id, owner, models \\ %{"codex" => ["codex-default"]}) do
    transport = "transport-" <> id <> "-" <> SystemsRuntime.Proc.uuid()
    device = "device-" <> id <> "-" <> scope.group_id
    station = Base.encode16(:crypto.hash(:sha256, device), case: :lower)

    {:ok, _, record} =
      Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => scope.tenant_id,
          "group_id" => scope.group_id,
          "device_id" => device,
          "connector_id" => "connector-" <> device,
          "owner_user_id" => owner,
          "station_id" => station,
          "capabilities" => %{"tasks" => 2, "task_models" => models}
        },
        transport_id: transport
      )

    :ok = StationDeviceLookup.record(scope.tenant_id, scope.group_id, device, station, owner)
    {device, record["connector_run_id"]}
  end

  defp host(scope, id) do
    id = id <> "-" <> scope.group_id

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: id,
        tenant_id: scope.tenant_id,
        group_id: scope.group_id,
        device_id: "device-" <> id,
        enrollment_token: String.duplicate("e", 32)
      })

    {:ok, pool} = Compute.ensure_managed_default_pool(scope.tenant_id, "agent_vmm")

    {:ok, environment} =
      Compute.create_environment(%{
        id: "env-" <> id,
        tenant_id: scope.tenant_id,
        owner_type: "project",
        owner_id: "project-" <> id,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-" <> id,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: id
      })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^id),
      set: [status: "ready", desired_enabled: true]
    )

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [
        status: "available",
        observation: %{"gateway_instance_id" => "test", "connection_epoch" => "1"}
      ]
    )

    {registration, environment, binding}
  end
end
