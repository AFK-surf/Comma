defmodule Salix.Bindings.TaskRunsOnTest do
  @moduledoc """
  Task placement through `Salix.Bindings.AgentConversations.runs_on/2`.
  A desktop station must be connected and accept Tasks with a model its profiles enable.
  Cloud VM placement requires the Group's Cloud VM switch to be on, and nothing
  else: a Task made while the VM sleeps or was never made is kept for its
  station and the VM woken (`SalixWeb.StationTasks`).
  """
  use SystemsClock.Case, async: false

  alias Salix.Bindings.AgentConversations
  alias SalixEnv.Registry
  alias SalixStore.RuntimeIds

  defmodule EnforcingFacts do
    @moduledoc "An IFC facts resolver for a Group that enforces."
    def mode(_tenant_id, _group_id), do: %{"mode" => "enforce"}
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Task runs_on"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Task runs_on"}, tenant["tenant_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    scope = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      agent_id: worker["agent_id"]
    }

    {:ok, scope: scope}
  end

  test "a connected station is accepted by its device id", %{scope: scope} do
    device_id = connect!(scope, "device-station", %{"tasks" => 2})

    assert AgentConversations.runs_on(scope, %{"kind" => "station", "device_id" => device_id}) ==
             {:ok, %{"kind" => "station", "device_id" => device_id}}
  end

  test "under IFC enforce, an agent's Task goes to a station only from public sources; a person's Task is not checked",
       %{scope: scope} do
    device_id = connect!(scope, "device-station", %{"tasks" => 2})
    station = %{"kind" => "station", "device_id" => device_id}

    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, __MODULE__.EnforcingFacts)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod) end)

    place = fn extra ->
      scope
      |> Map.take([:tenant_id, :group_id])
      |> Map.merge(extra)
      |> SalixIM.TaskPlacement.resolve(scope.agent_id, %{"runs_on" => station}, false)
    end

    dm = SalixIFC.Codec.encode_label(SalixIFC.Label.new([{:scope, "lark", "oc_dm"}]))

    # Made from a private chat, by an agent whose evidence the IFC check gave.
    assert {:error, {:runs_on, :private_sources_to_machine, :requested} = refusal} =
             place.(%{ifc_sources: dm})

    assert SalixIM.TaskPlacement.message(refusal) =~ "runs_on {kind: sandbox}"
    # An agent's Task with no evidence is not known to be public.
    assert {:error, {:runs_on, :private_sources_to_machine, _}} = place.(%{ifc_sources: nil})

    # Public sources (`sources: []`), or a Task a person makes in a product.
    assert {:ok, %{runs_on: ^station}} = place.(%{ifc_sources: []})
    assert {:ok, %{runs_on: ^station}} = place.(%{})
  end

  test "a station that is not connected now is refused", %{scope: scope} do
    {device_id, run_id} =
      connect_run_device!(scope, "device-offline-#{SystemsRuntime.Proc.unique_integer()}", %{
        "tasks" => 2
      })

    {:ok, _} = Registry.mark_disconnected(run_id)

    assert AgentConversations.runs_on(scope, %{"kind" => "station", "device_id" => device_id}) ==
             {:error, :device_offline}
  end

  test "a standalone Task accepts a catalog choice without changing its Worker", %{scope: scope} do
    choice = %{"kind" => "catalog", "model" => "gpt-5.6-sol", "reasoning_effort" => "medium"}
    assert {:ok, before} = SalixAgent.Control.get_record(scope.agent_id)

    assert {:ok, selected} = AgentConversations.session_model(scope, choice)
    assert selected == Map.put(choice, "allow_paid", false)
    assert {:ok, after_choice} = SalixAgent.Control.get_record(scope.agent_id)
    assert after_choice == before

    assert {:error, _} =
             AgentConversations.session_model(scope, Map.put(choice, "model", "unknown-model"))
  end

  test "standalone model selection cannot use another tenant's Group or replace a missing Bridge owner",
       %{scope: scope} do
    choice = %{"kind" => "catalog", "model" => "gpt-5.6-sol"}
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other model tenant"})

    assert {:error, :not_found} =
             AgentConversations.session_model(%{scope | tenant_id: other["tenant_id"]}, choice)

    {:ok, _} =
      Salix.Control.Groups.update(scope.group_id, %{"billing_owner" => %{"surface" => "bridge"}})

    assert {:error, :model_selection_unsupported} =
             AgentConversations.session_model(scope, choice)
  end

  test "a Task's model on a station must be one its profiles enable, as the station said", %{
    scope: scope
  } do
    device_id =
      connect!(scope, "device-models", %{"tasks" => 2, "task_models" => %{"codex" => ["gpt-5.5"]}})

    scope = Map.put(scope, :runs_on, %{"kind" => "station", "device_id" => device_id})
    choice = &%{"kind" => "runtime", "provider" => "codex", "model" => &1}

    assert AgentConversations.session_model(scope, choice.("gpt-5.4-mini")) ==
             {:error, {:not_on_station, %{"codex" => ["gpt-5.5"]}}}

    refute match?(
             {:error, {:not_on_station, _}},
             AgentConversations.session_model(scope, choice.("gpt-5.5"))
           )

    # A station that has said nothing of its models runs none a Task can name.
    silent = connect!(scope, "device-silent", %{"tasks" => 2})
    scope = Map.put(scope, :runs_on, %{"kind" => "station", "device_id" => silent})

    assert AgentConversations.session_model(scope, choice.("gpt-5.5")) ==
             {:error, {:not_on_station, %{}}}
  end

  # Before: a runtime Task without a model id was placed on any connected
  # computer, which then refused it for want of an account chosen for the
  # workspace. Now placement refuses it up front and names the Salix path.
  test "a runtime Task with no model id goes to a computer only if it runs that runtime for the workspace",
       %{scope: scope} do
    none =
      connect!(scope, "device-no-source", %{"tasks" => 2, "task_models" => %{"claude" => []}})

    chosen =
      connect!(scope, "device-local", %{"tasks" => 2, "task_models" => %{"claude" => ["opus"]}})

    claude = %{"kind" => "runtime", "provider" => "claude"}

    place = fn device_id ->
      scope
      |> Map.take([:tenant_id, :group_id])
      |> SalixIM.TaskPlacement.resolve(
        scope.agent_id,
        %{"runs_on" => %{"kind" => "station", "device_id" => device_id}, "model" => claude},
        false
      )
    end

    assert {:error, {:model, {:not_on_station, %{"claude" => []}}} = refusal} = place.(none)
    message = SalixIM.TaskPlacement.message(refusal)
    assert message =~ "do not choose one for the person"
    assert message =~ "runs_on {kind: salix}"

    station = %{"kind" => "station", "device_id" => chosen}
    assert {:ok, %{runs_on: ^station, session_model: ^claude}} = place.(chosen)
  end

  defmodule Signer do
    @moduledoc false
    def sign(claims), do: {:ok, claims}
  end

  test "where the deployment retires the Cloud VM, it is no place; sandboxes set up alone retire nothing",
       %{scope: scope} do
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

    # Sandboxes set up: the Cloud VM is still a place, decided by the Group's switch.
    refute match?(
             {:error, :cloud_vm_retired},
             AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"})
           )

    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)

    # Whatever the Group's Cloud VM switch says, the place is gone here; a
    # sandbox stands in its stead.
    assert AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_retired}

    assert AgentConversations.runs_on(scope, %{"kind" => "sandbox"}) ==
             {:ok, %{"kind" => "sandbox"}}

    assert SalixIM.TaskPlacement.message({:runs_on, :cloud_vm_retired, :requested}) =~
             "retired here: sandboxes have taken its place. Give runs_on {kind: sandbox}"

    assert SalixIM.TaskPlacement.message({:runs_on, :cloud_vm_retired, :binding}) =~
             "bind the Worker with station_binding.runs_on {kind: sandbox}"

    # A default place that is the retired Cloud VM: {kind: default} would come back here.
    default = SalixIM.TaskPlacement.message({:runs_on, :cloud_vm_retired, :default})
    assert default =~ "default place to run Tasks is its Cloud VM, which is retired here"
    assert default =~ "not {kind: default}; ask the user to change the default place"
  end

  test "a Group created where sandboxes are set up places no Task on a Cloud VM", %{scope: scope} do
    SystemsRuntime.put_env(:salix_web, :l4es, url: "https://l4es.test", max_sandboxes: 2)
    SystemsRuntime.put_env(:salix_web, :l4es_assertion_signer, Signer)
    sandboxes_mod = SystemsRuntime.get_env(:salix_agent, :sandboxes_mod)
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SalixWeb.L4ES)

    on_exit(fn ->
      for key <- [:l4es, :l4es_assertion_signer], do: SystemsRuntime.delete_env(:salix_web, key)

      if sandboxes_mod,
        do: SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, sandboxes_mod),
        else: SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
    end)

    {:ok, created} = Salix.Control.Groups.create(%{"name" => "New"}, scope.tenant_id)
    new_scope = %{scope | group_id: created["group_id"]}

    assert AgentConversations.runs_on(new_scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_retired}

    assert AgentConversations.runs_on(new_scope, %{"kind" => "sandbox"}) ==
             {:ok, %{"kind" => "sandbox"}}

    # The Group made before sandboxes were set up keeps its Cloud VM.
    refute match?(
             {:error, :cloud_vm_retired},
             AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"})
           )
  end

  test "Cloud VM Task placement requires the Tenant's VM provider, not a running VM",
       %{scope: scope} do
    # The Tenant has no VM provider: no Worker places a Task there, bound to it or not.
    {:ok, bound} =
      SalixAgent.Control.create(
        %{
          "group_id" => scope.group_id,
          "name" => "On the Cloud VM",
          "role" => "worker",
          "station_binding" => %{
            "runs_on" => %{"kind" => "cloud_vm"},
            "model" => %{"kind" => "runtime", "provider" => "codex"}
          }
        },
        scope.tenant_id
      )

    for agent_id <- [scope.agent_id, bound["agent_id"]] do
      assert AgentConversations.runs_on(%{scope | agent_id: agent_id}, %{"kind" => "cloud_vm"}) ==
               {:error, :cloud_vm_disabled}
    end

    {:ok, _} =
      Salix.Control.Tenants.update(scope.tenant_id, %{
        "config" =>
          Jason.encode!(%{
            "vm" => %{
              "default_provider" => "cloudflare",
              "providers" => %{"cloudflare" => %{"enabled" => true}}
            }
          })
      })

    # The provider passes admission for every Worker, with no VM made or
    # running yet: the Task's station gives the VM its wake (cloud_vm_test).
    place = %{"kind" => "cloud_vm", "device_id" => RuntimeIds.cloud_vm_device_id(scope.group_id)}

    for agent_id <- [scope.agent_id, bound["agent_id"]] do
      assert AgentConversations.runs_on(%{scope | agent_id: agent_id}, %{"kind" => "cloud_vm"}) ==
               {:ok, place}
    end

    # The Cloud VM's station named as a desktop station is the Cloud VM.
    assert AgentConversations.runs_on(scope, %{
             "kind" => "station",
             "device_id" => place["device_id"]
           }) ==
             {:error, :use_cloud_vm_kind}
  end

  defp connect!(scope, prefix, capabilities),
    do:
      connect_device!(
        scope,
        "#{prefix}-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        capabilities
      )

  defp connect_device!(scope, device_id, capabilities),
    do: scope |> connect_run_device!(device_id, capabilities) |> elem(0)

  defp connect_run_device!(scope, device_id, capabilities) do
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => scope.tenant_id,
          "group_id" => scope.group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Laptop"
        },
        transport_id: transport_id
      )

    {:ok, _} =
      Registry.update_meta(record["connector_run_id"], &Map.put(&1, "capabilities", capabilities))

    {device_id, record["connector_run_id"]}
  end
end
