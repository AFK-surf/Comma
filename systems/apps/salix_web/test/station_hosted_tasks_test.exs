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

        "task.read_file" ->
          {:ok,
           %{
             "name" => params["file"],
             "size" => 4,
             "offset" => params["offset"],
             "data" => Base.encode64("PNG!")
           }}
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

  test "a Worker reads the Group's station-hosted Tasks, one device's, by their words, and writes in none",
       context do
    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => context.view.group_id, "name" => "Worker", "role" => "worker"},
        context.view.tenant_id
      )

    worker = worker["agent_id"]

    assert {:ok, %{"tasks" => [%{"task_id" => ref, "title" => "Fix the build"}]}} =
             router_call(worker, "internal.station_task.list", %{
               "device_id" => context.view.device_id,
               "query" => "the BUILD"
             })

    assert ref == context.ref

    assert {:ok, %{"tasks" => []}} =
             router_call(worker, "internal.station_task.list", %{"query" => "report"})

    assert {:ok, %{"tasks" => []}} =
             router_call(worker, "internal.station_task.list", %{"device_id" => "device-other"})

    assert {:ok, %{"by" => "station", "rows" => []}} =
             router_call(worker, "internal.usage.query", %{
               "from" => "2026-11-01",
               "to" => "2026-11-30",
               "by" => "station",
               "device_id" => context.view.device_id
             })

    run_id = connect!(context.view)

    assert {:ok, %{"through_seq" => 2}} =
             router_call(worker, "internal.read_conversation", %{"conversation_id" => ref})

    assert_received {:asked, ^run_id, "task.read", %{"task" => "EMBER/1792.000100"}}

    assert {:error, "only the Router writes in a Task a station hosts"} =
             router_call(worker, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => "done?",
               "request_id" => "req-w"
             })

    refute_received {:asked, _, "task.say", _}
  end

  test "say/7 forwards normalized requester_email and omits invalid or missing emails", context do
    run_id = connect!(context.view)
    scope = %{tenant_id: context.view.tenant_id, group_id: context.view.group_id}

    assert {:ok, %{"seq" => 3}} =
             SalixWeb.StationHostedTasks.say(
               scope,
               context.station_id,
               "7",
               "Proceed",
               "k-opt",
               "Router",
               %{"requester_email" => "  Alice.Doe@Example.COM "}
             )

    assert_received {:asked, ^run_id, "task.say",
                     %{
                       "key" => "k-opt",
                       "requester_email" => "alice.doe@example.com"
                     }}

    assert {:ok, %{"seq" => 3}} =
             SalixWeb.StationHostedTasks.say(
               Map.put(scope, :requester_email, "  Bob@Example.ORG "),
               context.station_id,
               "7",
               "Scope fallback",
               "k-scope",
               "Router",
               %{}
             )

    assert_received {:asked, ^run_id, "task.say",
                     %{
                       "key" => "k-scope",
                       "requester_email" => "bob@example.org"
                     }}

    for {key, bad_email} <- [
          {"k-nil", nil},
          {"k-blank", "   "},
          {"k-no-at", "not-an-email"},
          {"k-colon", "alice:bob@example.com"},
          {"k-too-long", String.duplicate("a", 190) <> "@example.com"}
        ] do
      assert {:ok, %{"seq" => 3}} =
               SalixWeb.StationHostedTasks.say(
                 scope,
                 context.station_id,
                 "7",
                 "Invalid",
                 key,
                 "Router",
                 %{"requester_email" => bad_email}
               )

      assert_received {:asked, ^run_id, "task.say", params}
      assert params["key"] == key
      refute Map.has_key?(params, "requester_email")
    end
  end

  test "say/7 maps the default workspace name to Comma unless requester is custom", context do
    tenant_id = context.view.tenant_id
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Default workspace"}, tenant_id)
    group_id = group["group_id"]

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

    run_id = connect!(%{tenant_id: tenant_id, group_id: group_id, device_id: device_id})
    scope = %{tenant_id: tenant_id, group_id: group_id}

    assert {:ok, %{"seq" => 3}} =
             SalixWeb.StationHostedTasks.say(scope, station_id, "7", "Proceed", "k-def", "Router")

    assert_received {:asked, ^run_id, "task.say",
                     %{"key" => "k-def", "requester_name" => "Comma"}}

    assert {:ok, %{"seq" => 3}} =
             SalixWeb.StationHostedTasks.say(
               scope,
               station_id,
               "7",
               "Proceed",
               "k-custom",
               "Ops Router"
             )

    assert_received {:asked, ^run_id, "task.say",
                     %{"key" => "k-custom", "requester_name" => "Ops Router"}}
  end

  test "read_file/6 requests task.read_file with seq, file, and offset", context do
    run_id = connect!(context.view)
    scope = %{tenant_id: context.view.tenant_id, group_id: context.view.group_id}

    assert {:ok, %{"name" => "shot.png", "size" => 4, "offset" => 2, "data" => "UE5HIQ=="}} =
             SalixWeb.StationHostedTasks.read_file(scope, context.station_id, "7", 19, "shot.png", 2)

    assert_received {:asked, ^run_id, "task.read_file",
                     %{
                       "task" => "EMBER/1792.000100",
                       "seq" => 19,
                       "file" => "shot.png",
                       "offset" => 2
                     }}
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
