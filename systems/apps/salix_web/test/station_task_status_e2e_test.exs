defmodule SalixWeb.StationTaskStatusE2ETest do
  @moduledoc """
  A Task that runs on a station, from its Worker's result to its status, end
  to end: the Task, its Participants and delivery, the station's posts
  (`SalixWeb.StationTasks.post/2`), the watches, and the Router's own agent
  loop are the production ones. Only the station's wire (`Station`, which
  answers `task.invite`, `task.put` and `task.status` as an idle station
  does) and the model (`SalixAgent.LLM.Mock`) are stand-ins.

  The production case (2026-11-11): the Worker posted its result without a
  turn-ending state, the Router read it and ended its turn without deciding
  the Task's status, and the Task stayed `active`.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixAgent.LLM.Mock
  alias SalixEnv.Registry
  alias SalixIM.{ConversationServer, Conversations, ProviderConnects, TaskConversationInput}
  alias SalixStore.Compute, as: GroupCompute

  @status_pending "task_status_pending"

  defmodule Station do
    @moduledoc "The station's wire: an idle station that takes part in the Task."
    def request(_run_id, method, params, _opts) do
      case method do
        "task.invite" -> {:ok, %{"session" => "ember:c-1"}}
        "task.put" -> {:ok, %{"through" => params["through"]}}
        "task.status" -> {:ok, %{"state" => "idle", "pending" => 0, "for_ms" => 0}}
        _ -> {:ok, %{}}
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, Mock},
      {:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider},
      {:salix_agent, :visible_reply_mod, Salix.Bindings.AgentVisibleReply},
      {:salix_im, :task_create_mod, Salix.Bindings.AgentConversations},
      {:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery},
      {:salix_im, :session_activity_mod, Salix.Bindings.IMSessionActivity},
      {:salix_im, :task_stations_mod, SalixWeb.StationTasks},
      {:salix_im, :task_worker_watch_grace_ms, 1_000},
      {:salix_im, :station_task_watch,
       [
         vm_not_ready_ms: 60_000,
         station_offline_ms: 60_000,
         not_given_ms: 60_000,
         given_no_reply_ms: 60_000,
         running_ms: 60_000,
         idle_no_reply_ms: 60_000,
         cannot_start_ms: 60_000,
         recheck_ms: 1_000,
         stale_ms: 600_000
       ]},
      {:salix_web, :station_tasks, connector: Station}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    start_supervised!(Mock)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        Enum.each(previous, fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, value} -> SystemsRuntime.put_env(app, key, value)
        end)
      end
    end)

    SalixAgent.TestSupport.configure_platform_models!()

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Station Task status"})

    {:ok, group} =
      Salix.Control.Groups.create(%{"name" => "Station Task status"}, tenant["tenant_id"])

    group_id = group["group_id"]

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group_id, "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group_id, "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    {:ok, _} = Salix.Control.Groups.update(group_id, %{"router_agent_id" => router["agent_id"]})

    view = %{
      tenant_id: tenant["tenant_id"],
      group_id: group_id,
      device_id: "device-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    }

    connect!(view)

    {:ok,
     view: view, group_id: group_id, router_id: router["agent_id"], worker_id: worker["agent_id"]}
  end

  test "the Worker posts its result without a state and the Router ends its turn: the Router is told, and completes the Task",
       ctx do
    conversation_id = start_task(ctx, "invoice")

    # The Router's turn on the result: it tells nobody more and ends, the
    # Task still active (as deepseek-flash did). Its turn on the notice
    # completes the Task.
    Mock.script([
      {:final, "发好了"},
      tool("status", "im_api.internal.update_conversation", %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id,
        "status" => "completed"
      }),
      {:final, "done"}
    ])

    # The station's Session posts its result with chat_post and records
    # all_done with chat_state: the post carries no state.
    post!(ctx, conversation_id, "已把发票 PDF 发给 Yanyu。", nil)

    router_turn_ended!(ctx)
    assert status(ctx, conversation_id) == "active"

    settle_until(fn -> status_notices(ctx, conversation_id) != [] end, ctx, conversation_id)
    assert [_one] = status_notices(ctx, conversation_id)
    settle_until(fn -> status(ctx, conversation_id) == "completed" end, ctx, conversation_id)
  end

  test "the Worker ends its post all_done on a station Task: the Task stays active until the Router decides",
       ctx do
    conversation_id = start_task(ctx, "invoice-declared")
    Mock.script([{:final, "发好了"}])
    post!(ctx, conversation_id, "已把发票 PDF 发给 Yanyu。", "all_done")

    router_turn_ended!(ctx)
    settle_until(fn -> status_notices(ctx, conversation_id) != [] end, ctx, conversation_id)
    assert status(ctx, conversation_id) == "active"
  end

  # What the chain did, printed when a wait runs out.
  defp settle_until(condition, ctx, conversation_id) do
    settle_until(condition)
  rescue
    error ->
      {:ok, messages} =
        Conversations.list_group_conversation_messages(ctx.group_id, conversation_id, limit: 200)

      IO.puts("== status: #{status(ctx, conversation_id)}")

      for m <- messages,
          do:
            IO.puts(
              "== msg #{m["seq"]} #{m["actor_type"]} #{m["agent_id"]} #{inspect(get_in(m, ["metadata"]))} #{inspect(m["content"]) |> String.slice(0, 200)}"
            )

      IO.puts("== mock left: #{inspect(SystemsRuntime.Agent.get(Mock, & &1))}")

      {:ok, session_id} =
        ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

      case SalixAgent.InternalSessionStore.read(ctx.router_id, session_id) do
        {:ok, session} ->
          for m <- SalixAgent.InternalSession.get(session, :messages),
              do: IO.puts("== router #{m.role}: #{inspect(m) |> String.slice(0, 600)}")

        other ->
          IO.puts("== router session: #{inspect(other)}")
      end

      reraise error, __STACKTRACE__
  end

  # -- the chain's entry points ------------------------------------------------

  defp start_task(ctx, request_id) do
    command = "下载山东航空发票 PDF，发给 Yanyu。"

    attrs = %{
      "content" => command,
      "client_request_id" => request_id,
      "schedule" => %{"schedule_id" => nil, "command" => command},
      "runs_on" => %{"kind" => "station", "device_id" => ctx.view.device_id},
      "session_model" => %{"kind" => "runtime", "provider" => "codex"},
      "initial_message_attrs" => %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => ctx.router_id,
        "content" => command,
        "metadata" => %{"message_type" => "task_command"},
        "client_request_id" => "delegate-" <> request_id,
        "created_at" => SystemsClock.system_time(:millisecond)
      }
    }

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             TaskConversationInput.create_with_id(
               ctx.group_id,
               conversation_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    settle()
    conversation_id
  end

  # The station's Session writes in the Task, as `task.post` does.
  defp post!(ctx, conversation_id, text, declared) do
    assert {:ok, %{"seq" => _}} =
             SalixWeb.StationTasks.post(ctx.view, %{
               "task" => conversation_id,
               "session" => "ember:c-1",
               "text" => text,
               "key" => "post-#{SystemsRuntime.Proc.unique_integer([:positive])}",
               "declared" => declared
             })
  end

  defp router_turn_ended!(ctx) do
    {:ok, session_id} =
      ProviderConnects.agent_group_router_session_id(ctx.router_id, ctx.group_id)

    settle_until(fn ->
      match?(
        {:ok, %{"state" => "stopped"}},
        Salix.Bindings.IMSessionActivity.get(ctx.router_id, session_id)
      ) and router_script_moved_on?()
    end)
  end

  # The Router's first turn ran: its script moved on.
  defp router_script_moved_on? do
    SystemsRuntime.Agent.get(Mock, & &1) |> Enum.all?(&(not match?({:final, "发好了"}, &1)))
  end

  defp status(ctx, conversation_id) do
    {:ok, conversation} =
      Conversations.get_group_conversation_record(ctx.group_id, conversation_id)

    conversation["status"]
  end

  defp status_notices(ctx, conversation_id) do
    {:ok, messages} =
      Conversations.list_group_conversation_messages(ctx.group_id, conversation_id, limit: 200)

    Enum.filter(messages, &(get_in(&1, ["metadata", "message_type"]) == @status_pending))
  end

  defp tool(id, operation, params) do
    {:assistant, "", [%{id: id, name: "call", args: %{"tool" => operation, "params" => params}}]}
  end

  defp connect!(view) do
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    proof =
      case GroupCompute.group_workload(view.group_id) do
        {:ok, %{"device_id" => device, "workload_id" => id, "generation" => generation}}
        when device == view.device_id ->
          %{"workload_id" => id, "workload_generation" => generation}

        _ ->
          %{}
      end

    {:ok, ^transport_id, _record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => view.tenant_id,
          "group_id" => view.group_id,
          "device_id" => view.device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Laptop"
        }
        |> Map.merge(proof),
        transport_id: transport_id
      )

    transport_id
  end
end
