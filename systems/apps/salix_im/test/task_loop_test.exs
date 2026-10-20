defmodule SalixIM.TaskLoopTest do
  @moduledoc """
  A Loop Task's Task-side rules (`SalixIM.TaskLoop`), through the Task's
  Conversation owner with the Loop runtime replaced by
  `SalixIM.TestSupport.TaskLoops`: the request written as the Task's Loop,
  the Worker's guidance, wakes, a Loop's end completing its Task, and the
  Task's end ending its Loop. No client takes part.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{ConversationServer, Conversations, TaskLoop}
  alias SalixIM.TestSupport.TaskLoops

  defmodule CaptureDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    @impl true
    def conversation_progress(_, _, participant),
      do: SalixStore.CasRecord.get("test/conversation-delivery/#{participant}")

    def deliver(agent_id, payload, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :test}),
        {:delivered, agent_id, payload}
      )

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_implemented}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_implemented}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, CaptureDelivery)
    SystemsRuntime.PersistentTerm.put({CaptureDelivery, :test}, SystemsRuntime.Proc.self())
    start_supervised!(SalixStore.S3.Fake)
    TaskLoops.install()

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SystemsRuntime.PersistentTerm.erase({CaptureDelivery, :test})
      restore(:salix_store, :s3_backend, previous_s3)
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Loop Tasks"})

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
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok, group_id: group_id, router: router["agent_id"], worker: worker["agent_id"]}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp create_task(ctx, request_id, loop) do
    content = "Check PR #12 for new review comments and summarize them."
    attrs = %{"content" => content, "client_request_id" => request_id}
    attrs = if loop, do: Map.put(attrs, "loop", loop), else: attrs

    {:ok, id} =
      ConversationServer.reserve_task_conversation_id(ctx.group_id, ctx.router, ctx.worker, attrs)

    {:ok, _created} =
      SalixIM.TaskConversationInput.create_with_id(
        ctx.group_id,
        id,
        ctx.router,
        ctx.worker,
        attrs
        |> Map.put("schedule", %{"schedule_id" => nil, "command" => content})
        |> Map.put("initial_message_attrs", %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => ctx.router,
          "content" => content,
          "metadata" => %{"message_type" => "task_command"},
          "client_request_id" => "delegate-" <> id
        })
      )

    id
  end

  defp task(ctx, id) do
    {:ok, task} = Conversations.get_group_conversation(ctx.group_id, id)
    task
  end

  defp ended(ctx, id, reason, limits) do
    ConversationServer.task_loop_ended(
      ctx.group_id,
      id,
      %{"loop_id" => "lop_" <> id},
      Map.merge(%{"ended_reason" => reason}, limits)
    )
  end

  defp worker_session(ctx, id) do
    case Conversations.list_group_conversation_participants(ctx.group_id, id) do
      {:ok, %{"participants" => participants}} ->
        case Enum.find(participants, &(&1["agent_id"] == ctx.worker)) do
          nil -> "missing"
          worker -> worker["payload"]["session_id"]
        end

      _ ->
        "missing"
    end
  end

  defp wake(ctx, id, source) do
    loop = %{"agent_id" => ctx.worker, "session_id" => worker_session(ctx, id)}

    ConversationServer.task_loop_wake(
      ctx.group_id,
      id,
      loop,
      %{content: "Run " <> source},
      source
    )
  end

  defp text(%{"content" => content}),
    do: Enum.map_join(List.wrap(content), &if(is_map(&1), do: &1["text"], else: &1))

  defp loop_notices(ctx, id) do
    {:ok, messages} = Conversations.list_group_conversation_messages(ctx.group_id, id, limit: 50)

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, id)

    router = Enum.find(participants, &(&1["agent_id"] == ctx.router))["participant_id"]

    notices =
      Enum.filter(messages, &(get_in(&1, ["metadata", "message_type"]) == "task_loop"))

    assert Enum.all?(notices, &(&1["delivery_filter"]["participant_ids"] == [router]))
    notices
  end

  test "a cron cadence without a timezone takes the requester's" do
    request = %{"cadence" => %{"cron" => "0 9 * * 1-5"}}

    assert {:ok, %{"cadence" => %{"cron" => "0 9 * * 1-5", "timezone" => "Asia/Shanghai"}}} =
             TaskLoop.request(request, now: 0, timezone: "Asia/Shanghai")

    assert {:error, "loop.cadence.timezone is required with cron" <> _} =
             TaskLoop.request(request, now: 0, timezone: nil)
  end

  test "an events cadence is a label of 1 to 32 characters, counted in graphemes" do
    request = &TaskLoop.request(%{"cadence" => %{"events" => &1}}, now: 0)

    # 32 Chinese characters are 96 bytes: the limit is the same for both.
    for label <- [String.duplicate("e", 32), String.duplicate("评", 32)] do
      assert {:ok, %{"cadence" => %{"events" => ^label}}} = request.(label)
    end

    for label <- [String.duplicate("e", 33), "  "] do
      assert {:error, "loop.cadence.events must be a label of 1 to 32 characters" <> _} =
               request.(label)
    end
  end

  test "a Loop Task writes its request as the Task's Loop, and the command tells the Worker how to run it",
       ctx do
    id =
      create_task(ctx, "loop-request", %{"cadence" => %{"every_minutes" => 60}, "max_runs" => 2})

    assert_received {:task_loops, :request, ^id}
    refute Map.has_key?(task(ctx, id), "loop")

    settle_receive({:delivered, worker, %{pre_deliveries: [context]}})
    assert worker == ctx.worker
    assert context.content =~ "This Task is a Loop Task"
    assert context.content =~ "every 60 minutes (at most 2 runs)"
    assert context.content =~ "passing no cadence"
    assert context.content =~ "loop.next_run"

    # A repeated create of the same Task leaves its Loop alone.
    assert create_task(ctx, "loop-request", %{
             "cadence" => %{"every_minutes" => 60},
             "max_runs" => 2
           }) == id

    refute_received {:task_loops, :request, ^id}
  end

  test "a wake reaches the Worker's Session in its Task once, and not after the Worker left",
       ctx do
    id = create_task(ctx, "loop-wake", %{"cadence" => %{"events" => "new comments on PR #12"}})
    assert {:ok, :created} = wake(ctx, id, "loop:lop:a")
    assert {:ok, :duplicate} = wake(ctx, id, "loop:lop:a")

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, id)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker))

    assert {:ok, _} =
             ConversationServer.deactivate_group_conversation_participant(
               ctx.group_id,
               id,
               worker["participant_id"]
             )

    assert {:error, :task_worker_missing} = wake(ctx, id, "loop:lop:b")
    assert task(ctx, id)["status"] == "active"
  end

  test "a Loop that ended at its run limit or end time completes its Task and tells the Router once",
       ctx do
    by_runs = create_task(ctx, "loop-max-runs", %{"cadence" => %{"every_minutes" => 60}})
    by_time = create_task(ctx, "loop-ends-at", %{"cadence" => %{"every_minutes" => 60}})

    assert {:ok, :ended} = ended(ctx, by_runs, "max_runs", %{"max_runs" => 2})
    assert {:ok, :ended} = ended(ctx, by_runs, "max_runs", %{"max_runs" => 2})
    assert task(ctx, by_runs)["status"] == "completed"
    assert [notice] = loop_notices(ctx, by_runs)
    assert text(notice) =~ "reached its run limit of 2 runs"
    assert notice["metadata"]["task_loop"] == %{"event" => "ended", "reason" => "max_runs"}

    assert {:ok, :ended} = ended(ctx, by_time, "ends_at", %{"ends_at" => 1_000})
    assert task(ctx, by_time)["status"] == "completed"
    assert [notice] = loop_notices(ctx, by_time)
    assert text(notice) =~ "reached its end time"

    # A Task that already ended keeps its status and hears nothing.
    cancelled = create_task(ctx, "loop-cancelled", %{"cadence" => %{"every_minutes" => 60}})

    assert {:ok, _} =
             ConversationServer.set_task_status(
               ctx.group_id,
               cancelled,
               "cancelled",
               task(ctx, cancelled)["updated_at"],
               "user-1"
             )

    assert {:ok, :ended} = ended(ctx, cancelled, "max_runs", %{"max_runs" => 1})
    assert task(ctx, cancelled)["status"] == "cancelled"
    assert [] = loop_notices(ctx, cancelled)
  end

  test "a Task that ends ends its Loop: the Router's end and a user's Done or Cancel", ctx do
    loop = %{"cadence" => %{"every_minutes" => 30}}
    by_router = create_task(ctx, "loop-router-end", loop)
    by_user = create_task(ctx, "loop-user-end", loop)

    assert {:ok, %{"status" => "failed"}} =
             ConversationServer.update_group_conversation(ctx.group_id, by_router, %{
               "status" => "failed",
               router_agent_id: ctx.router
             })

    settle_receive({:task_loops, :end, ^by_router, "failed"})

    current = task(ctx, by_user)

    assert {:ok, %{"status" => "cancelled"}} =
             ConversationServer.set_task_status(
               ctx.group_id,
               by_user,
               "cancelled",
               current["updated_at"],
               "user-1"
             )

    settle_receive({:task_loops, :end, ^by_user, "cancelled"})
  end

  test "the Task's waiting does not pause its Loop, and ready_for_review waits for its end",
       ctx do
    id = create_task(ctx, "loop-escalate", %{"cadence" => %{"every_minutes" => 15}})
    TaskLoops.put_views(%{id => %{"status" => "active", "trigger" => %{"every_minutes" => 15}}})
    update = &ConversationServer.update_group_conversation(ctx.group_id, id, &1)

    assert {:error, {:forbidden, refusal}} = update.(%{"status" => "ready_for_review"})
    assert refusal =~ "one report is one run"

    assert {:ok, %{"status" => "escalated"}} = update.(%{"status" => "escalated"})
    assert {:ok, %{"status" => "active"}} = update.(%{"status" => "active"})
    settle_refute_receive({:task_loops, :end, ^id, _})

    TaskLoops.put_views(%{id => %{"status" => "ended", "trigger" => %{"every_minutes" => 15}}})
    assert {:ok, %{"status" => "ready_for_review"}} = update.(%{"status" => "ready_for_review"})
  end
end
