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

  test "a station that is not connected now is refused", %{scope: scope} do
    {device_id, run_id} =
      connect_run_device!(scope, "device-offline-#{SystemsRuntime.Proc.unique_integer()}", %{
        "tasks" => 2
      })

    {:ok, _} = Registry.mark_disconnected(run_id)

    assert AgentConversations.runs_on(scope, %{"kind" => "station", "device_id" => device_id}) ==
             {:error, :device_offline}
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

  test "Cloud VM Task placement requires the Group's switch, not a running VM", %{scope: scope} do
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

    # The switch passes admission for every Worker, with no VM made or
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
