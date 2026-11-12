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

  test "model routing preserves the default Station and commits its invited Task", %{scope: scope} do
    {device, _run} = physical(scope, "routing-default", "alice")
    Agent.update(Station, &%{&1 | lost: false})

    policy = %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => "station-test",
      "entries" => [
        %{
          "key" => "all",
          "description" => "All internal tasks",
          "model" => %{"kind" => "catalog", "model" => "gpt-6-sol"}
        }
      ]
    }

    {:ok, _} =
      SalixAgent.TaskPlace.put(scope.tenant_id, scope.group_id, %{
        "kind" => "station",
        "device_id" => device
      })

    {:ok, _} = Salix.Control.Groups.update(scope.group_id, %{"task_model_selection" => policy})

    assert {:ok, created} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               %{"content" => "Build the project", "client_request_id" => "routing-station"},
               %{requester_user_id: "alice"}
             )

    task = created["conversation_id"]

    assert {:ok, conversation} =
             SalixIM.Conversations.get_group_conversation(scope.group_id, task)

    assert conversation["runs_on"]["device_id"] == device
    assert [{_, ^task}] = Station.state().invites
    assert {:ok, [_]} = StationTaskSessions.of_task(scope.group_id, task)
    refute get_in(conversation, ["metadata", "task_model_selection"])

    # Explicit policies constrain internal Tasks, never Station runtime choices.
    {:ok, _} =
      Salix.Control.Groups.update(scope.group_id, %{
        "task_model_selection" => %{
          "mode" => "explicit",
          "actions" => [%{"model" => "gpt-6-sol", "reasoning_effort" => "medium"}]
        }
      })

    assert {:ok, second} =
             TaskPlacement.create_task_conversation(
               scope.group_id,
               scope.agent_id,
               %{"content" => "Build another project", "client_request_id" => "explicit-station"},
               %{requester_user_id: "alice"}
             )

    assert {:ok, second_conversation} =
             SalixIM.Conversations.get_group_conversation(
               scope.group_id,
               second["conversation_id"]
             )

    assert second_conversation["runs_on"]["device_id"] == device
    assert length(Station.state().invites) == 2
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

  defmodule Signer do
    @moduledoc false
    def sign(claims), do: {:ok, claims}
  end

  test "where the Cloud VM is retired, automatic placement and a sandbox default end in a sandbox of the Task's own",
       %{scope: scope} do
    runtime = %{"kind" => "runtime", "provider" => "codex"}
    request = Map.put(scope, :requester_user_id, "alice")

    # Without sandboxes, automatic placement falls through to the Cloud VM.
    assert {:error, :cloud_vm_disabled} = SalixWeb.TaskStations.resolve(request, runtime)

    SystemsRuntime.put_env(:salix_web, :l4es, url: "https://l4es.test", max_sandboxes: 2)
    SystemsRuntime.put_env(:salix_web, :l4es_assertion_signer, Signer)
    sandboxes_mod = SystemsRuntime.get_env(:salix_agent, :sandboxes_mod)
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SalixWeb.L4ES)

    on_exit(fn ->
      for key <- [:l4es, :l4es_assertion_signer], do: SystemsRuntime.delete_env(:salix_web, key)
      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)

      if sandboxes_mod,
        do: SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, sandboxes_mod),
        else: SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
    end)

    # Sandboxes set up, the Cloud VM not retired: automatic placement still ends at the Cloud VM.
    assert {:error, :cloud_vm_disabled} = SalixWeb.TaskStations.resolve(request, runtime)

    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)

    # No VMM Station, no personal Station of the requester: a sandbox.
    assert {:ok, %{"kind" => "sandbox"}} = SalixWeb.TaskStations.resolve(request, runtime)

    assert {:ok, %{runs_on: %{"kind" => "sandbox"}}} =
             TaskPlacement.resolve(request, scope.agent_id, %{"model" => runtime}, false)

    # The requester's own computer still comes first.
    {alice, _} = physical(scope, "alice-first", "alice")

    assert {:ok, %{"kind" => "station", "device_id" => ^alice}} =
             SalixWeb.TaskStations.resolve(request, runtime)

    # A Group whose default place is the sandbox places every runtime Task there.
    assert {:ok, %{"kind" => "sandbox"}} =
             SalixAgent.TaskPlace.put(scope.tenant_id, scope.group_id, %{"kind" => "sandbox"})

    assert {:ok, %{runs_on: %{"kind" => "sandbox"}}} =
             TaskPlacement.resolve(request, scope.agent_id, %{"model" => runtime}, false)

    # A Loop Task takes no default: it runs inside Salix.
    assert {:ok, %{runs_on: nil}} =
             TaskPlacement.resolve(request, scope.agent_id, %{}, true)
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

    {other, other_environment, _} = host(scope, "second-observed")

    assert {:error, :ambiguous_vmm_hosts} =
             Compute.group_vmm_placement(scope.tenant_id, scope.group_id)

    assert {:ok, first_workload} =
             SalixStore.ComputeGroupStation.prepare_registration(registration.id)

    assert first_workload.id == first["workload_id"]

    assert {:ok, second_workload} =
             SalixStore.ComputeGroupStation.prepare_registration(other.id)

    assert second_workload.environment_id == other_environment.id
    refute second_workload.id == first_workload.id

    # An offline Host keeps its work without blocking preparation here.
    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^other.id),
      set: [connected: false]
    )

    assert {:ok, same} = SalixStore.ComputeGroupStation.prepare_registration(registration.id)
    assert same.id == first_workload.id
    assert {:error, :not_found} = SalixStore.ComputeGroupStation.prepare_registration(other.id)
    assert Repo.get!(Compute.Workload, second_workload.id).desired_state == "ready"

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^first_workload.id),
      set: [desired_state: "stopped"]
    )

    assert {:ok, %{desired_state: "stopped"}} =
             SalixStore.ComputeGroupStation.prepare_registration(registration.id, true)

    assert AgentVMM.connected?(registration.id)
  end

  test "a new Host connection reopens a Station parked on a Host-side failure", %{scope: scope} do
    {registration, _, _} = host(scope, "parked")
    hello = %{"connectionEpoch" => "2", "inventoryWatermark" => 0, "inventory" => []}
    assert {:ok, :ok} = AgentVMM.observe_registration(registration.id, "gateway", hello)
    assert {:ok, %{"workload_id" => id}} = Compute.group_station(scope.tenant_id, scope.group_id)
    station = Repo.get!(Compute.Workload, id)
    now = SystemsClock.utc_now()

    park = fn code ->
      Repo.delete_all(from(c in Compute.ReconcilerClaim, where: c.workload_id == ^id))

      Repo.insert!(%Compute.ReconcilerClaim{
        id: "parked-" <> code,
        provider: "agent_vmm",
        workload_id: id,
        generation: station.generation,
        claim_token: "parked",
        attempt_count: 9,
        last_error: %{"kind" => "action_required", "code" => code},
        created_at: now,
        updated_at: now
      })
    end

    reconnect = fn epoch ->
      assert {:ok, :ok} =
               AgentVMM.observe_registration(
                 registration.id,
                 "gateway",
                 Map.put(hello, "connectionEpoch", epoch)
               )

      Repo.get_by!(Compute.ReconcilerClaim, workload_id: id).last_error
    end

    # A person must inspect the old container first.
    park.("container_start_evidence_unavailable")
    assert %{"kind" => "action_required"} = reconnect.("3")

    park.("provider_command_outcome_unknown")
    assert reconnect.("4") == %{}
    assert Repo.get!(Compute.Workload, id).observed_state == "pending"
  end

  test "concurrent preparation reuses one Station under its exact registration", %{scope: scope} do
    {registration, environment, _} = host(scope, "concurrent-prepare", prepare: false)
    {other, _, _} = host(scope, "unrelated-prepare")

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          SalixStore.ComputeGroupStation.prepare_registration(registration.id)
        end,
        max_concurrency: 2
      )
      |> Enum.to_list()

    assert [{:ok, {:ok, first}}, {:ok, {:ok, second}}] = results
    assert first.id == second.id
    assert first.environment_id == environment.id

    assert Repo.aggregate(
             from(w in Compute.Workload,
               where: w.environment_id == ^environment.id and w.template_key == "station.default"
             ),
             :count
           ) == 1

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^other.id),
      set: [status: "revoked"]
    )

    assert {:error, :not_found} = SalixStore.ComputeGroupStation.prepare_registration(other.id)
  end

  test "a person's computers are their own connected Stations, whatever runtime they run", %{
    scope: scope
  } do
    {laptop, _} = physical(scope, "own-laptop", "alice", %{"claude" => []})
    {desk, _} = physical(scope, "own-desk", "alice", %{"codex" => ["codex-default"]})
    physical(scope, "theirs", "bob")

    assert {:ok, computers} =
             SalixWeb.TaskStations.personal_computers(Map.put(scope, :requester_user_id, "alice"))

    assert computers |> Enum.map(& &1["device_id"]) |> Enum.sort() == Enum.sort([laptop, desk])
    assert Enum.all?(computers, &is_binary(&1["station_id"]))
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
      SalixWeb.StationLLM.token(%{
        tenant_id: scope.tenant_id,
        group_id: scope.group_id,
        device_id: record["device_id"],
        connector_run_id: runtime_device["connector_run_id"],
        workload_id: station.id,
        workload_generation: station.generation
      })

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

  defp host(scope, id, opts \\ []) do
    id = id <> "-" <> scope.group_id

    {:ok, registration} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: id,
        tenant_id: scope.tenant_id,
        group_id: scope.group_id,
        device_id: "device-" <> id,
        credential: String.duplicate("e", 32)
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

    if Keyword.get(opts, :prepare, true) do
      assert {:ok, :ok} =
               AgentVMM.observe_registration(id, "test", %{
                 "connectionEpoch" => "1",
                 "inventoryWatermark" => 0,
                 "inventory" => []
               })
    else
      Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^id),
        set: [connected: true]
      )
    end

    {registration, environment, binding}
  end
end
