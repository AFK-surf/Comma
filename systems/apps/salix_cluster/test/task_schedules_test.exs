defmodule SalixCluster.TaskSchedulesTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixCluster"]
  alias SalixCalendar.Server
  alias SalixCalendar.SourceAdapter.SalixTaskSchedule
  alias SalixCluster.{Schedules, TaskSchedules}

  alias SalixIM.{
    ConversationInput,
    ConversationServer,
    Conversations,
    Provider,
    RouterConversationInput,
    TaskCalendarChanges
  }

  alias SalixStore.{Ids, Keys, S3}

  defmodule NoopAgentDelivery do
    @behaviour SalixIM.Ports.AgentDelivery

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      if pid = SystemsRuntime.get_env(:salix_cluster, :task_schedule_test_pid) do
        SystemsRuntime.Proc.send(pid, {:agent_delivery, agent_id, payload, opts})
      end

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_found}
  end

  defmodule StationsFake do
    @moduledoc "The stations a Task runs on (`SalixIM.Ports.TaskStations`): what they are asked, and how they answer."
    @behaviour SalixIM.Ports.TaskStations

    defp tell(message) do
      if pid = SystemsRuntime.get_env(:salix_cluster, :task_schedule_test_pid),
        do: SystemsRuntime.Proc.send(pid, message)
    end

    @impl true
    def invite(invitation) do
      tell({:station_invite, invitation})
      SystemsRuntime.get_env(:salix_cluster, :station_answer, {:ok, "ember:c-1"})
    end

    @impl true
    def joined(row), do: tell({:station_joined, row}) && :ok

    @impl true
    def standing(_group_id, _conversation_id), do: :not_station

    @impl true
    def appended(group_id, conversation_id),
      do: tell({:station_appended, group_id, conversation_id}) && :ok

    @impl true
    def sandbox(reservation), do: tell({:sandbox_reserved, reservation}) && :ok

    @impl true
    def task_status(group_id, conversation_id, status),
      do: tell({:sandbox_task_status, group_id, conversation_id, status}) && :ok
  end

  defmodule SandboxPorts do
    @moduledoc "The product's check of a coding Task's place: any repository is readable, from main."
    def runs_on(_scope, %{"kind" => "sandbox", "repo" => repo}),
      do: {:ok, %{"kind" => "sandbox", "repo" => Map.put_new(repo, "base_ref", "main")}}

    def session_model(_scope, choice), do: {:ok, choice}
    def task_worker(scope), do: SalixAgent.TaskAgent.ensure(scope)
    def default_task_model(_scope), do: {:ok, nil}

    defdelegate create_task_conversation(group_id, delegator, worker, attrs),
      to: Salix.Bindings.AgentConversations
  end

  defmodule TaskCreateReceipt do
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(%{boundary: :tool_result, payload: %{"async" => true, "results" => results}}) do
      for result <- results,
          (result[:id] || result["id"]) == "create-reporting-schedule" do
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_cluster, :task_schedule_test_pid),
          {:scheduled_task_receipt, result}
        )
      end

      :ok
    end

    def record(_fact), do: :ok
  end

  defmodule ReportDestinationRouterLLM do
    @behaviour SalixAgent.LLM

    @destination "Slack channel C-report, thread 1785400205.698689"

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete(messages, tools, opts),
      do: complete_stream(messages, tools, fn _ -> :ok end, opts)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, _tools, _on_delta, _opts) do
      text =
        Enum.map_join(messages, "\n", fn message ->
          to_string(message[:content] || message["content"] || "")
        end)

      cond do
        task_created?(messages) ->
          {:final, "Scheduled Task created."}

        # Task operations are not pre-disclosed. Like a model, read the
        # operation's schema and guidance through help before calling it.
        not tool_result?(messages, "help") ->
          {:assistant, "",
           [
             %{
               id: "read-task-create-help",
               name: "call",
               args: %{"tool" => "help", "params" => %{"tool" => "im_api.internal.task.create"}}
             }
           ]}

        true ->
          create_schedule(text)
      end
    end

    defp create_schedule(text) do
      [_, worker_id] = Regex.run(~r/worker_id=([A-Za-z0-9_-]+)/, text)

      command =
        "Prepare the scheduled repository health report."
        |> maybe_add_report_handoff(text)

      {:assistant, "",
       [
         %{
           id: "create-reporting-schedule",
           name: "call",
           args: %{
             "tool" => "im_api.internal.task.create",
             "params" => %{
               "runs_on" => %{"kind" => "default"},
               "connect_id" => "internal",
               "agent_id" => worker_id,
               "content" => command,
               "schedule" => %{"interval_minutes" => 5}
             }
           }
         }
       ]}
    end

    def destination, do: @destination

    defp maybe_add_report_handoff(command, prompt) do
      if String.contains?(
           prompt,
           "repeat the exact destination in its final Task response"
         ) do
        command <>
          " Report only in the Task conversation; do not deliver externally. " <>
          "In the final Task response, repeat the exact reporting destination as a reminder " <>
          "to the Router: #{@destination}."
      else
        command
      end
    end

    defp task_created?(messages), do: tool_result?(messages, "im_api.internal.task.create")

    defp tool_result?(messages, name) do
      Enum.any?(messages, fn message ->
        role = message[:role] || message["role"]
        tool_name = message[:tool_name] || message["tool_name"]
        role == "tool" and tool_name == name
      end)
    end
  end

  defmodule ScheduledFailureLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def configure(conversation_id, opts \\ []),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, conversation_id, %{
            call: 0,
            retry_failure?: Keyword.get(opts, :retry_failure?, true)
          })
        )

    def calls(conversation_id),
      do: Agent.get(__MODULE__, &(get_in(&1, [conversation_id, :call]) || 0))

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete(messages, tools, opts),
      do: complete_stream(messages, tools, fn _ -> :ok end, opts)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, _tools, _on_delta, _opts) do
      with {:ok, conversation_id} <- scheduled_conversation_id(messages),
           {call, retry_failure?} <- next_call(conversation_id) do
        case call do
          1 ->
            {:assistant, "",
             [
               tool_call("missing-slack", "im.provider_apis_list", %{"provider" => "slack"}),
               failed_task_message("scheduled-failure", conversation_id)
             ]}

          2 when retry_failure? ->
            {:assistant, "", [failed_task_message("scheduled-failure-retry", conversation_id)]}

          _ ->
            {:final, "done"}
        end
      else
        _ -> {:final, "done"}
      end
    end

    defp scheduled_conversation_id(messages) do
      Enum.find_value(messages, :not_scheduled_task, fn message ->
        content = message[:content] || message["content"] || ""

        with true <- is_binary(content),
             true <- String.contains?(content, "This is production Task Schedule window"),
             [_, conversation_id] <- Regex.run(~r/^\s*- conversation_id: (\S+)$/m, content) do
          {:ok, conversation_id}
        else
          _ -> false
        end
      end)
    end

    defp next_call(conversation_id) do
      Agent.get_and_update(__MODULE__, fn scenarios ->
        case scenarios[conversation_id] do
          %{call: call, retry_failure?: retry_failure?} = scenario ->
            call = call + 1

            {{call, retry_failure?},
             put_in(scenarios, [conversation_id], %{scenario | call: call})}

          nil ->
            {:not_configured, scenarios}
        end
      end)
    end

    defp failed_task_message(id, conversation_id) do
      tool_call(id, "im_api.internal.send_message", %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id,
        "content" => "PRIVATE provider diagnostic: provider is not visible to this session"
      })
    end

    defp tool_call(id, tool, params),
      do: %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    # Schedules live in the node-global control Postgres now, which no
    # S3.Fake.reset can clear — every file expecting a clean slate truncates.
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      task_change_feed: SystemsRuntime.get_env(:salix_calendar, :task_change_feed_mod),
      task_create: SystemsRuntime.get_env(:salix_im, :task_create_mod),
      task_schedule: SystemsRuntime.get_env(:salix_im, :task_schedule_mod),
      delivery: SystemsRuntime.get_env(:salix_im, :agent_delivery_mod),
      task_stations: SystemsRuntime.get_env(:salix_im, :task_stations_mod),
      transfer_port: SystemsRuntime.get_env(:salix_env, :transfer_port),
      test_pid: SystemsRuntime.get_env(:salix_cluster, :task_schedule_test_pid),
      diagnostic_sink: SystemsRuntime.get_env(:salix_cluster, :schedule_diagnostic_sink)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_calendar, :task_change_feed_mod, TaskCalendarChanges)

    SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    SystemsRuntime.put_env(:salix_im, :task_schedule_mod, Salix.Bindings.AgentConversations)

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, NoopAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :task_stations_mod, StationsFake)
    SystemsRuntime.put_env(:salix_env, :transfer_port, 0)
    SystemsRuntime.put_env(:salix_cluster, :task_schedule_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.delete_env(:salix_cluster, :schedule_diagnostic_sink)
    {:ok, _started} = Application.ensure_all_started(:salix_cluster)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous.s3)
        restore(:salix_calendar, :task_change_feed_mod, previous.task_change_feed)
        restore(:salix_im, :task_create_mod, previous.task_create)
        restore(:salix_im, :task_schedule_mod, previous.task_schedule)
        restore(:salix_im, :agent_delivery_mod, previous.delivery)
        restore(:salix_im, :task_stations_mod, previous.task_stations)
        SystemsRuntime.delete_env(:salix_cluster, :station_answer)
        restore(:salix_env, :transfer_port, previous.transfer_port)
        restore(:salix_cluster, :task_schedule_test_pid, previous.test_pid)
        restore(:salix_cluster, :schedule_diagnostic_sink, previous.diagnostic_sink)
      end
    end)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Scheduled tasks"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok, tenant_id: tenant_id, group_id: group_id, router: router, worker: worker}
  end

  test "im_api.internal.task.create groups the Schedule id and command and fires through the shared table",
       %{
         group_id: group_id,
         router: router,
         worker: worker
       } do
    created =
      create_task(router["agent_id"], %{
        "agent_id" => worker["agent_id"],
        "content" => "Check the repository and report every finding.",
        "schedule" => %{"interval_minutes" => 5}
      })

    conversation_id = created["conversation_id"]
    assert %{"schedule_id" => schedule_id, "command" => command} = created["schedule"]

    assert {:ok, conversation} = Conversations.get_group_conversation(group_id, conversation_id)
    assert conversation["schedule"] == created["schedule"]
    assert conversation["message_count"] == 1

    assert command == "Check the repository and report every finding."

    refute Map.has_key?(conversation, "command")

    assert {:ok, schedule} = Schedules.get(schedule_id)
    assert schedule["receiver"] == "task"
    assert schedule["interval_minutes"] == 5

    assert schedule["payload"] == %{
             "agent_group_id" => group_id,
             "conversation_id" => conversation_id
           }

    refute Enum.any?(SalixStore.S3.Fake.dump(), fn {key, _value} ->
             String.starts_with?(key, "ctl/task_schedules/")
           end)

    due = Schedules.next_fire_ms(schedule)

    assert {:ok, before_fire_projection} =
             TaskSchedules.calendar_projection(group_id, conversation_id, created["schedule"])

    assert before_fire_projection["recurrence_anchor_at"] == due
    assert before_fire_projection["next_fire_at"] == due

    assert {:ok, %{fired: []}} = Schedules.run_once(now: due - 1)
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

    assert {:ok, after_fire_projection} =
             TaskSchedules.calendar_projection(group_id, conversation_id, created["schedule"])

    assert after_fire_projection["recurrence_anchor_at"] == due
    assert after_fire_projection["next_fire_at"] == due + :timer.minutes(5)

    assert {:ok, [initial, scheduled]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert_initial_dry_run_envelope(message_text(initial), command)
    assert initial["actor_type"] == "agent"
    assert initial["agent_id"] == router["agent_id"]
    assert initial["metadata"]["message_type"] == "task_command"

    assert initial["metadata"]["task_schedule"] == %{
             "dry_run" => true,
             "schedule_id" => schedule_id
           }

    assert message_text(scheduled) == command
    assert scheduled["metadata"]["message_type"] == "task_command"
    assert scheduled["metadata"]["task_schedule"]["schedule_id"] == schedule_id
    assert scheduled["metadata"]["task_schedule"]["scheduled_for"] == due

    worker_id = worker["agent_id"]
    router_id = router["agent_id"]

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker_participant = Enum.find(participants, &(&1["agent_id"] == worker_id))
    router_participant = Enum.find(participants, &(&1["agent_id"] == router_id))

    scheduled_source =
      "groupconv:#{conversation_id}:#{scheduled["message_id"]}:#{worker_participant["participant_id"]}"

    router_source =
      "groupconv:#{conversation_id}:#{scheduled["message_id"]}:#{router_participant["participant_id"]}"

    settle_receive(
      {:agent_delivery, ^worker_id, _payload, [{:source_message_id, ^scheduled_source} | _]}
    )

    settle_refute_receive(
      {:agent_delivery, ^router_id, _payload, [{:source_message_id, ^router_source} | _]},
      100
    )

    assert {:ok, report} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "content" => "Today's check is complete.",
                 "client_request_id" => "worker-report-1"
               }
             )

    report_source =
      "groupconv:#{conversation_id}:#{report["message_id"]}:#{router_participant["participant_id"]}"

    settle_receive(
      {:agent_delivery, ^router_id, _payload, [{:source_message_id, ^report_source} | _]}
    )
  end

  defmodule ChoosingPorts do
    @moduledoc false
    def session_model(_scope, choice), do: {:ok, Map.put(choice, "checked", true)}
    def task_worker(scope), do: SalixAgent.TaskAgent.ensure(scope)
  end

  test "a Task that runs on a station: the station is invited first, then given every Message; Salix runs no Worker",
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         router: router,
         worker: worker
       } do
    previous = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, ChoosingPorts)
    on_exit(fn -> restore(:salix_agent, :agent_management_ports, previous) end)

    device_id = connect_station!(tenant_id, group_id)
    worker_id = worker["agent_id"]
    choice = %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"}
    runs_on = %{"kind" => "station", "device_id" => device_id}

    created =
      create_task(router["agent_id"], %{
        "agent_id" => worker_id,
        "content" => "Run the benchmark.",
        "model" => choice,
        "runs_on" => runs_on
      })

    conversation_id = created["conversation_id"]

    assert_received {:station_invite,
                     %{device_id: ^device_id, conversation_id: ^conversation_id, start: start}}

    assert Map.take(start, ~w(runtime model)) == %{"runtime" => "codex", "model" => "gpt-5.5"}

    assert_received {:station_joined,
                     %{
                       device_id: ^device_id,
                       conversation_id: ^conversation_id,
                       session: "ember:c-1",
                       agent_id: ^worker_id
                     }}

    {:ok, _} =
      ConversationServer.append_group_conversation_agent_message(
        group_id,
        conversation_id,
        router["agent_id"],
        %{"content" => "Also profile the slowest case.", "client_request_id" => "follow-up-1"}
      )

    settle_receive({:station_appended, ^group_id, ^conversation_id})
    refute_received {:agent_delivery, ^worker_id, _payload, _opts}
  end

  test "a coding Task reserves its sandbox instead of inviting a station, and keeps its repository and session branch",
       %{group_id: group_id, router: router} do
    previous = SystemsRuntime.get_env(:salix_im, :task_create_mod)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, SandboxPorts)
    on_exit(fn -> restore(:salix_im, :task_create_mod, previous) end)

    created =
      create_task(router["agent_id"], %{
        "content" => "Fix the flaky retry test.",
        "model" => %{"kind" => "runtime", "provider" => "claude"},
        "runs_on" => %{"kind" => "sandbox"},
        "repo" => %{"owner" => "acme", "name" => "api"}
      })

    conversation_id = created["conversation_id"]
    device_id = "dev-sbx-" <> conversation_id
    refute_received {:station_invite, _}

    assert_received {:sandbox_reserved,
                     %{
                       conversation_id: ^conversation_id,
                       device_id: ^device_id,
                       start: start,
                       repo: %{
                         "owner" => "acme",
                         "name" => "api",
                         "base_ref" => "main",
                         "branch" => branch
                       }
                     }}

    assert "comma/" <> _ = branch
    assert start["runtime"] == "claude"
    assert start["repo"]["branch"] == branch

    {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["runs_on"] == %{"kind" => "sandbox", "device_id" => device_id}
    assert task["repo"]["branch"] == branch

    # Without a repository there is no coding Task.
    assert {:error, message} =
             call_task_create(
               router["agent_id"],
               %{
                 "content" => "Fix it.",
                 "runs_on" => %{"kind" => "sandbox"}
               },
               %{}
             )

    assert message =~ "needs repo"
  end

  test "a Task that names no place runs at the Group's default place, checked as a named one",
       %{tenant_id: tenant_id, group_id: group_id, router: router, worker: worker} do
    previous = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, ChoosingPorts)
    on_exit(fn -> restore(:salix_agent, :agent_management_ports, previous) end)

    {device_id, run_id} = connect_station_run!(tenant_id, group_id)
    worker_id = worker["agent_id"]
    station = %{"kind" => "station", "device_id" => device_id}

    # A Worker of a Task on a station is delivered nothing; inside Salix it is.
    on_station? = fn created ->
      {:ok, %{"participants" => participants}} =
        Conversations.list_group_conversation_participants(group_id, created["conversation_id"])

      participants
      |> Enum.find(&(&1["agent_id"] == worker_id))
      |> SalixIM.TaskConversationInput.station_worker?()
    end

    # A Group that has set none runs it inside Salix.
    inside = create_task(router["agent_id"], %{"agent_id" => worker_id, "content" => "First."})
    refute on_station?.(inside)
    refute_received {:station_invite, _invitation}

    assert {:ok, ^station} = SalixAgent.TaskPlace.put(tenant_id, group_id, station)

    created = create_task(router["agent_id"], %{"agent_id" => worker_id, "content" => "Second."})
    conversation_id = created["conversation_id"]

    assert_received {:station_invite,
                     %{device_id: ^device_id, conversation_id: ^conversation_id, start: start}}

    # No model: the station runs its default.
    refute Map.has_key?(start, "model")
    assert on_station?.(created)

    # A model only Salix runs, or runs_on {kind: salix}, runs it inside Salix.
    for params <- [
          %{"model" => SalixAgent.TaskModel.platform()},
          %{"runs_on" => %{"kind" => "salix"}}
        ] do
      created =
        create_task(
          router["agent_id"],
          Map.merge(%{"agent_id" => worker_id, "content" => "Inside."}, params)
        )

      refute on_station?.(created)
      refute_received {:station_invite, _invitation}
    end

    # An offline default station refuses the Task as a named one does.
    {:ok, _} = SalixEnv.Registry.mark_disconnected(run_id)

    assert {:error, refused} =
             call_task_create(
               router["agent_id"],
               %{"agent_id" => worker_id, "content" => "Third."},
               %{}
             )

    assert refused =~ "that station is not connected now; the Task was not made"
    assert refused =~ "default place to run Tasks"
    refute_received {:station_invite, _invitation}
  end

  test "a product's Task runs on the Group's Task agent, at the place and model it names",
       %{tenant_id: tenant_id, group_id: group_id, router: router} do
    previous = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, ChoosingPorts)
    on_exit(fn -> restore(:salix_agent, :agent_management_ports, previous) end)

    {device_id, run_id} = connect_station_run!(tenant_id, group_id)
    station = %{"kind" => "station", "device_id" => device_id}
    choice = %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"}
    create = &SalixIM.TaskPlacement.create_task_conversation(group_id, router["agent_id"], &1)

    assert {:ok, %{"conversation_id" => id, "worker_agent_id" => task_agent}} =
             create.(%{
               "title" => "Benchmark",
               "content" => "Run the benchmark.",
               "client_request_id" => "dashboard-1",
               "runs_on" => station,
               "model" => choice
             })

    assert {:ok, ^task_agent} = SalixAgent.TaskAgent.get(group_id)

    assert_received {:station_invite,
                     %{device_id: ^device_id, conversation_id: ^id, start: start}}

    assert start["model"] == "gpt-5.5"

    # Without a place it runs at the Group's default place, as a Router's Task does.
    assert {:ok, ^station} = SalixAgent.TaskPlace.put(tenant_id, group_id, station)

    assert {:ok, %{"conversation_id" => default_id}} =
             create.(%{"content" => "Again.", "client_request_id" => "dashboard-2"})

    assert_received {:station_invite, %{device_id: ^device_id, conversation_id: ^default_id}}

    # A place it cannot use refuses the Task, with where the place came from.
    {:ok, _} = SalixEnv.Registry.mark_disconnected(run_id)

    assert create.(%{"content" => "Third.", "client_request_id" => "dashboard-3"}) ==
             {:error, {:runs_on, :device_offline, :default}}

    assert create.(%{
             "content" => "Fourth.",
             "client_request_id" => "dashboard-4",
             "runs_on" => %{"kind" => "cloud_vm"}
           }) == {:error, {:runs_on, :cloud_vm_disabled, :requested}}

    refute_received {:station_invite, _invitation}

    # Only the Group's current Router delegates it.
    worker_as_router =
      SalixIM.TaskPlacement.create_task_conversation(group_id, task_agent, %{"content" => "No."})

    assert worker_as_router == {:error, :router_changed}
  end

  test "a Task on a station may name only its runtime: the station runs its default model",
       %{tenant_id: tenant_id, group_id: group_id, router: router, worker: worker} do
    device_id = connect_station!(tenant_id, group_id)
    runtime = %{"kind" => "runtime", "provider" => "codex"}

    created =
      create_task(router["agent_id"], %{
        "agent_id" => worker["agent_id"],
        "content" => "Run the benchmark.",
        "model" => runtime,
        "runs_on" => %{"kind" => "station", "device_id" => device_id}
      })

    conversation_id = created["conversation_id"]

    assert_received {:station_invite,
                     %{device_id: ^device_id, conversation_id: ^conversation_id, start: start}}

    assert start["runtime"] == "codex"
    refute Map.has_key?(start, "model")

    assert {:error, "model of kind runtime requires runs_on"} =
             call_task_create(
               router["agent_id"],
               %{
                 "agent_id" => worker["agent_id"],
                 "content" => "Inside Salix.",
                 "model" => runtime,
                 "runs_on" => %{"kind" => "salix"}
               },
               %{}
             )
  end

  test "a Task inside Salix that names no model runs the Group's default Task model",
       %{tenant_id: tenant_id, group_id: group_id, router: router, worker: worker} do
    previous = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, ChoosingPorts)
    on_exit(fn -> restore(:salix_agent, :agent_management_ports, previous) end)

    worker_id = worker["agent_id"]

    session_model = fn params ->
      created =
        create_task(router["agent_id"], Map.put(params, "agent_id", worker_id))

      {:ok, %{"participants" => participants}} =
        Conversations.list_group_conversation_participants(group_id, created["conversation_id"])

      participants
      |> Enum.find(&(&1["agent_id"] == worker_id))
      |> get_in(["payload", "session_model"])
    end

    # A Group that has set none leaves the Worker's model.
    assert session_model.(%{"content" => "First."}) == nil

    catalog = %{"kind" => "catalog", "model" => "gpt-5.5", "reasoning_effort" => "high"}
    assert {:ok, ^catalog} = SalixAgent.TaskModel.put_new(tenant_id, group_id, catalog)
    assert session_model.(%{"content" => "Second."}) == catalog

    # The Router's choice for one Task wins.
    platform = SalixAgent.TaskModel.platform()

    assert session_model.(%{"content" => "Third.", "model" => platform}) ==
             Map.put(platform, "checked", true)

    assert {:ok, ^platform} = SalixAgent.TaskModel.put(tenant_id, group_id, platform)
    assert session_model.(%{"content" => "Fourth."}) == platform

    # Cleared, the Group has set none again: the Worker's model applies.
    assert {:ok, nil} = SalixAgent.TaskModel.put(tenant_id, group_id, nil)
    assert {:ok, nil} = SalixAgent.TaskModel.get(group_id)
    assert session_model.(%{"content" => "Fifth."}) == nil
  end

  test "a scheduled Task targets every active Worker participant", %{
    tenant_id: tenant_id,
    group_id: group_id,
    router: router,
    worker: first_worker
  } do
    {conversation_id, schedule} =
      create_scheduled_task(group_id, router, first_worker)

    first_worker_id = first_worker["agent_id"]

    settle_receive({:agent_delivery, ^first_worker_id, _initial_payload, _initial_opts})

    second_worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Second Worker",
        "role" => "worker"
      })

    assert {:ok, %{"participant_id" => second_participant_id}} =
             ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{
                 "agent_id" => second_worker["agent_id"],
                 "role_label" => "worker",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               }
             )

    due = Schedules.next_fire_ms(schedule)
    schedule_id = schedule["id"]

    assert {:ok, %{fired: [^schedule_id], failed: []}} =
             Schedules.run_once(now: due)

    assert {:ok, [_initial, scheduled]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert scheduled["delivery_filter"]["participant_ids"] |> length() == 2
    assert second_participant_id in scheduled["delivery_filter"]["participant_ids"]

    deliveries =
      for _ <- 1..2 do
        settle_receive({:agent_delivery, agent_id, _scheduled_payload, scheduled_opts})
        {agent_id, scheduled_opts}
      end

    assert deliveries |> Enum.map(&elem(&1, 0)) |> MapSet.new() ==
             MapSet.new([first_worker["agent_id"], second_worker["agent_id"]])

    expected_sources =
      scheduled["delivery_filter"]["participant_ids"]
      |> Enum.map(&"groupconv:#{conversation_id}:#{scheduled["message_id"]}:#{&1}")
      |> MapSet.new()

    assert deliveries
           |> Enum.map(fn {_agent_id, opts} -> Keyword.fetch!(opts, :source_message_id) end)
           |> MapSet.new() == expected_sources
  end

  test "new delivery owner keeps legacy scheduled dry-run content fenced", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{"content" => "Create a one-shot Task before the compatibility probe."}
             )

    worker_id = worker["agent_id"]

    settle_receive(
      {:agent_delivery, ^worker_id, _initial_payload, [{:source_message_id, _initial_source} | _]}
    )

    legacy_content = """
    Scheduled Task creation dry run

    Production command:
    检查仓库健康并报告所有发现。

    For this dry run only:
    - Do not perform the production task or cause external side effects.
    - Perform only safe, read-only discovery and validation.
    - Do not claim that the production command has completed.
    """

    schedule_id = Ids.new_schedule_id()

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               router["agent_id"],
               %{
                 "content" => legacy_content,
                 "client_request_id" => "legacy-scheduled-dry-run",
                 "metadata" => %{
                   "message_type" => "task_command",
                   "task_schedule" => %{"dry_run" => true, "schedule_id" => schedule_id}
                 }
               }
             )

    settle_receive(
      {:agent_delivery, ^worker_id, legacy_payload, [{:source_message_id, _legacy_source} | _]}
    )

    assert legacy_payload.content == String.trim(legacy_content)
    assert [source_context] = legacy_payload.pre_deliveries
    assert source_context.content =~ "initial read-only Task Schedule dry run"
    assert source_context.content =~ "do not perform the production task"

    assert legacy_payload.trusted_origin["task_schedule"] == %{
             "dry_run" => true,
             "schedule_id" => schedule_id
           }
  end

  test "Router preserves a scheduled Task report destination for Worker reminder and Task-only reporting",
       %{
         group_id: group_id,
         router: router,
         worker: worker
       } do
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_agent, :llm, ReportDestinationRouterLLM)
    on_exit(fn -> restore(:salix_agent, :llm, previous_llm) end)

    router_id = router["agent_id"]
    worker_id = worker["agent_id"]
    session_id = Ids.new_session_id()
    destination = ReportDestinationRouterLLM.destination()

    assert {:ok, :created} =
             SalixAgent.deliver(
               router_id,
               %{
                 session_id: session_id,
                 content:
                   "Create a Task Schedule with worker_id=#{worker_id}. " <>
                     "Every five minutes prepare a repository health report. " <>
                     "The result must be reported to #{destination}."
               },
               source_message_id: "task-schedule-report-destination:#{router_id}"
             )

    conversation =
      eventually_value(fn ->
        with {:ok, %{"data" => conversations}} <-
               Conversations.list_group_conversations(group_id, limit: 100),
             %{"kind" => "agent_task"} = task <-
               Enum.find(conversations, &(&1["kind"] == "agent_task")) do
          {:ok, task}
        else
          _ -> :retry
        end
      end)

    conversation_id = conversation["conversation_id"]
    command = get_in(conversation, ["schedule", "command"])
    schedule_id = get_in(conversation, ["schedule", "schedule_id"])

    assert command =~ destination
    assert command =~ "final Task response"
    assert command =~ "reminder to the Router"
    assert command =~ "Report only in the Task conversation"
    assert command =~ "do not deliver externally"
    assert is_binary(schedule_id) and schedule_id != ""

    settle_receive(
      {:agent_delivery, ^worker_id, initial_payload, [{:source_message_id, _initial_source} | _]}
    )

    assert initial_payload.content =~ command

    schedule =
      eventually_value(fn ->
        case Schedules.get(schedule_id) do
          {:ok, schedule} -> {:ok, schedule}
          {:error, :not_found} -> :retry
        end
      end)

    due = Schedules.next_fire_ms(schedule)
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

    settle_receive(
      {:agent_delivery, ^worker_id, scheduled_payload,
       [{:source_message_id, _scheduled_source} | _]}
    )

    assert scheduled_payload.content == command
    settle_refute_receive({:agent_delivery, ^router_id, ^scheduled_payload, _opts}, 100)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert Enum.all?(participants, &(&1["actor_type"] == "agent"))

    router_participant =
      Enum.find(participants, &(&1["agent_id"] == router_id))

    worker_report =
      "Repository health report complete. Reporting destination reminder for the Router: " <>
        destination

    assert {:ok, report} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "content" => worker_report,
                 "client_request_id" => "scheduled-report-destination-reminder"
               }
             )

    report_source =
      "groupconv:#{conversation_id}:#{report["message_id"]}:#{router_participant["participant_id"]}"

    settle_receive(
      {:agent_delivery, ^router_id, report_payload, [{:source_message_id, ^report_source} | _]}
    )

    assert report_payload.content == worker_report
    assert report_payload.content =~ destination
  end

  test "im_api.internal.task.update changes future command and recurrence in place, then removes Schedule",
       %{
         group_id: group_id,
         router: router,
         worker: worker
       } do
    {conversation_id, original_definition} = create_scheduled_task(group_id, router, worker)
    schedule_id = original_definition["id"]

    assert %{"schedule" => %{"schedule_id" => ^schedule_id, "command" => "new command"}} =
             update_task(router["agent_id"], %{
               "conversation_id" => conversation_id,
               "command" => "new command"
             })

    assert {:ok, command_only_definition} = Schedules.get(schedule_id)
    assert command_only_definition == original_definition

    assert %{"schedule" => %{"schedule_id" => ^schedule_id, "command" => "new command"}} =
             update_task(router["agent_id"], %{
               "conversation_id" => conversation_id,
               "schedule" => %{"interval_minutes" => 10}
             })

    assert {:ok, updated_definition} = Schedules.get(schedule_id)
    assert updated_definition["interval_minutes"] == 10

    assert %{"schedule" => %{"schedule_id" => ^schedule_id, "command" => "final command"}} =
             %{
               "conversation_id" => conversation_id,
               "command" => "final command",
               "schedule" => %{"cron" => "0 17 * * *", "timezone" => "Asia/Shanghai"}
             }
             |> then(&update_task(router["agent_id"], &1))

    assert {:ok, final_definition} = Schedules.get(schedule_id)
    assert final_definition["cron"] == "0 17 * * *"
    assert final_definition["timezone"] == "Asia/Shanghai"
    refute Map.has_key?(final_definition, "interval_minutes")

    assert {:ok, messages_before_due} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages_before_due) == 1

    due = Schedules.next_fire_ms(final_definition)
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

    assert {:ok, [_dry_run, scheduled]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert message_text(scheduled) == "final command"

    assert %{
             "schedule" => %{"schedule_id" => nil, "command" => "final command"},
             "scheduled" => false
           } =
             update_task(router["agent_id"], %{
               "conversation_id" => conversation_id,
               "schedule" => nil
             })

    assert {:error, :not_found} = Schedules.get(schedule_id)

    assert %{
             "schedule" => %{"schedule_id" => replacement_id, "command" => "final command"},
             "scheduled" => true
           } =
             update_task(router["agent_id"], %{
               "conversation_id" => conversation_id,
               "schedule" => %{"interval_minutes" => 15}
             })

    refute replacement_id == schedule_id
  end

  test "Task change feed incrementally imports, tombstones, and restores one Calendar item", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, calendar} =
             Server.create_calendar(group_id, %{
               "name" => "Agent work",
               "default_time_zone" => "Asia/Shanghai"
             })

    assert {:ok, source} =
             Server.ensure_source(group_id, calendar["calendar_id"], %{
               "adapter" => "salix_task_schedule",
               "adapter_contract_id" => SalixTaskSchedule.adapter_contract_id(),
               "source_locator" => %{
                 "kind" => "group_agent_tasks",
                 "group_id" => group_id
               },
               "access_profile" => "scheduled_tasks_read"
             })

    assert {:ok, created} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{
                 "title" => "Weekday status scan",
                 "content" => "Inspect private systems and report results.",
                 "schedule" => %{
                   "cron" => "0 10 * * 1-5",
                   "timezone" => "Asia/Shanghai"
                 }
               }
             )

    query = %{"group_id" => group_id, "object_type" => "Task", "page_size" => 1}

    assert {:ok, first_sync} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert [first_item] = first_sync["applied"]
    item_id = first_item["calendar_item_id"]
    link_id = first_item["scheduling_link_id"]
    assert get_in(first_item, ["object", "recurrenceRules", Access.at(0), "byDay"]) != []
    refute Map.has_key?(first_item["object"], "command")
    refute Map.has_key?(first_item["object"], "messages")
    refute Map.has_key?(first_item["object"], "artifacts")

    assert {:ok, [public_change]} = TaskCalendarChanges.page(group_id, limit: 1) |> page_changes()
    refute Map.has_key?(public_change, "command")
    refute Map.has_key?(public_change, "messages")

    assert {:ok, _updated} =
             put_task_schedule(group_id, created["conversation_id"], %{
               "cron" => "30 10 * * 1-5",
               "timezone" => "Asia/Shanghai"
             })

    assert {:ok, updated_sync} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert [updated_item] = updated_sync["applied"]
    assert updated_item["calendar_item_id"] == item_id
    assert updated_item["scheduling_link_id"] == link_id

    assert {:ok, _unscheduled} = delete_task_schedule(group_id, created["conversation_id"])

    assert {:ok, removed_sync} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert [removed] = removed_sync["applied"]
    assert removed["calendar_item_id"] == item_id
    assert is_integer(removed["tombstoned_at"])

    assert {:ok, _rescheduled} =
             put_task_schedule(group_id, created["conversation_id"], %{
               "interval_minutes" => 15
             })

    assert {:ok, restored_sync} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert [restored] = restored_sync["applied"]
    assert restored["calendar_item_id"] == item_id
    assert restored["scheduling_link_id"] == link_id
    assert restored["tombstoned_at"] == nil
    assert get_in(restored, ["object", "timeZone"]) == "UTC"
    assert String.ends_with?(get_in(restored, ["object", "due"]), "Z")

    assert {:ok, _cancelled} =
             TaskSchedules.update_conversation(group_id, created["conversation_id"], %{
               "status" => "cancelled"
             })

    assert {:ok, cancelled_sync} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert [%{"calendar_item_id" => ^item_id, "tombstoned_at" => cancelled_at}] =
             cancelled_sync["applied"]

    assert is_integer(cancelled_at)

    completed_cursor = cancelled_sync["sync"]["completed_cursor"]

    assert {:ok, empty_sync} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert empty_sync["applied"] == []
    assert empty_sync["sync"]["completed_cursor"] == completed_cursor
  end

  test "an existing run claim is idempotently delivered and advances the Schedule", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    due = Schedules.next_fire_ms(schedule)

    assert :claimed = Schedules.claim_window(schedule["id"], due, %{"fired_at" => due})
    assert {:ok, %{already_fired: [schedule_id], failed: []}} = Schedules.run_once(now: due)
    assert schedule_id == schedule["id"]

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages) == 2

    assert length(
             Enum.filter(messages, &get_in(&1, ["metadata", "task_schedule", "scheduled_for"]))
           ) == 1

    assert {:ok, advanced} = Schedules.get(schedule["id"])
    assert advanced["last_run"] == due
    assert {:ok, %{fired: [], already_fired: []}} = Schedules.run_once(now: due)
  end

  test "release cutover restores a claimed stale Task window", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, created} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{
                 "content" => "Run this command after the release cutover.",
                 "schedule" => %{"cron" => "* * * * *", "timezone" => "UTC"}
               }
             )

    conversation_id = created["conversation_id"]
    assert {:ok, schedule} = Schedules.get(created["schedule"]["schedule_id"])

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker_participant = Enum.find(participants, &(&1["agent_id"] == worker["agent_id"]))
    participant_id = worker_participant["participant_id"]

    assert :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)

    flat_key =
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        participant_id
      )

    nested_key =
      Keys.ctl_group_conversation_participant_dir(
        group_id,
        conversation_id,
        participant_id
      ) <> "state.json"

    assert {:ok, %{body: participant_state}} = S3.get(flat_key)
    assert {:ok, _} = S3.put(nested_key, participant_state)
    assert :ok = S3.delete(flat_key)

    due = Schedules.next_fire_ms(schedule)
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_cluster, :schedule_diagnostic_sink, fn diagnostic ->
      SystemsRuntime.Proc.send(parent, {:schedule_diagnostic, diagnostic})
    end)

    assert {:error, {:bad_request, "task worker participant is missing"}} =
             Schedules.fire(schedule, due, now: due)

    settle_receive({:schedule_diagnostic, diagnostic})
    assert diagnostic.schedule_id == schedule["id"]
    assert diagnostic.agent_group_id == group_id
    assert diagnostic.conversation_id == conversation_id
    assert diagnostic.stage == "receiver"
    refute inspect(diagnostic) =~ "Run this command after the release cutover."

    assert :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)

    # The published migration assumes no serving owners during its cutover.
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    stats =
      SalixIM.Release.migrate_conversation_participant_states(
        confirm_no_writers: true,
        ensure_started: fn :salix_store -> {:ok, []} end
      )

    assert stats.migrated == 1
    refute Map.has_key?(stats, :failed) and stats.failed != []

    assert {:ok,
            %{
              already_fired: [schedule_id],
              skipped: [],
              failed: []
            }} =
             Schedules.run_once(
               now: due + :timer.minutes(11),
               stale_grace_ms: :timer.minutes(10)
             )

    assert schedule_id == schedule["id"]

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(
             Enum.filter(messages, &get_in(&1, ["metadata", "task_schedule", "scheduled_for"]))
           ) == 1

    future_anchor = due + :timer.minutes(10)
    assert {:ok, _} = Schedules.update(schedule["id"], %{"last_run" => future_anchor})

    assert {:ok, :already_fired} =
             Schedules.recover_claim(schedule["id"], due, now: due + :timer.minutes(11))

    assert {:ok, repaired} = Schedules.get(schedule["id"])
    assert repaired["last_run"] == future_anchor

    assert {:ok, messages_after_repair} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(
             Enum.filter(
               messages_after_repair,
               &get_in(&1, ["metadata", "task_schedule", "scheduled_for"])
             )
           ) == 1

    missing_window = due + :timer.hours(1)
    assert {:error, :not_found} = Schedules.recover_claim(schedule["id"], missing_window)
    assert {:ok, %{"last_run" => ^future_anchor}} = Schedules.get(schedule["id"])
  end

  test "legacy exact claim recovery cannot move a concurrently advanced anchor backward", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    due = Schedules.next_fire_ms(schedule)
    future_anchor = due + :timer.hours(1)

    assert :claimed = Schedules.claim_window(schedule["id"], due, %{"fired_at" => due})
    assert {:ok, owner} = SalixIM.ConversationFleet.ensure_started(group_id, conversation_id)
    :ok = :sys.suspend(owner, :infinity)

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(owner), do: :sys.resume(owner, :infinity)
    end)

    recovery =
      SystemsRuntime.Task.async(fn ->
        Schedules.recover_claim(schedule["id"], due, now: due + :timer.minutes(11))
      end)

    SystemsClock.sleep(100)
    assert {:status, :waiting} = Process.info(recovery.pid, :status)

    assert {:ok, %{"last_run" => ^future_anchor}} =
             Schedules.update(schedule["id"], %{"last_run" => future_anchor})

    :ok = :sys.resume(owner, :infinity)
    assert {:ok, :already_fired} = settled_await(recovery)

    assert {:ok, %{"last_run" => ^future_anchor}} = Schedules.get(schedule["id"])
  end

  test "concurrent sweepers append one scheduled command", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    due = Schedules.next_fire_ms(schedule)

    results =
      1..2
      |> Task.async_stream(fn _ -> Schedules.run_once(now: due) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{failed: []}}, &1))

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(
             Enum.filter(messages, &get_in(&1, ["metadata", "task_schedule", "scheduled_for"]))
           ) == 1
  end

  test "terminal Task fences a due notification", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    due = Schedules.next_fire_ms(schedule)

    assert {:ok, _cancelled} =
             TaskSchedules.update_conversation(group_id, conversation_id, %{
               "status" => "cancelled"
             })

    assert {:ok, %{inactive: [schedule_id], failed: []}} = Schedules.run_once(now: due)
    assert schedule_id == schedule["id"]

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages) == 1
  end

  test "a Task that is not active keeps its Schedule and fires again once active", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    schedule_id = schedule["id"]
    due = Schedules.next_fire_ms(schedule)

    assert {:ok, _escalated} =
             TaskSchedules.update_conversation(group_id, conversation_id, %{
               "status" => "escalated"
             })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{paused: [^schedule_id], fired: [], inactive: [], failed: []}} =
                 Schedules.run_once(now: due)
      end)

    assert log =~ "Task Schedule window skipped: Task is escalated"
    refute log =~ "Task Schedule deleted"

    assert {:ok, paused} = Schedules.get(schedule_id)
    assert paused["last_run"] == due

    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["schedule"]["schedule_id"] == schedule_id

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages) == 1

    # A failed run is not an end either: the Router sets `failed` and later
    # `active` again.
    assert {:ok, _failed} =
             TaskSchedules.update_conversation(group_id, conversation_id, %{
               "status" => "failed"
             })

    failed_due = Schedules.next_fire_ms(paused)
    assert failed_due > due
    assert {:ok, %{paused: [^schedule_id], failed: []}} = Schedules.run_once(now: failed_due)
    assert {:ok, paused} = Schedules.get(schedule_id)

    assert {:ok, _active} =
             TaskSchedules.update_conversation(group_id, conversation_id, %{
               "status" => "active"
             })

    next_due = Schedules.next_fire_ms(paused)
    assert next_due > failed_due
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: next_due)

    assert {:ok, [_dry_run, scheduled]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert message_text(scheduled) == "Run this complete command on every window."
  end

  test "an ended Task is unbound, its Schedule is deleted, and the deletion is logged", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    schedule_id = schedule["id"]
    due = Schedules.next_fire_ms(schedule)

    assert {:ok, _cancelled} =
             TaskSchedules.update_conversation(group_id, conversation_id, %{
               "status" => "cancelled"
             })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{inactive: [^schedule_id], failed: []}} = Schedules.run_once(now: due)
      end)

    assert log =~ "Task Schedule deleted: inactive"
    assert log =~ "schedule=#{schedule_id} unbound=true"
    assert {:error, :not_found} = Schedules.get(schedule_id)

    # The record does not keep a schedule_id without a definition.
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["schedule"]["schedule_id"] == nil
    assert task["status"] == "cancelled"
  end

  test "a Task whose Schedule definition is gone gets it rebuilt under the same id", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    schedule_id = schedule["id"]

    # The definition is lost while the Task still points at it.
    assert :ok = Schedules.delete(schedule_id)
    assert {:error, :not_found} = Schedules.get(schedule_id)
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["schedule"]["schedule_id"] == schedule_id

    assert {:ok, %{"schedule" => %{"schedule_id" => ^schedule_id}}} =
             TaskSchedules.update_task_schedule(group_id, conversation_id, %{
               "interval_minutes" => 5
             })

    assert {:ok, rebuilt} = Schedules.get(schedule_id)
    assert rebuilt["interval_minutes"] == 5
    assert rebuilt["payload"]["conversation_id"] == conversation_id

    due = Schedules.next_fire_ms(rebuilt)
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages) == 2
  end

  test "Task receiver rejects a Schedule rebound to another Task", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)

    assert {:ok, %{"conversation_id" => other_id}} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{"content" => "Do not run the first Task's Schedule."}
             )

    assert {:ok, :inactive} =
             TaskSchedules.receive(
               %{"agent_group_id" => group_id, "conversation_id" => other_id},
               :claimed,
               schedule_id: schedule["id"],
               scheduled_for: Schedules.next_fire_ms(schedule)
             )

    assert {:ok, original} = Conversations.get_group_conversation(group_id, conversation_id)
    assert original["schedule"]["schedule_id"] == schedule["id"]

    assert {:ok, other_messages} =
             Conversations.list_group_conversation_messages(group_id, other_id, limit: 10)

    assert length(other_messages) == 1
  end

  defp create_scheduled_task(group_id, router, worker) do
    assert {:ok, created} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{
                 "content" => "Run this complete command on every window.",
                 "schedule" => %{"interval_minutes" => 5}
               }
             )

    conversation_id = created["conversation_id"]

    assert {:ok, schedule} = Schedules.get(created["schedule"]["schedule_id"])
    {conversation_id, schedule}
  end

  defp create_task(router_id, params, tool_context \\ %{}) do
    assert {:ok, result} = call_task_create(router_id, params, tool_context)
    result
  end

  defp call_task_create(router_id, params, tool_context) do
    args = %{
      "connect_id" => "internal",
      "params" => Map.put_new(params, "runs_on", %{"kind" => "default"}),
      "tool_context" => tool_context
    }

    args =
      case tool_context[:tool_call_id] || tool_context["tool_call_id"] do
        tool_call_id when is_binary(tool_call_id) and tool_call_id != "" ->
          Map.put(args, "tool_call_id", tool_call_id)

        _missing ->
          args
      end

    Provider.call_api(router_id, "internal", "internal.task.create", args)
  end

  defp update_task(router_id, params) do
    assert {:ok, result} =
             Provider.call_api(router_id, "internal", "internal.task.update", %{
               "connect_id" => "internal",
               "params" => params
             })

    result
  end

  defp put_task_schedule(group_id, conversation_id, schedule) do
    TaskSchedules.update_task_schedule(group_id, conversation_id, schedule)
  end

  defp delete_task_schedule(group_id, conversation_id) do
    TaskSchedules.update_task_schedule(group_id, conversation_id, nil)
  end

  defp message_text(%{"content" => content}) when is_binary(content), do: content

  defp message_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp assert_initial_dry_run_envelope(content, command) do
    assert is_binary(content)

    assert Jason.decode!(content) == %{
             "format" => "scheduled_task_initial/v1",
             "mode" => "read_only_validation",
             "production_command" => command,
             "execute_production_command" => false,
             "external_side_effects" => false,
             "forbidden_operations" => [
               "issue_create_or_update",
               "repository_write",
               "team_message_send",
               "deployment",
               "permission_change",
               "destructive_operation"
             ],
             "allowed_operations" => ["read_only_discovery", "read_only_validation"],
             "required_report" => [
               "planned_checks",
               "completed_validation",
               "results",
               "blockers"
             ],
             "claim_production_completed" => false
           }

    assert String.contains?(content, ~s("production_command":#{Jason.encode!(command)}))

    assert :binary.match(content, ~s("production_command")) <
             :binary.match(content, ~s("execute_production_command"))

    content
  end

  defp eventually_value(fun, attempts \\ 3000)

  defp eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        SystemsClock.sleep(10)
        eventually_value(fun, attempts - 1)
    end
  end

  defp eventually_value(_fun, 0), do: flunk("condition did not become true")

  defp page_changes({:ok, %{"changes" => changes}}), do: {:ok, changes}
  defp page_changes(other), do: other

  defp connect_station!(tenant_id, group_id),
    do: tenant_id |> connect_station_run!(group_id) |> elem(0)

  defp connect_station_run!(tenant_id, group_id) do
    device_id = "device-station-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      SalixEnv.Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Laptop"
        },
        transport_id: transport_id
      )

    {:ok, _} =
      SalixEnv.Registry.update_meta(
        record["connector_run_id"],
        &Map.put(&1, "capabilities", %{
          "tasks" => 2,
          "task_models" => %{"codex" => ["gpt-5.5", "gpt-5.4-mini"]}
        })
      )

    {device_id, record["connector_run_id"]}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
