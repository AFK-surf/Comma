defmodule SalixIM.EndedTaskDeliveryTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixIM.{Conversations, ConversationServer}
  alias SalixStore.{Ids, S3}

  defmodule AgentDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :ended_task_test_pid),
        {:agent_input, agent, payload, opts}
      )

      {:ok, :queued}
    end
  end

  setup do
    previous =
      [
        {:salix_store, :s3_backend, SystemsRuntime.get_env(:salix_store, :s3_backend)}
      ] ++
        for key <- [:conversation_placement, :agent_delivery_mod, :ended_task_test_pid],
            do: {:salix_im, key, SystemsRuntime.get_env(:salix_im, key)}

    SalixIM.TestSupport.Fleet.stop_all!()
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, AgentDelivery)
    SystemsRuntime.put_env(:salix_im, :ended_task_test_pid, SystemsRuntime.Proc.self())
    start_supervised!(S3.Fake)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "EndedTaskDelivery"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, _} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group), fn current ->
        Map.put(current, "router_agent_id", router["agent_id"])
      end)

    %{
      tenant: tenant,
      group: group,
      router: router,
      worker: worker
    }
  end

  test "ended Router-owned Task delivers follow-ups to Router only, and resumes Worker when reopened",
       ctx do
    router_id = ctx.router["agent_id"]
    worker_id = ctx.worker["agent_id"]
    task = create_task(ctx, "Ended plain task")

    # Initial delegation reaches Worker.
    assert_agent_input(worker_id, "Work on Ended plain task")

    # While active, user message reaches both Router and Worker.
    send_user_message(ctx, task, "Still working", "req-active-1")
    assert_agent_input(worker_id, "Still working")
    assert_agent_input(router_id, "Still working")

    # Mark the Task completed.
    set_status(ctx, task, "completed")

    # Follow-up user message goes to Router only, never internal Worker.
    send_user_message(ctx, task, "Follow up after done", "req-done-1")
    assert_agent_input(router_id, "Follow up after done")
    refute_agent_input(worker_id, "Follow up after done")

    # Router's own reply in the ended Task also does not wake internal Worker.
    assert {:ok, _} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               task,
               router_id,
               %{
                 "kind" => "message",
                 "content" => "Router answered follow-up",
                 "client_request_id" => "req-done-router-1"
               }
             )

    refute_agent_input(worker_id, "Router answered follow-up")

    # When Router makes the Task active again, Worker receives new turns again.
    set_status(ctx, task, "active")
    send_user_message(ctx, task, "Continue work now", "req-reopened-1")
    assert_agent_input(worker_id, "Continue work now")
    assert_agent_input(router_id, "Continue work now")
  end

  test "cancelled and failed Router-owned Tasks skip internal Worker unless explicitly targeted",
       ctx do
    router_id = ctx.router["agent_id"]
    worker_id = ctx.worker["agent_id"]

    cancelled_task = create_task(ctx, "Cancelled task")
    assert_agent_input(worker_id, "Work on Cancelled task")
    set_status(ctx, cancelled_task, "cancelled")

    send_user_message(ctx, cancelled_task, "Why was this cancelled?", "req-cancel-1")
    assert_agent_input(router_id, "Why was this cancelled?")
    refute_agent_input(worker_id, "Why was this cancelled?")

    # Explicit delivery_filter targeting Worker still reaches Worker.
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group, cancelled_task)

    worker_participant = Enum.find(participants, &(&1["agent_id"] == worker_id))
    assert is_map(worker_participant)

    assert {:ok, _} =
             ConversationServer.append_group_conversation_message(
               ctx.group,
               cancelled_task,
               %{
                 "kind" => "message",
                 "actor_type" => "user",
                 "user_id" => "user-1",
                 "content" => "Explicitly asking worker",
                 "delivery_filter" => %{
                   "participant_ids" => [worker_participant["participant_id"]]
                 },
                 "client_request_id" => "req-cancel-explicit-1"
               }
             )

    assert_agent_input(worker_id, "Explicitly asking worker")

    failed_task = create_task(ctx, "Failed task")
    assert_agent_input(worker_id, "Work on Failed task")
    set_status(ctx, failed_task, "failed")

    send_user_message(ctx, failed_task, "What failed?", "req-failed-1")
    assert_agent_input(router_id, "What failed?")
    refute_agent_input(worker_id, "What failed?")
  end

  test "ended Collaborative Task still lets host reach Worker", ctx do
    worker_id = ctx.worker["agent_id"]

    task =
      create_task(ctx, "Collab task", %{
        "conversation_metadata" => %{"collaboration" => %{"host_user_id" => "user-1"}},
        "initial_message_attrs" => %{
          "kind" => "message",
          "actor_type" => "user",
          "user_id" => "user-1",
          "content" => "Work on Collab task",
          "metadata" => %{"message_type" => "task_command"}
        }
      })

    assert_agent_input(worker_id, "Work on Collab task")
    set_status(ctx, task, "completed")

    assert {:ok, _} =
             ConversationServer.append_group_conversation_message(
               ctx.group,
               task,
               %{
                 "kind" => "message",
                 "actor_type" => "user",
                 "user_id" => "user-1",
                 "content" => "@Worker please reopen this",
                 "client_request_id" => "req-collab-done-1"
               }
             )

    assert_agent_input(worker_id, "@Worker please reopen this")
  end

  defp create_task(ctx, title, extra \\ %{}) do
    id = Ids.new_conversation_id()

    attrs =
      Map.merge(
        %{
          "title" => title,
          "owner_user_id" => "user-1",
          "content" => "Work on " <> title,
          "schedule" => %{"schedule_id" => nil, "command" => "Work on " <> title},
          "initial_message_attrs" => %{
            "kind" => "message",
            "actor_type" => "agent",
            "agent_id" => ctx.router["agent_id"],
            "content" => "Work on " <> title
          }
        },
        extra
      )

    assert {:ok, _} =
             SalixIM.TaskConversationInput.create_with_id(
               ctx.group,
               id,
               ctx.router["agent_id"],
               ctx.worker["agent_id"],
               attrs
             )

    id
  end

  defp send_user_message(ctx, task, content, request_id) do
    assert {:ok, _} =
             ConversationServer.append_group_conversation_message(
               ctx.group,
               task,
               %{
                 "kind" => "message",
                 "actor_type" => "user",
                 "user_id" => "user-1",
                 "content" => content,
                 "client_request_id" => request_id
               }
             )
  end

  defp set_status(ctx, task, status) when status in ["completed", "cancelled"] do
    {:ok, current} = Conversations.get_group_conversation(ctx.group, task)

    assert {:ok, %{"status" => ^status}} =
             ConversationServer.set_task_status(
               ctx.group,
               task,
               status,
               current["updated_at"],
               "user-1"
             )
  end

  defp set_status(ctx, task, status) do
    assert {:ok, %{"status" => ^status}} =
             ConversationServer.update_group_conversation(ctx.group, task, %{"status" => status})
  end

  defp assert_agent_input(agent, text, attempts \\ 10)
  defp assert_agent_input(_, text, 0), do: flunk("Agent did not receive message: #{text}")

  defp assert_agent_input(agent, text, attempts) do
    settle_receive({:agent_input, ^agent, payload, _})

    if not String.contains?(inspect(payload[:content]), text),
      do: assert_agent_input(agent, text, attempts - 1)
  end

  defp refute_agent_input(agent, text) do
    SystemsClock.run_for(100)
    drain_agent_input(agent, text)
  end

  defp drain_agent_input(agent, text) do
    receive do
      {:agent_input, ^agent, payload, _} ->
        refute String.contains?(inspect(payload[:content]), text)
        drain_agent_input(agent, text)
    after
      0 -> :ok
    end
  end
end
