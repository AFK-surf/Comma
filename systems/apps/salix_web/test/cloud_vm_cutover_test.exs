defmodule SalixWeb.CloudVMCutoverTest do
  @moduledoc """
  The Cloud VM cutover (`SalixWeb.Migrations.CloudVMCutover`) over seeded
  Groups, Workers and Tasks, a page of one record at a time: every Group is
  marked retired, a Cloud VM default place and a Cloud VM Worker binding
  become a sandbox, each open Task on the Cloud VM gets one notice and is
  closed, the Cloud VM's station alone leaves it, and the Cloudflare VM is
  asked to stop. A record that cannot be changed is counted and the others go
  on. A Group whose VM is on its Agent VMM Host keeps that VM and its Tasks:
  its place and bindings name the VM's station, and new Tasks are placed
  there; a Group with a Host registered but its VM on Cloudflare is retired
  like any other, and the station form cannot reach its Cloud VM. Run again, it changes
  nothing. The Tasks are real Conversations; no VM provider is asked anything.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  import Ecto.Query, only: [from: 2]

  alias SalixAgent.{Sandboxes, TaskPlace}
  alias SalixStore.{CasRecord, Keys, RuntimeIds, StationTaskSessions}
  alias SalixWeb.Migrations.CloudVMCutover

  defmodule SandboxesOn do
    @moduledoc "A deployment with Task sandboxes set up (`SalixAgent.Sandboxes`)."
    def enabled?, do: true
  end

  @model %{"kind" => "runtime", "provider" => "claude"}

  setup do
    previous = SystemsRuntime.get_env(:salix_im, :task_stations_mod)
    SystemsRuntime.put_env(:salix_im, :task_stations_mod, SalixWeb.StationTasks)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_im, :task_stations_mod, previous),
        else: SystemsRuntime.delete_env(:salix_im, :task_stations_mod)

      SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Cloud VM cutover"})
    %{tenant: tenant["tenant_id"]}
  end

  test "the cutover retires every Group, moves Cloud VM places and bindings to sandboxes, and closes open Cloud VM Tasks once",
       %{tenant: tenant} do
    # Groups as the release before left them: none is marked retired.
    cloud = group!(tenant, "On the Cloud VM", TaskPlace.cloud_vm())

    host =
      group!(tenant, "On an Agent VMM Host", TaskPlace.cloud_vm())

    # A Host registered for it, its Group VM still on Cloudflare.
    registered =
      group!(tenant, "A Host registered", TaskPlace.cloud_vm())

    station = group!(tenant, "On a station", %{"kind" => "station", "device_id" => "dev-ann"})

    host_vm!(tenant, host)
    registration!(tenant, registered)
    vm_record!(tenant, registered, %{"provider" => "cloudflare"})

    router = router!(tenant, cloud)
    host_router = router!(tenant, host)
    registered_router = router!(tenant, registered)
    worker = worker!(tenant, cloud, %{"kind" => "cloud_vm"})
    archived = worker!(tenant, cloud, %{"kind" => "cloud_vm"})
    {:ok, _} = SalixAgent.Control.delete(archived)
    host_worker = worker!(tenant, host, %{"kind" => "cloud_vm"})
    host_free = agent!(tenant, host, %{"name" => "Free Worker", "role" => "worker"})
    registered_worker = worker!(tenant, registered, %{"kind" => "cloud_vm"})
    station_worker = worker!(tenant, station, %{"kind" => "station", "device_id" => "dev-ann"})

    active = task!(cloud, router, worker, "active")
    review = task!(cloud, router, worker, "ready_for_review")
    failed = task!(cloud, router, worker, "failed")
    done = task!(cloud, router, worker, "completed")
    host_task = task!(host, host_router, host_worker, "active")
    registered_task = task!(registered, registered_router, registered_worker, "active")

    # Another station takes part in a Cloud VM Task too.
    :ok =
      StationTaskSessions.join(%{
        tenant_id: tenant,
        group_id: cloud,
        conversation_id: active,
        device_id: "dev-ann",
        session: "claude:#{active}",
        agent_id: worker
      })

    # The deployment that turns the switch on: the BridgeForTeams derivation of
    # Cloud VM defaults, run again on a database that has not recorded it,
    # writes none.
    derived = group!(tenant, "Derived", nil)
    worker!(tenant, derived, %{"kind" => "cloud_vm"})
    retire_deployment!()

    assert {:ok, :none} = SalixAgent.Migrations.DefaultTaskPlaces.derive(tenant, derived)
    assert {:ok, nil} = TaskPlace.get(derived)

    # A Group record that cannot be read.
    unreadable = SalixStore.Ids.new_group_id(tenant)
    SalixStore.S3.put(Keys.ctl_group(unreadable), "not a record")

    assert {:ok, %{"groups" => 5, "workers" => 5, "tasks" => 4, "workloads" => 1, "failed" => 1}} =
             CloudVMCutover.run(tenant: tenant, page: 1)

    for group <- [cloud, host, registered, station, derived],
        do: assert(group(group)[Sandboxes.field()])

    host_vm = RuntimeIds.cloud_vm_device_id(host)
    assert {:ok, %{"kind" => "sandbox"}} = TaskPlace.get(cloud)
    # The Agent VMM Host is the Group's own: its VM stays, named as its station.
    assert {:ok, %{"kind" => "station", "device_id" => ^host_vm}} = TaskPlace.get(host)
    assert {:ok, %{"kind" => "sandbox"}} = TaskPlace.get(registered)
    assert {:ok, %{"kind" => "station"}} = TaskPlace.get(station)

    # The model and everything else of the binding stays; the revision moves on.
    assert %{"runs_on" => %{"kind" => "sandbox"}, "model" => @model, "binding_revision" => 2} =
             station_binding(worker)

    assert %{"runs_on" => %{"kind" => "sandbox"}} = station_binding(archived)

    assert %{
             "runs_on" => %{"kind" => "station", "device_id" => ^host_vm},
             "model" => @model,
             "binding_revision" => 2
           } = station_binding(host_worker)

    assert %{"runs_on" => %{"kind" => "sandbox"}} = station_binding(registered_worker)

    assert %{"runs_on" => %{"kind" => "station"}} = station_binding(station_worker)

    # Open Tasks are told once and closed; their earlier Messages stay.
    assert task(cloud, active)["status"] == "cancelled"
    assert task(cloud, review)["status"] == "completed"
    assert task(cloud, failed)["status"] == "cancelled"
    assert task(cloud, done)["status"] == "completed"
    assert [_, %{"content" => [%{"text" => text}]}] = messages(cloud, active)
    assert text =~ "retired" and text =~ "cancelled" and text =~ "runs_on {kind: sandbox}"
    assert [_, %{"content" => [%{"text" => text}]}] = messages(cloud, review)
    assert text =~ "(completed)"
    assert [_, _] = messages(cloud, failed)
    assert [_] = messages(cloud, done)

    # The Cloud VM's station takes part in none of them any more, the other
    # station still does; the Agent VMM Host's station still does too.
    assert {:ok, []} =
             StationTaskSessions.of_device(tenant, cloud, RuntimeIds.cloud_vm_device_id(cloud))

    assert {:ok, [%{device_id: "dev-ann"}]} = StationTaskSessions.of_task(cloud, active)
    assert task(host, host_task)["status"] == "active"
    assert {:ok, [_]} = StationTaskSessions.of_task(host, host_task)
    assert task(registered, registered_task)["status"] == "cancelled"
    assert {:ok, []} = StationTaskSessions.of_task(registered, registered_task)

    # The Cloudflare VM is asked to stop; the Agent VMM Host's VM is not.
    assert {:ok, %{"desired_state" => "stopped"}} = SalixStore.Compute.group_workload(registered)
    assert {:ok, %{"desired_state" => "ready"}} = SalixStore.Compute.group_workload(host)

    # New Tasks of the Agent VMM Host's Group go to its VM's station, by the
    # bound Worker and by {kind: default}, though the VM's station is not
    # connected now: it is invited when it is, as the Cloud VM's was.
    host_scope = %{tenant_id: tenant, group_id: host}
    host_station = %{"kind" => "station", "device_id" => host_vm}

    assert {:ok, %{runs_on: ^host_station, source: :binding}} =
             SalixIM.TaskPlacement.resolve(host_scope, host_worker, %{}, false)

    assert {:ok, %{runs_on: ^host_station, source: :default}} =
             SalixIM.TaskPlacement.resolve(host_scope, host_free, %{}, false)

    assert {:ok, ^host_station} = SalixAgent.StationBinding.runs_on(host_station, host)
    assert {:ok, ^host_station} = TaskPlace.put(tenant, host, host_station)

    # {kind: cloud_vm} is no place anywhere now, the Agent VMM Host's Group too.
    for group <- [cloud, host, registered] do
      assert {:error, {:bad_request, _}} =
               SalixAgent.StationBinding.runs_on(%{"kind" => "cloud_vm"}, group)

      assert {:error, :cloud_vm_retired} = TaskPlace.put(tenant, group, TaskPlace.cloud_vm())
    end

    # The station form of a Group VM on Cloudflare is refused as the Cloud VM
    # is, a Host registered or not: it names the Group's Workload, not the
    # Host's own Station.
    for {group, worker} <- [{cloud, worker}, {registered, registered_worker}] do
      vm = %{"kind" => "station", "device_id" => RuntimeIds.cloud_vm_device_id(group)}

      assert {:error, :cloud_vm_retired} =
               Salix.Bindings.AgentConversations.runs_on(
                 %{tenant_id: tenant, group_id: group, agent_id: worker},
                 vm
               )

      assert {:error, {:bad_request, _}} = SalixAgent.StationBinding.runs_on(vm, group)
      assert {:error, :cloud_vm_retired} = TaskPlace.put(tenant, group, vm)
    end

    # Run again, it changes nothing; the record it could not change, it tries again.
    assert {:ok, %{"groups" => 0, "workers" => 0, "tasks" => 0, "workloads" => 0, "failed" => 1}} =
             CloudVMCutover.run(tenant: tenant)

    assert length(messages(cloud, active)) == 2
  end

  test "where the deployment does not retire the Cloud VM, the release's page does nothing and records nothing" do
    SalixStore.Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'cloud_vm_cutover_v1'")

    # Sandboxes set up alone do not retire it.
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)

    assert {:ok, %{processed: 0, done: true}} = CloudVMCutover.after_rollout_page()

    assert %{rows: []} =
             SalixStore.Repo.query!(
               "SELECT 1 FROM salix_cutover_markers WHERE name = 'cloud_vm_cutover_v1'"
             )
  end

  defp retire_deployment! do
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)
  end

  # A Group as a release before this one made it: no `cloud_vm_retired`.
  defp group!(tenant, name, place, fields \\ %{}) do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => name}, tenant)
    group = group["group_id"]

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_group(group),
        fn record ->
          record = record |> Map.delete(Sandboxes.field()) |> Map.merge(fields)
          if place, do: Map.put(record, "default_task_place", place), else: record
        end,
        create: false
      )

    group
  end

  # A VMM Host registered for the Group, enabled.
  defp registration!(tenant, group) do
    registration = "host-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _registration} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: registration,
        tenant_id: tenant,
        group_id: group,
        device_id: "device-" <> registration,
        credential: String.duplicate("h", 32),
        desired_enabled: true
      })

    registration
  end

  # The Group's VM on its connected, authorized Agent VMM Host, as
  # `SalixWeb.CloudVMTest` makes it.
  defp host_vm!(tenant, group) do
    registration = registration!(tenant, group)

    {:ok, pool} =
      SalixStore.Compute.create_pool(%{
        id: "host-pool-" <> registration,
        tenant_id: tenant,
        name: "Host",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      SalixStore.Compute.create_environment(%{
        id: "host-project-" <> registration,
        tenant_id: tenant,
        owner_type: "project",
        owner_id: "project-" <> registration,
        pool_id: pool.id
      })

    {:ok, _binding} =
      SalixStore.Compute.create_provider_binding(%{
        id: "host-binding-" <> registration,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration
      })

    SalixStore.Repo.update_all(
      from(r in SalixStore.AgentVMM.Registration, where: r.id == ^registration),
      set: [
        status: "ready",
        authorization_expires_at: DateTime.add(SystemsClock.utc_now(), 86_400, :second)
      ]
    )

    {:ok, :ok} =
      SalixStore.AgentVMM.observe_registration(registration, "gateway-test", %{
        "connectionEpoch" => "7",
        "inventoryWatermark" => 0,
        "inventory" => []
      })

    vm_record!(tenant, group, %{
      "provider" => "agent_vmm",
      "provider_resource_id" => registration,
      "provider_spec" => %{"profile_key" => "vmm-station-1"}
    })

    # Running there: the reconciler has allocated it.
    {:ok, %{"allocation_id" => allocation}} = SalixStore.Compute.group_workload(group)

    SalixStore.Repo.update_all(
      from(a in SalixStore.Compute.Allocation, where: a.id == ^allocation),
      set: [status: "ready"]
    )
  end

  # The Group's VM as a release before made it, as Compute records it.
  defp vm_record!(tenant, group, attrs) do
    {:ok, _vm, :created} =
      SalixStore.Compute.ensure_group_workload(
        Map.merge(
          %{
            "tenant_id" => tenant,
            "group_id" => group,
            "provider_resource_name" => RuntimeIds.cloud_vm_provider_resource_name(group),
            "env_id" => RuntimeIds.cloud_vm_env_id(group),
            "device_id" => RuntimeIds.cloud_vm_device_id(group),
            "connector_id" => RuntimeIds.cloud_vm_connector_id(group),
            "alias" => "cloud-vm",
            "status" => "ready",
            "created_at" => SystemsClock.system_time(:millisecond)
          },
          attrs
        )
      )
  end

  defp group(group) do
    {:ok, record} = CasRecord.get(Keys.ctl_group(group))
    record
  end

  defp agent!(tenant, group, attrs) do
    {:ok, agent} = SalixAgent.Control.create(Map.put(attrs, "group_id", group), tenant)
    agent["agent_id"]
  end

  defp router!(tenant, group) do
    router = agent!(tenant, group, %{"name" => "Router", "role" => "router"})
    {:ok, _} = Salix.Control.Groups.update(group, %{"router_agent_id" => router})
    router
  end

  defp worker!(tenant, group, runs_on) do
    agent!(tenant, group, %{
      "name" => "Worker",
      "role" => "worker",
      "station_binding" => %{"runs_on" => runs_on, "model" => @model}
    })
  end

  defp station_binding(agent_id) do
    {:ok, record} = SalixAgent.AgentControl.get_record(agent_id)
    record["station_binding"]
  end

  # A Task on the Group's Cloud VM, its station taking part.
  defp task!(group, router, worker, status) do
    id = SalixStore.Ids.new_conversation_id()
    device = RuntimeIds.cloud_vm_device_id(group)

    participants = [
      %{"actor_type" => "agent", "agent_id" => router, "role_label" => "router"},
      %{"actor_type" => "agent", "agent_id" => worker, "role_label" => "worker"}
    ]

    {:ok, seed} =
      SalixIM.ConversationSeedInput.prepare(group, id, %{
        "messages" => [
          %{"actor_type" => "agent", "agent_id" => router, "content" => "build it"}
        ],
        "conversation" => %{
          "kind" => "agent_task",
          "status" => status,
          "runs_on" => %{"kind" => "cloud_vm", "device_id" => device},
          "participants" => participants
        }
      })

    {:ok, _} = SalixIM.ConversationServer.seed_group_conversation_transcript(group, id, seed)

    :ok =
      StationTaskSessions.join(%{
        tenant_id: SalixStore.Ids.tenant_id_from_group!(group),
        group_id: group,
        conversation_id: id,
        device_id: device,
        session: "codex:#{id}",
        agent_id: worker
      })

    id
  end

  defp task(group, id) do
    {:ok, task} = SalixIM.Conversations.get_group_conversation(group, id)
    task
  end

  defp messages(group, id) do
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group, id, limit: 20)
    messages
  end
end
