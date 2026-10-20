defmodule SalixWeb.StationHostedTasksTest do
  @moduledoc """
  A Router and the Tasks its Group's stations host (`SalixWeb.StationHostedTasks`
  behind `SalixIM.Ports.StationHostedTasks`): `internal.task.list` lists them
  from the Task index, `internal.read_conversation` reads one and
  `internal.send_message` writes in it through the station's Connector
  (`task.read`, `task.say`), and a station that is offline answers neither.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.Registry
  alias SalixStore.{StationTaskIndex, Stations}

  defmodule Station do
    @moduledoc "The station on the other end: what it is asked, answered as a station would."
    def request(run_id, method, params, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :station_hosted_tasks_test_pid),
        {:asked, run_id, method, params}
      )

      case method do
        "task.read" ->
          {:ok,
           %{
             "task" => params["task"],
             "title" => "Fix the build",
             "messages" => [
               %{
                 "seq" => 1,
                 "author_kind" => "person",
                 "author" => "ann@x",
                 "text" => "fix it",
                 "at" => 1
               }
             ],
             "through" => 1
           }}

        "task.say" ->
          {:ok, %{"seq" => 2}}
      end
    end
  end

  defmodule EnforcingFacts do
    @moduledoc "An IFC facts resolver for a Group that enforces."
    def mode(_tenant_id, _group_id), do: %{"mode" => "enforce"}
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Station-hosted Tasks"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Hosted"}, tenant_id)
    group_id = group["group_id"]

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group_id, "name" => "Router", "role" => "router"},
        tenant_id
      )

    station_id = String.duplicate("ab", 32)
    device_id = "device-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    {:ok, _station, nil} = Stations.admit(tenant_id, group_id, station_id)
    {:ok, station} = Stations.active_station(station_id)

    {:ok, _held} =
      StationTaskIndex.apply_page(station, device_id, %{
        "epoch" => "e1",
        "reset" => true,
        "through" => 1,
        "rows" => [
          %{
            "thread" => "7",
            "rev" => 1,
            "task" => "EMBER/1792.000100",
            "title" => "Fix the build",
            "status" => "in_progress",
            "created_at" => 1_000,
            "last_activity_at" => 2_000
          }
        ]
      })

    SystemsRuntime.put_env(:salix_web, :station_tasks, connector: Station)
    SystemsRuntime.put_env(:salix_web, :station_hosted_tasks_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :station_tasks)
      SystemsRuntime.delete_env(:salix_web, :station_hosted_tasks_test_pid)
    end)

    {:ok,
     router: router["agent_id"],
     view: %{tenant_id: tenant_id, group_id: group_id, device_id: device_id},
     ref: "station:#{station_id}:7"}
  end

  defp router_call(agent_id, api, params) do
    SalixIM.Provider.call_api(agent_id, "internal", api, %{
      "connect_id" => "internal",
      "params" => params
    })
  end

  test "a Router lists, reads and writes in a Task a station hosts", context do
    assert {:ok, %{"station_tasks" => [listed]}} =
             router_call(context.router, "internal.task.list", %{})

    assert %{"task_id" => ref, "title" => "Fix the build", "hosted_on" => device} = listed
    assert ref == context.ref
    assert device == context.view.device_id

    # Offline: neither read nor written.
    assert {:error, "the station hosting this Task is offline" <> _} =
             router_call(context.router, "internal.read_conversation", %{"conversation_id" => ref})

    run_id = connect!(context.view)

    assert {:ok, %{"messages" => [%{"text" => "fix it"}], "through_seq" => 1}} =
             router_call(context.router, "internal.read_conversation", %{"conversation_id" => ref})

    assert_received {:asked, ^run_id, "task.read", %{"task" => "EMBER/1792.000100", "after" => 0}}

    assert {:ok, %{"seq" => 2, "conversation_id" => ^ref}} =
             router_call(context.router, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => "run the tests too",
               "request_id" => "req-1"
             })

    assert_received {:asked, ^run_id, "task.say",
                     %{
                       "task" => "EMBER/1792.000100",
                       "text" => "run the tests too",
                       "key" => "req-1"
                     }}

    # A Group that enforces information-flow checks: no unlabeled station content.
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, __MODULE__.EnforcingFacts)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod) end)

    assert {:error, "this Group enforces information-flow checks" <> _} =
             router_call(context.router, "internal.read_conversation", %{"conversation_id" => ref})

    refute_received {:asked, _, _, _}
    SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod)

    # A Task no station of the Group hosts.
    assert {:error, "unknown station-hosted Task"} =
             router_call(context.router, "internal.read_conversation", %{
               "conversation_id" => "station:#{String.duplicate("cd", 32)}:7"
             })
  end

  defp connect!(view) do
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => view.tenant_id,
          "group_id" => view.group_id,
          "device_id" => view.device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Laptop"
        },
        transport_id: transport_id
      )

    record["connector_run_id"]
  end
end
