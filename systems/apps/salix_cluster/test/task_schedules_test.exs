defmodule SalixCluster.TaskSchedulesTest do
  use ExUnit.Case, async: false

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

  @scheduled_failure_summary "This scheduled run could not be completed because a required integration was unavailable. The result was recorded only in this Task; the Router must handle any requested external reporting."

  defmodule NoopAgentDelivery do
    @behaviour SalixIM.Ports.AgentDelivery

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      if pid = Application.get_env(:salix_cluster, :task_schedule_test_pid) do
        send(pid, {:agent_delivery, agent_id, payload, opts})
      end

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_found}
  end

  defmodule TaskCreateReceipt do
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(%{boundary: :tool_result, payload: %{"async" => true, "results" => results}}) do
      for result <- results,
          (result[:id] || result["id"]) == "create-reporting-schedule" do
        send(
          Application.fetch_env!(:salix_cluster, :task_schedule_test_pid),
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

      if task_created?(messages) do
        {:final, "Scheduled Task created."}
      else
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
                 "connect_id" => "internal",
                 "agent_id" => worker_id,
                 "content" => command,
                 "schedule" => %{"interval_minutes" => 5}
               }
             }
           }
         ]}
      end
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

    defp task_created?(messages) do
      Enum.any?(messages, fn message ->
        role = message[:role] || message["role"]
        tool_name = message[:tool_name] || message["tool_name"]
        role == "tool" and tool_name == "im_api.internal.task.create"
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
      s3: Application.get_env(:salix_store, :s3_backend),
      task_change_feed: Application.get_env(:salix_calendar, :task_change_feed_mod),
      task_create: Application.get_env(:salix_im, :task_create_mod),
      task_schedule: Application.get_env(:salix_im, :task_schedule_mod),
      delivery: Application.get_env(:salix_im, :agent_delivery_mod),
      transfer_port: Application.get_env(:salix_env, :transfer_port),
      test_pid: Application.get_env(:salix_cluster, :task_schedule_test_pid),
      diagnostic_sink: Application.get_env(:salix_cluster, :schedule_diagnostic_sink)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_calendar, :task_change_feed_mod, TaskCalendarChanges)

    Application.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    Application.put_env(:salix_im, :task_schedule_mod, Salix.Bindings.AgentConversations)

    Application.put_env(:salix_im, :agent_delivery_mod, NoopAgentDelivery)
    Application.put_env(:salix_env, :transfer_port, 0)
    Application.put_env(:salix_cluster, :task_schedule_test_pid, self())
    Application.delete_env(:salix_cluster, :schedule_diagnostic_sink)
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

    assert_receive {:agent_delivery, ^worker_id, _payload,
                    [{:source_message_id, ^scheduled_source} | _]},
                   1_000

    refute_receive {:agent_delivery, ^router_id, _payload,
                    [{:source_message_id, ^router_source} | _]},
                   100

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

    assert_receive {:agent_delivery, ^router_id, _payload,
                    [{:source_message_id, ^report_source} | _]},
                   1_000
  end

  test "recurring Task Messages do not change lifecycle before its next delivery", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    worker_id = worker["agent_id"]
    router_id = router["agent_id"]

    assert_receive {:agent_delivery, ^worker_id, _initial_payload, _initial_opts}, 1_000

    params = %{
      "conversation_id" => conversation_id,
      "content" => "The current run is complete.",
      "request_id" => "recurring-worker-completion",
      "task_completion" => %{"outcome" => "succeeded"}
    }

    assert {:error,
            "im_api.internal.send_message accepts only conversation_id, content, request_id, delivery_filter, mentions, reply_to_message_id"} =
             Provider.call_api(worker_id, "internal", "internal.send_message", %{
               "connect_id" => "internal",
               "params" => params
             })

    assert {:ok, before_retry} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert before_retry["status"] == "active"
    refute Map.has_key?(before_retry, "task_completion")
    assert before_retry["message_count"] == 1

    assert {:ok, %{"inserted" => true}} =
             Provider.call_api(worker_id, "internal", "internal.send_message", %{
               "connect_id" => "internal",
               "params" => Map.delete(params, "task_completion")
             })

    assert {:ok, after_message} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert after_message["status"] == "active"
    refute Map.has_key?(after_message, "task_completion")

    assert {:error, "operation is not authorized for this agent role"} =
             Provider.call_api(worker_id, "internal", "internal.update_conversation", %{
               "connect_id" => "internal",
               "params" => %{
                 "conversation_id" => conversation_id,
                 "status" => "ready_for_review"
               }
             })

    assert {:ok, %{"status" => "ready_for_review", "updated_at" => review_version}} =
             Provider.call_api(router_id, "internal", "internal.update_conversation", %{
               "connect_id" => "internal",
               "params" => %{
                 "conversation_id" => conversation_id,
                 "status" => "ready_for_review"
               }
             })

    assert {:error, {:conflict, "Recurring Task runs cannot complete the Task"}} =
             SalixIM.ConversationServer.accept_task_review(
               group_id,
               conversation_id,
               review_version
             )

    assert {:ok, %{"status" => "active"}} =
             Provider.call_api(router_id, "internal", "internal.update_conversation", %{
               "connect_id" => "internal",
               "params" => %{"conversation_id" => conversation_id, "status" => "active"}
             })

    due = Schedules.next_fire_ms(schedule)
    schedule_id = schedule["id"]

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

    assert {:ok, after_fire} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert after_fire["status"] == "active"
    assert after_fire["message_count"] == 3

    assert_receive {:agent_delivery, ^worker_id, scheduled_payload, _scheduled_opts}, 1_000
    assert scheduled_payload.content == "Run this complete command on every window."
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

    assert_receive {:agent_delivery, ^first_worker_id, _initial_payload, _initial_opts}, 1_000

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
        assert_receive {:agent_delivery, agent_id, _scheduled_payload, scheduled_opts}, 1_000
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

  test "scheduled Task persists a language-neutral safety envelope for old and new readers",
       %{
         group_id: group_id,
         router: router,
         worker: worker
       } do
    command = "检查仓库健康并报告所有发现。"

    created =
      create_task(router["agent_id"], %{
        "agent_id" => worker["agent_id"],
        "content" => command,
        "schedule" => %{"interval_minutes" => 5}
      })

    schedule_id = created["schedule"]["schedule_id"]
    worker_id = worker["agent_id"]

    assert_receive {:agent_delivery, ^worker_id, initial_payload,
                    [{:source_message_id, _initial_source} | _]},
                   1_000

    assert_initial_dry_run_envelope(initial_payload.content, command)
    assert [source_context] = initial_payload.pre_deliveries
    assert source_context.role == "summary"
    assert source_context.content =~ "initial read-only Task Schedule dry run"
    assert source_context.content =~ "structured safety envelope and the exact production command"
    assert source_context.content =~ "do not perform the production task"
    assert source_context.content =~ "Perform only safe, read-only discovery and validation"
    assert source_context.content =~ "Do not claim that the production command has completed"

    assert initial_payload.trusted_origin["task_schedule"] == %{
             "dry_run" => true,
             "schedule_id" => schedule_id
           }

    assert {:ok, [task_command]} =
             Conversations.list_group_conversation_messages(
               group_id,
               created["conversation_id"],
               limit: 10
             )

    assert task_command["actor_type"] == "agent"
    assert task_command["agent_id"] == router["agent_id"]
    assert_initial_dry_run_envelope(message_text(task_command), command)
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

    assert_receive {:agent_delivery, ^worker_id, _initial_payload,
                    [{:source_message_id, _initial_source} | _]},
                   1_000

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

    assert_receive {:agent_delivery, ^worker_id, legacy_payload,
                    [{:source_message_id, _legacy_source} | _]},
                   1_000

    assert legacy_payload.content == String.trim(legacy_content)
    assert [source_context] = legacy_payload.pre_deliveries
    assert source_context.content =~ "initial read-only Task Schedule dry run"
    assert source_context.content =~ "do not perform the production task"

    assert legacy_payload.trusted_origin["task_schedule"] == %{
             "dry_run" => true,
             "schedule_id" => schedule_id
           }
  end

  test "scheduled Task keeps Feishu delivery Router-owned while the worker prepares content", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    command =
      "Prepare the final meeting reminder and return it to the Router for Feishu delivery. Do not call external IM tools."

    created =
      create_task(router["agent_id"], %{
        "agent_id" => worker["agent_id"],
        "content" => command,
        "schedule" => %{"interval_minutes" => 5}
      })

    worker_id = worker["agent_id"]

    assert_receive {:agent_delivery, ^worker_id, initial_payload,
                    [{:source_message_id, _initial_source} | _]},
                   1_000

    assert_initial_dry_run_envelope(initial_payload.content, command)
    assert [source_context] = initial_payload.pre_deliveries
    assert source_context.role == "summary"
    assert source_context.content =~ "initial read-only Task Schedule dry run"
    assert source_context.content =~ "structured safety envelope and the exact production command"
    assert source_context.content =~ "do not perform the production task"
    assert source_context.content =~ "Perform only safe, read-only discovery and validation"
    assert source_context.content =~ "Do not claim that the production command has completed"

    assert initial_payload.trusted_origin["task_schedule"] == %{
             "dry_run" => true,
             "schedule_id" => created["schedule"]["schedule_id"]
           }

    assert {:ok, [context_message]} =
             Conversations.list_group_conversation_messages(
               group_id,
               created["conversation_id"],
               limit: 10
             )

    assert_initial_dry_run_envelope(message_text(context_message), command)
    assert context_message["actor_type"] == "agent"
    assert context_message["agent_id"] == router["agent_id"]

    assert {:ok, schedule} = Schedules.get(created["schedule"]["schedule_id"])
    due = Schedules.next_fire_ms(schedule)
    assert {:ok, %{fired: [schedule_id], failed: []}} = Schedules.run_once(now: due)
    assert schedule_id == schedule["id"]

    assert_receive {:agent_delivery, ^worker_id, scheduled_payload,
                    [{:source_message_id, _scheduled_source} | _]},
                   1_000

    assert scheduled_payload.content == command
    assert scheduled_payload.content =~ "return it to the Router"
    refute scheduled_payload.content =~ "im_api.feishu"
  end

  @tag :meeting_context_schedule
  test "Slack scheduled Task creation ignores leading meeting context through the Router tool path",
       %{group_id: group_id, router: router, worker: worker} do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, ReportDestinationRouterLLM)
    on_exit(fn -> restore(:salix_agent, :llm, previous_llm) end)

    previous_archive = Application.get_env(:salix_agent, :event_archive_mod)
    Application.put_env(:salix_agent, :event_archive_mod, TaskCreateReceipt)
    on_exit(fn -> restore(:salix_agent, :event_archive_mod, previous_archive) end)

    router_id = router["agent_id"]
    session_id = Ids.new_session_id()
    meeting_source = "meeting-activation:previous-meeting:completed"
    slack_source = "im_provider:slack:monitor-request"

    # A context-only meeting is not authority for this later human request.
    # Its grant may already be unavailable; Task creation must not consult it.
    assert {:ok, :created} =
             SalixAgent.deliver(
               router_id,
               %{
                 session_id: session_id,
                 content: "An unrelated meeting completed.",
                 trusted_origin: %{
                   "provider" => "feishu",
                   "source_actor_type" => "provider_system",
                   "source_message_id" => meeting_source,
                   "agent_group_id" => group_id,
                   "provider_context" => %{"event_type" => "meeting.completed"}
                 }
               },
               source_message_id: meeting_source,
               no_wake: true
             )

    assert {:ok, :created} =
             SalixAgent.deliver(
               router_id,
               %{
                 session_id: session_id,
                 content:
                   "Create a Task Schedule with worker_id=#{worker["agent_id"]}. " <>
                     "Check the host every five minutes.",
                 trusted_origin: %{
                   "provider" => "slack",
                   "source_actor_type" => "provider_user",
                   "source_message_id" => slack_source,
                   "agent_group_id" => group_id,
                   "provider_context" => %{
                     "connect_id" => "slack-monitor",
                     "channel_id" => "C-monitor",
                     "thread_ts" => "1788749531.253089"
                   }
                 }
               },
               source_message_id: slack_source
             )

    assert_receive {:scheduled_task_receipt, receipt}, 10_000

    assert (receipt[:error] || receipt["error"]) != true,
           "Task creation failed: #{inspect(receipt[:content] || receipt["content"])}"

    task =
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

    schedule_id = get_in(task, ["schedule", "schedule_id"])
    assert is_binary(schedule_id) and schedule_id != ""
    assert {:ok, schedule} = Schedules.get(schedule_id)
    assert schedule["interval_minutes"] == 5
    assert schedule["payload"]["conversation_id"] == task["conversation_id"]
    refute Map.has_key?(task["source_refs"], "meeting_activation_refs")
  end

  test "Router preserves a scheduled Task report destination for Worker reminder and Task-only reporting",
       %{
         group_id: group_id,
         router: router,
         worker: worker
       } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, ReportDestinationRouterLLM)
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

    assert_receive {:agent_delivery, ^worker_id, initial_payload,
                    [{:source_message_id, _initial_source} | _]},
                   1_000

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

    assert_receive {:agent_delivery, ^worker_id, scheduled_payload,
                    [{:source_message_id, _scheduled_source} | _]},
                   1_000

    assert scheduled_payload.content == command
    refute_receive {:agent_delivery, ^router_id, ^scheduled_payload, _opts}, 100

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

    assert_receive {:agent_delivery, ^router_id, report_payload,
                    [{:source_message_id, ^report_source} | _]},
                   1_000

    assert report_payload.content == worker_report
    assert report_payload.content =~ destination
  end

  test "a scheduled Task records one bounded failure when an external dependency is unavailable",
       %{group_id: group_id, router: router, worker: worker} do
    worker_id = worker["agent_id"]

    start_supervised!(ScheduledFailureLLM)

    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    previous_im_provider = Application.get_env(:salix_agent, :im_provider_mod)

    Application.put_env(:salix_agent, :llm, ScheduledFailureLLM)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)

    on_exit(fn ->
      restore(:salix_agent, :llm, previous_llm)
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
      restore(:salix_agent, :im_provider_mod, previous_im_provider)
    end)

    for retry_failure? <- [true, false] do
      Application.put_env(:salix_im, :agent_delivery_mod, previous_delivery)
      {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)

      assert_receive {:agent_delivery, ^worker_id, initial_payload, _initial_opts}, 1_000
      session_id = initial_payload.session_id

      ScheduledFailureLLM.configure(conversation_id, retry_failure?: retry_failure?)
      Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)

      due = Schedules.next_fire_ms(schedule)
      schedule_id = schedule["id"]
      assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

      failed =
        eventually_value(fn ->
          with {:ok, messages} <-
                 Conversations.list_group_conversation_messages(
                   group_id,
                   conversation_id,
                   limit: 20
                 ),
               %{} = message <- Enum.find(messages, &scheduled_failure_message?/1) do
            {:ok, message}
          else
            _ -> :retry
          end
        end)

      assert message_text(failed) == @scheduled_failure_summary

      refute message_text(failed) =~ "provider is not visible"
      assert failed["agent_id"] == worker_id

      assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
      assert task["status"] == "active"
      refute Map.has_key?(task, "task_completion")

      assert :ok = SalixAgent.TestSupport.await_session_quiet(worker_id, session_id)

      assert {:ok, settled_messages} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 conversation_id,
                 limit: 20
               )

      assert [^failed] =
               Enum.filter(settled_messages, &scheduled_failure_message?/1)
    end
  end

  test "each overdue scheduled window records one bounded failure when a later Task message shares the activation",
       %{group_id: group_id, router: router, worker: worker} do
    worker_id = worker["agent_id"]

    start_supervised!(ScheduledFailureLLM)

    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    previous_im_provider = Application.get_env(:salix_agent, :im_provider_mod)

    Application.put_env(:salix_agent, :llm, ScheduledFailureLLM)
    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)

    on_exit(fn ->
      restore(:salix_agent, :llm, previous_llm)
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
      restore(:salix_agent, :im_provider_mod, previous_im_provider)
    end)

    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)

    assert_receive {:agent_delivery, ^worker_id, initial_payload, _initial_opts}, 1_000
    session_id = initial_payload.session_id

    due = Schedules.next_fire_ms(schedule)
    schedule_id = schedule["id"]
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)

    assert_receive {:agent_delivery, ^worker_id, first_window_payload, first_window_opts}, 1_000

    second_due = due + :timer.minutes(5)
    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: second_due)

    assert_receive {:agent_delivery, ^worker_id, second_window_payload, second_window_opts},
                   1_000

    assert get_in(first_window_payload, [:trusted_origin, "task_schedule"]) == %{
             "schedule_id" => schedule_id,
             "scheduled_for" => due
           }

    assert get_in(second_window_payload, [:trusted_origin, "task_schedule"]) == %{
             "schedule_id" => schedule_id,
             "scheduled_for" => second_due
           }

    assert {:ok, _message} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               router["agent_id"],
               %{
                 "content" => "Also include the current branch name.",
                 "client_request_id" => "scheduled-failure-batched-follow-up"
               }
             )

    assert_receive {:agent_delivery, ^worker_id, follow_up_payload, follow_up_opts}, 1_000
    refute get_in(follow_up_payload, [:trusted_origin, "task_schedule"])

    ScheduledFailureLLM.configure(conversation_id, retry_failure?: true)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)

    for {payload, opts} <- [
          {first_window_payload, first_window_opts},
          {second_window_payload, second_window_opts}
        ] do
      # Replay the captured delivery through the public rpc ingress (the
      # staged engine retired in A2 §3.4); no_wake keeps round scheduling in
      # this test's own hands, as the staged replay did.
      assert {:ok, :created} =
               SalixAgent.deliver(worker_id, payload, Keyword.put(opts, :no_wake, true))
    end

    assert {:ok, :created} = SalixAgent.deliver(worker_id, follow_up_payload, follow_up_opts)

    llm_calls =
      eventually_value(fn ->
        case ScheduledFailureLLM.calls(conversation_id) do
          calls when calls > 0 -> {:ok, calls}
          _ -> :retry
        end
      end)

    assert llm_calls > 0

    failures =
      eventually_value(fn ->
        with {:ok, messages} <-
               Conversations.list_group_conversation_messages(
                 group_id,
                 conversation_id,
                 limit: 20
               ),
             failures =
               Enum.filter(messages, &scheduled_failure_message?/1),
             true <- length(failures) == 2 do
          {:ok, failures}
        else
          _ -> :retry
        end
      end)

    assert Enum.all?(failures, &scheduled_failure_message?/1)

    assert failures |> Enum.map(& &1["request_identity"]) |> MapSet.new() |> MapSet.size() == 2

    assert :ok = SalixAgent.TestSupport.await_session_quiet(worker_id, session_id)

    expected_call_ids =
      MapSet.new([
        "scheduled-task-safe-failure:#{schedule_id}:#{due}",
        "scheduled-task-safe-failure:#{schedule_id}:#{second_due}"
      ])

    assert {:ok, internal_session} =
             SalixAgent.InternalSessionStore.read(worker_id, session_id)

    assert SalixAgent.VisibleReplyPolicy.phase(internal_session) == :clean

    session_messages = SalixAgent.InternalSession.get(internal_session, :messages)

    assert Enum.any?(session_messages, fn
             %{role: "assistant", tool_calls: calls} ->
               calls |> Enum.map(&(&1["id"] || &1[:id])) |> MapSet.new() == expected_call_ids

             _ ->
               false
           end)

    assert session_messages
           |> Enum.filter(
             &(&1[:role] == "tool" and
                 String.starts_with?(
                   &1[:tool_call_id] || "",
                   "scheduled-task-safe-failure:"
                 ))
           )
           |> Enum.map(& &1[:tool_call_id])
           |> MapSet.new() == expected_call_ids

    assert {:ok, settled_messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )

    assert 2 ==
             Enum.count(settled_messages, &scheduled_failure_message?/1)
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

  test "one-shot Task converts in place, updates the same Schedule, and deletes it", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, created} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{"content" => "Keep this Task and its history."}
             )

    conversation_id = created["conversation_id"]

    assert %{"schedule_id" => nil, "command" => command} = created["schedule"]

    assert {:ok, scheduled} =
             put_task_schedule(group_id, conversation_id, %{"interval_minutes" => 5})

    assert %{"schedule_id" => schedule_id, "command" => ^command} = scheduled["schedule"]
    assert {:ok, first_definition} = Schedules.get(schedule_id)

    assert {:ok, updated} =
             put_task_schedule(group_id, conversation_id, %{
               "interval_minutes" => 10,
               "receiver" => "agent",
               "payload" => %{"conversation_id" => "other"}
             })

    assert updated["conversation_id"] == conversation_id
    assert updated["schedule"] == scheduled["schedule"]
    assert {:ok, second_definition} = Schedules.get(schedule_id)
    assert second_definition["interval_minutes"] == 10
    assert second_definition["receiver"] == "task"
    assert second_definition["payload"] == first_definition["payload"]

    assert {:ok, unscheduled} = delete_task_schedule(group_id, conversation_id)
    assert unscheduled["schedule"] == %{"schedule_id" => nil, "command" => command}
    assert {:error, :not_found} = Schedules.get(schedule_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert [%{"metadata" => metadata} = message] = messages
    assert message_text(message) == command
    refute get_in(metadata, ["task_schedule", "dry_run"])

    assert {:ok, :inactive} =
             TaskSchedules.receive(first_definition["payload"], :claimed,
               schedule_id: schedule_id,
               scheduled_for: Schedules.next_fire_ms(first_definition)
             )
  end

  test "a Schedule added to a trusted-ingress Task fires without a delegator participant", %{
    group_id: group_id,
    worker: worker
  } do
    conversation_id = Ids.new_conversation_id()
    created_at = System.system_time(:millisecond)
    command = "Continue the trusted-ingress task in its canonical conversation."

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               worker["agent_id"],
               %{
                 "title" => "Trusted ingress task",
                 "command" => command,
                 "created_at" => created_at
               }
             )

    assert {:ok, scheduled} =
             TaskSchedules.update_task_schedule(
               group_id,
               conversation_id,
               %{"interval_minutes" => 5}
             )

    schedule_id = scheduled["schedule"]["schedule_id"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    due = Schedules.next_fire_ms(schedule)

    assert {:ok, %{fired: [^schedule_id], failed: []}} =
             Schedules.run_once(now: due)

    assert {:ok, [scheduled_message]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert message_text(scheduled_message) == command
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

  test "a delayed repair snapshot cannot roll a newer Task state back in Calendar", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, calendar} =
             Server.create_calendar(group_id, %{
               "name" => "Agent work",
               "default_time_zone" => "UTC"
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
                 "title" => "Initial title",
                 "content" => "Keep the public Calendar projection current.",
                 "schedule" => %{"interval_minutes" => 30}
               }
             )

    assert {:ok, stale_snapshot} =
             ConversationServer.update_group_conversation(
               group_id,
               created["conversation_id"],
               %{"title" => "Older deferred title"}
             )

    assert {:ok, current} =
             TaskSchedules.update_conversation(
               group_id,
               created["conversation_id"],
               %{"title" => "Current title"}
             )

    assert current["updated_at"] > stale_snapshot["updated_at"]

    assert {:ok, stale_definition} =
             TaskSchedules.calendar_projection(
               group_id,
               created["conversation_id"],
               stale_snapshot["schedule"]
             )

    # A repair page may have loaded the older snapshot before the current update
    # committed, then record that snapshot after the current change-feed write.
    assert {:ok, _late_stale_change} =
             TaskCalendarChanges.record(stale_snapshot, stale_definition)

    assert {:ok, synced} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               %{"group_id" => group_id, "object_type" => "Task", "page_size" => 100}
             )

    assert List.last(synced["applied"])["object"]["title"] == "Current title"
  end

  test "a pre-upgrade scheduled Task without assigned_agent_id still fires", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)

    assert {:ok, _legacy_conversation} =
             SalixStore.CasRecord.update(
               Keys.ctl_group_conversation(group_id, conversation_id),
               &Map.delete(&1, "assigned_agent_id")
             )

    due = Schedules.next_fire_ms(schedule)
    schedule_id = schedule["id"]

    assert {:ok, %{fired: [^schedule_id], failed: []}} = Schedules.run_once(now: due)
  end

  test "Task change recording is state-idempotent and bounded repair restores a missing event", %{
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
                 "content" => "Repair the public task projection.",
                 "schedule" => %{"interval_minutes" => 30}
               }
             )

    assert {:ok, conversation} =
             Conversations.get_group_conversation(group_id, created["conversation_id"])

    assert {:ok, definition} =
             TaskSchedules.calendar_projection(
               group_id,
               created["conversation_id"],
               conversation["schedule"]
             )

    assert {:ok, first} = TaskCalendarChanges.record(conversation, definition)
    assert {:ok, same} = TaskCalendarChanges.record(conversation, definition)
    assert same["change_id"] == first["change_id"]

    assert :ok = S3.delete(Keys.ctl_task_calendar_change(group_id, first["change_id"]))
    assert {:ok, repaired_page} = TaskSchedules.page(group_id, limit: 100)

    assert repaired =
             Enum.find(repaired_page["changes"], fn change ->
               change["conversation_id"] == created["conversation_id"]
             end)

    assert repaired["change_id"] != first["change_id"]
  end

  test "a committed Task update does not fail when its rebuildable Calendar projection is deferred",
       %{
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
                 "content" => "Keep Task facts authoritative.",
                 "schedule" => %{"interval_minutes" => 30}
               }
             )

    assert {:ok, %{"title" => "Updated while projection is unavailable"}} =
             ConversationServer.update_group_conversation(
               group_id,
               created["conversation_id"],
               %{"title" => "Updated while projection is unavailable"}
             )

    assert {:ok, page} = TaskSchedules.page(group_id, limit: 100)

    assert Enum.any?(page["changes"], fn change ->
             change["conversation_id"] == created["conversation_id"] and
               change["title"] == "Updated while projection is unavailable"
           end)
  end

  test "deleting a scheduled Task publishes a tombstone before physical removal", %{
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
                 "content" => "Delete this scheduled task safely.",
                 "schedule" => %{"interval_minutes" => 30}
               }
             )

    assert {:ok, before_delete} = TaskCalendarChanges.page(group_id, limit: 100)
    cursor = before_delete["completed_cursor"]
    assert is_binary(cursor)

    assert :ok =
             TaskSchedules.delete_conversation(group_id, created["conversation_id"])

    assert {:error, :not_found} =
             Conversations.get_group_conversation(group_id, created["conversation_id"])

    assert {:ok, after_delete} =
             TaskCalendarChanges.page(group_id, start_after: cursor, limit: 100)

    assert [tombstone] = after_delete["changes"]
    assert tombstone["conversation_id"] == created["conversation_id"]
    assert tombstone["status"] == "terminal"
    assert {:ok, %{"tombstone" => true}} = SalixTaskSchedule.normalize(tombstone)
  end

  test "an empty Task change feed completes its initial Calendar generation", %{
    group_id: group_id
  } do
    assert {:ok, calendar} =
             Server.create_calendar(group_id, %{
               "name" => "Empty agent work",
               "default_time_zone" => "UTC"
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

    assert {:ok, result} =
             Server.refresh_source(
               group_id,
               calendar["calendar_id"],
               source["source_id"],
               %{"group_id" => group_id, "object_type" => "Task", "page_size" => 100}
             )

    assert result["applied"] == []
    assert result["sync"]["status"] == "active"
    assert is_binary(result["sync"]["completed_cursor"])
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
    parent = self()

    Application.put_env(:salix_cluster, :schedule_diagnostic_sink, fn diagnostic ->
      send(parent, {:schedule_diagnostic, diagnostic})
    end)

    assert {:error, {:bad_request, "task worker participant is missing"}} =
             Schedules.fire(schedule, due, now: due)

    assert_receive {:schedule_diagnostic, diagnostic}
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
    :ok = :sys.suspend(owner)

    on_exit(fn ->
      if Process.alive?(owner), do: :sys.resume(owner)
    end)

    recovery =
      Task.async(fn ->
        Schedules.recover_claim(schedule["id"], due, now: due + :timer.minutes(11))
      end)

    Process.sleep(100)
    assert {:status, :waiting} = Process.info(recovery.pid, :status)

    assert {:ok, %{"last_run" => ^future_anchor}} =
             Schedules.update(schedule["id"], %{"last_run" => future_anchor})

    :ok = :sys.resume(owner)
    assert {:ok, :already_fired} = Task.await(recovery, 5_000)

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

  test "non-active Task fences a due notification", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    {conversation_id, schedule} = create_scheduled_task(group_id, router, worker)
    due = Schedules.next_fire_ms(schedule)

    assert {:ok, _inactive} =
             TaskSchedules.update_conversation(group_id, conversation_id, %{
               "status" => "inactive"
             })

    assert {:ok, %{inactive: [schedule_id], failed: []}} = Schedules.run_once(now: due)
    assert schedule_id == schedule["id"]

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages) == 1
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

  test "cron requires a valid explicit timezone", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, %{"data" => before}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert {:error, :invalid_schedule} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{
                 "content" => "Run every morning.",
                 "schedule" => %{"cron" => "0 9 * * *", "timezone" => "Mars/Phobos"}
               }
             )

    assert {:ok, %{"data" => after_failed_create}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert MapSet.new(Enum.map(after_failed_create, & &1["conversation_id"])) ==
             MapSet.new(Enum.map(before, & &1["conversation_id"]))
  end

  test "a failed Schedule definition write cannot strand an unlocatable live Task", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, %{"data" => before}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    # Schedule definitions live in the control Postgres: take the table away
    # so the definition write fails while everything else stays healthy.
    SalixStore.Repo.query!("ALTER TABLE schedules RENAME TO schedules_tmp")

    result =
      try do
        TaskSchedules.create_task_conversation(
          group_id,
          router["agent_id"],
          worker["agent_id"],
          %{
            "content" => "Do not strand this Task after Schedule storage fails.",
            "schedule" => %{"interval_minutes" => 5}
          }
        )
      after
        SalixStore.Repo.query!("ALTER TABLE schedules_tmp RENAME TO schedules")
      end

    assert {:error, :unavailable} = result

    assert {:ok, %{"data" => after_failure}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert MapSet.new(Enum.map(after_failure, & &1["conversation_id"])) ==
             MapSet.new(Enum.map(before, & &1["conversation_id"]))
  end

  test "a failed first-message write leaves no Task, and a retry creates one delegated Task", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    attrs = %{
      "content" => "Summarize today's New York news.",
      "client_request_id" => "task-create-log-recovery-outage"
    }

    assert {:ok, %{"data" => before}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    # The first-message commit marks the log-recovery index in Postgres. Take
    # that table away, as a lost database sidecar does during a rollout.
    SalixStore.Repo.query!(
      "ALTER TABLE conversation_log_recovery RENAME TO conversation_log_recovery_tmp"
    )

    result =
      try do
        TaskSchedules.create_task_conversation(
          group_id,
          router["agent_id"],
          worker["agent_id"],
          attrs
        )
      after
        SalixStore.Repo.query!(
          "ALTER TABLE conversation_log_recovery_tmp RENAME TO conversation_log_recovery"
        )
      end

    assert {:error, _reason} = result

    assert {:ok, %{"data" => after_failure}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert MapSet.new(Enum.map(after_failure, & &1["conversation_id"])) ==
             MapSet.new(Enum.map(before, & &1["conversation_id"]))

    assert {:ok, %{"conversation_id" => conversation_id}} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               attrs
             )

    assert {:ok, %{"data" => after_retry}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert [conversation_id] ==
             Enum.map(after_retry, & &1["conversation_id"]) --
               Enum.map(before, & &1["conversation_id"])

    assert {:ok, [message]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert %{"seq" => 1, "content" => [%{"text" => "Summarize today's New York news."}]} =
             message
  end

  test "failed Schedule update does not add a synthetic conversation participant", %{
    group_id: group_id,
    router: router,
    worker: worker
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{"content" => "Keep this one-shot Task unchanged."}
             )

    assert {:ok, %{"participants" => before}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:error, :invalid_schedule} =
             TaskSchedules.update_task_schedule(
               group_id,
               conversation_id,
               %{
                 "command" => "This invalid Schedule must not mutate the Task.",
                 "cron" => "0 9 * * *",
                 "timezone" => "Mars/Phobos"
               }
             )

    assert {:ok, %{"participants" => after_failed_update}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert MapSet.new(Enum.map(after_failed_update, & &1["participant_id"])) ==
             MapSet.new(Enum.map(before, & &1["participant_id"]))
  end

  test "Schedule can only be attached to an agent_task", %{group_id: group_id} do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             ConversationServer.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Not a Task"
             })

    assert {:error, {:bad_request, "schedule is only supported on agent_task"}} =
             put_task_schedule(group_id, conversation_id, %{"interval_minutes" => 5})
  end

  test "Router cannot be selected as the Task command target", %{
    group_id: group_id,
    router: router
  } do
    assert {:error, {:bad_request, "router cannot be a Task command target"}} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               router["agent_id"],
               %{"content" => "This command must not return to Router."}
             )
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
      "params" => params,
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

  defp scheduled_failure_message?(message),
    do: message_text(message) == @scheduled_failure_summary

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

  defp eventually_value(fun, attempts \\ 200)

  defp eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)
    end
  end

  defp eventually_value(_fun, 0), do: flunk("condition did not become true")

  defp page_changes({:ok, %{"changes" => changes}}), do: {:ok, changes}
  defp page_changes(other), do: other

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
