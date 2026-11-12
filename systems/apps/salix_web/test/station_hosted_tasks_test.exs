defmodule SalixWeb.StationHostedTasksTest do
  @moduledoc """
  A Router and the Tasks its Group's stations host (`SalixWeb.StationHostedTasks`
  behind `SalixIM.Ports.StationHostedTasks`): `internal.task.list` lists them
  from the Task index, `internal.read_conversation` reads one and
  `internal.send_message` writes in it through the station's Connector
  (`task.read`, `task.say`), also where the Group enforces IFC, and a station
  that is offline answers neither.
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
               },
               # Milestones its agent recorded alone: no text.
               %{
                 "seq" => 2,
                 "author_kind" => "agent",
                 "author" => "ember:c-1",
                 "text" => "",
                 "at" => 2,
                 "milestones" => ["Found the failing test"]
               }
             ],
             "through" => 2
           }}

        "task.say" ->
          {:ok, %{"seq" => 3}}
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

    # Each test its own station: a station admitted again moves to the new Group.
    station_id =
      Base.encode16(<<SystemsRuntime.Proc.unique_integer([:positive])::256>>, case: :lower)

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
     station_id: station_id,
     ref: "station:#{station_id}:7"}
  end

  defp router_call(agent_id, api, params) do
    SalixIM.Provider.call_api(agent_id, "internal", api, %{
      "connect_id" => "internal",
      "params" => params
    })
  end

  test "a Router pages a station's Tasks with their creators and adds up what was spent on each",
       context do
    {:ok, station} = Stations.active_station(context.station_id)

    {:ok, _held} =
      StationTaskIndex.apply_page(station, context.view.device_id, %{
        "epoch" => "e1",
        "since" => 1,
        "through" => 2,
        "rows" => [
          %{
            "thread" => "8",
            "rev" => 2,
            "title" => "Write the report",
            "status" => "done",
            "created_by" => "ann@x",
            "created_at" => 1_500,
            "last_activity_at" => 3_000,
            "attention" => "done",
            "waits_for" => ["bob@x"],
            "note" => "The report is in report.md.",
            "url" => "https://still.fail/c/8"
          }
        ]
      })

    assert {:ok, %{"tasks" => [first], "has_more" => true, "next_cursor" => cursor}} =
             router_call(context.router, "internal.station_task.list", %{"limit" => 1})

    assert %{"task_id" => "station:" <> _, "title" => "Write the report", "created_by" => "ann@x"} =
             first

    assert {:ok, %{"tasks" => [%{"task_id" => ref}], "has_more" => false}} =
             router_call(context.router, "internal.station_task.list", %{
               "limit" => 1,
               "cursor" => cursor
             })

    assert ref == context.ref

    assert {:ok, %{"tasks" => [%{"title" => "Write the report"}]}} =
             router_call(context.router, "internal.station_task.list", %{"created_by" => "ann@x"})

    # What a still.fail chat asks of whom, and only the Tasks that wait for one person.
    assert {:ok, %{"tasks" => [asks], "has_more" => false}} =
             router_call(context.router, "internal.station_task.list", %{
               "waits_for" => "Bob@x",
               "attention" => "done"
             })

    assert %{
             "title" => "Write the report",
             "attention" => "done",
             "waits_for" => ["bob@x"],
             "note" => "The report is in report.md.",
             "url" => "https://still.fail/c/8"
           } = asks

    # A Task whose station says nothing of it carries none of these.
    assert {:ok, %{"tasks" => [plain]}} =
             router_call(context.router, "internal.station_task.list", %{"cursor" => cursor})

    refute Enum.any?(~w(attention waits_for note url), &Map.has_key?(plain, &1))

    assert {:ok, %{"tasks" => []}} =
             router_call(context.router, "internal.station_task.list", %{"waits_for" => "ann@x"})

    assert {:error, "attention must be one of" <> _} =
             router_call(context.router, "internal.station_task.list", %{"attention" => "x"})

    {:ok, station} = Stations.active_station(context.station_id)

    {:ok, _} =
      SalixStore.StationStatsIndex.apply_page(station, context.view.device_id, %{
        "epoch" => "s1",
        "reset" => true,
        "since" => 0,
        "through" => 0,
        "rows" => [
          %{
            "key" => "u1",
            "source" => "stillfail",
            "kind" => "usage",
            "rev" => 1,
            "row" => %{
              "day" => "2026-11-02",
              "session" => "s1",
              "thread" => 8,
              "person" => "ann@x",
              "model" => "m",
              "runtime" => "claude",
              "calls" => 3,
              "input" => 30,
              "cacheRead" => 0,
              "cacheWrite" => 0,
              "output" => 3,
              "cost" => 1.25
            }
          }
        ]
      })

    assert {:ok,
            %{"by" => "task", "rows" => [%{"key" => task_key, "calls" => 3, "cost" => 1.25}]}} =
             router_call(context.router, "internal.usage.query", %{
               "from" => "2026-11-01",
               "to" => "2026-11-30",
               "by" => "task",
               "person" => "ann@x"
             })

    assert task_key == "station:#{context.station_id}:8"

    assert {:error, "by must be one of" <> _} =
             router_call(context.router, "internal.usage.query", %{
               "from" => "2026-11-01",
               "to" => "2026-11-30",
               "by" => "nonsense"
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

    assert {:ok,
            %{
              "messages" => [
                %{"text" => "fix it"},
                %{"text" => "", "milestones" => ["Found the failing test"]}
              ],
              "through_seq" => 2
            }} =
             router_call(context.router, "internal.read_conversation", %{"conversation_id" => ref})

    assert_received {:asked, ^run_id, "task.read", %{"task" => "EMBER/1792.000100", "after" => 0}}

    assert {:ok, %{"seq" => 3, "conversation_id" => ^ref}} =
             router_call(context.router, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => "run the tests too",
               "request_id" => "req-1"
             })

    assert_received {:asked, ^run_id, "task.say",
                     %{
                       "task" => "EMBER/1792.000100",
                       "text" => "run the tests too",
                       "key" => "req-1",
                       "requester_name" => "Hosted"
                     }}

    # A Group that enforces information-flow checks reads it too: the IFC
    # check labels the unlabelled read, not this port.
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, __MODULE__.EnforcingFacts)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod) end)

    assert {:ok, %{"through_seq" => 2}} =
             router_call(context.router, "internal.read_conversation", %{"conversation_id" => ref})

    assert_received {:asked, ^run_id, "task.read", %{"task" => "EMBER/1792.000100"}}
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
