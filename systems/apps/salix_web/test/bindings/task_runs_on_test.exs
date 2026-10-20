defmodule Salix.Bindings.TaskRunsOnTest do
  @moduledoc """
  Task placement through `Salix.Bindings.AgentConversations.runs_on/2`.
  A desktop station must be connected and accept Tasks with a model its profiles enable.
  A Loop Task runs while every app is closed, so it never runs on a person's own computer.
  Cloud VM placement requires the Group's Cloud VM switch to be on.
  An Agent starts the VM first with `cloud_vm.start`. Task placement requires
  a ready VM and a connected station.
  """
  use SystemsClock.Case, async: false

  alias Salix.Bindings.AgentConversations
  alias SalixEnv.Registry
  alias SalixStore.RuntimeIds

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

  test "a Loop Task is refused a person's own computer, connected or not", %{scope: scope} do
    {personal, run_id} =
      connect_run_device!(scope, "device-personal-#{SystemsRuntime.Proc.unique_integer()}", %{
        "tasks" => 2
      })

    {:ok, _} = Registry.update_meta(run_id, &Map.put(&1, "owner_user_id", "user-1"))
    {:ok, _} = Registry.mark_disconnected(run_id)
    runs_on = %{"kind" => "station", "device_id" => personal}
    loop = Map.put(scope, :loop, true)

    assert AgentConversations.runs_on(loop, runs_on) == {:error, :personal_station_for_loop}

    # A one-shot Task only needs the station to be connected now.
    assert AgentConversations.runs_on(scope, runs_on) == {:error, :device_offline}

    # A station its owner does not carry around takes Loop Tasks.
    unattended = connect!(scope, "device-unattended", %{"tasks" => 2})

    assert AgentConversations.runs_on(loop, %{"kind" => "station", "device_id" => unattended}) ==
             {:ok, %{"kind" => "station", "device_id" => unattended}}
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

  test "Cloud VM Task placement requires the Group's switch and a ready VM with a connected station",
       %{scope: scope} do
    # The Group's Cloud VM switch is off: no Worker places a Task there, bound to it or not.
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

    {:ok, _} = Salix.Control.Groups.update(scope.group_id, %{"cloud_vm_enabled" => true})

    # The switch passes admission for every Worker, but does not create or start the Group VM.
    assert AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_not_running}

    scope = %{scope | agent_id: bound["agent_id"]}

    assert AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_not_running}

    # Its station connected, but the VM is not ready (its archive is still to be
    # restored): no Task runs there yet. A ready one is in cloud_vm_test.
    connect_device!(scope, RuntimeIds.cloud_vm_device_id(scope.group_id), %{})

    assert AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_not_running}
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
