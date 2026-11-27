defmodule SalixIM.Migrations.RepairArchiveTypoTasksTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationPGStore, ConversationServer, Conversations}
  alias SalixIM.Migrations.RepairArchiveTypoTasks
  alias SalixStore.{CasRecord, Ids, Keys, Repo}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    prev_session_activity = SystemsRuntime.get_env(:salix_im, :session_activity_mod)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    SystemsRuntime.put_env(:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity)

    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, prev_s3)
        restore(:salix_agent, :llm, prev_llm)
        restore(:salix_im, :agent_delivery_mod, prev_agent_delivery)
        restore(:salix_im, :session_activity_mod, prev_session_activity)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Repair group"})

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
      CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    %{group_id: group_id, router_id: router["agent_id"], worker_id: worker["agent_id"]}
  end

  test "dry_run inspects without writing and live run repairs status='archive' to completed via owner",
       %{group_id: group_id, router_id: router_id, worker_id: worker_id} do
    assert {:ok, %{"conversation_id" => task_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "title" => "Corrupted archive typo",
                 "content" => "work",
                 "client_request_id" => "repair-archive-typo-1"
               }
             )

    # Simulate pre-fix corrupted row with status="archive" in both PG column and canonical metadata.
    SalixIM.TestSupport.Fleet.stop_all!()
    scope = ConversationPGStore.new(group_id, task_id)
    {:ok, _raw, rev} = ConversationPGStore.read(scope)

    {:ok, _, _, _} =
      ConversationPGStore.update(scope, rev, fn current ->
        Map.put(current, "status", "archive")
      end)

    assert {:ok, %{"status" => "archive", "archive_availability" => %{"allowed" => false}}} =
             Conversations.get_group_conversation(group_id, task_id)

    assert {:error, {:invalid_target_status, "archive"}} =
             RepairArchiveTypoTasks.run(
               group_id: group_id,
               target_status: "archive",
               dry_run: true
             )

    assert {:ok, %{"dry_run" => true, "candidates" => 1, "repaired" => 0, "failed" => []}} =
             RepairArchiveTypoTasks.run(group_id: group_id, dry_run: true)

    assert {:ok, %{"status" => "archive"}} =
             Conversations.get_group_conversation(group_id, task_id)

    assert {:ok, %{"dry_run" => false, "candidates" => 1, "repaired" => 1, "failed" => []}} =
             RepairArchiveTypoTasks.run(group_id: group_id, dry_run: false)

    assert {:ok,
            %{
              "status" => "completed",
              "archive_availability" => %{"allowed" => true, "reason" => nil}
            }} = Conversations.get_group_conversation(group_id, task_id)

    # Second run is a no-op.
    assert {:ok, %{"dry_run" => false, "candidates" => 0, "repaired" => 0, "failed" => []}} =
             RepairArchiveTypoTasks.run(group_id: group_id, dry_run: false)

    # Verify PG top-level status column also updated.
    assert %{rows: [["completed"]]} =
             Repo.query!(
               "SELECT status FROM salix_conversations WHERE group_id = $1 AND conversation_id = $2",
               [group_id, task_id]
             )
  end

  defp create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs) do
    command = String.trim(attrs["content"])
    created_at = attrs["created_at"] || SystemsClock.system_time(:millisecond)

    with {:ok, conversation_id} <-
           ConversationServer.reserve_task_conversation_id(
             group_id,
             delegator_agent_id,
             worker_agent_id,
             attrs
           ) do
      SalixIM.TaskConversationInput.create_with_id(
        group_id,
        conversation_id,
        delegator_agent_id,
        worker_agent_id,
        attrs
        |> Map.put("schedule", %{"schedule_id" => nil, "command" => command})
        |> Map.put_new("initial_message_attrs", %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => delegator_agent_id,
          "content" => command,
          "metadata" => %{"message_type" => "task_command"},
          "client_request_id" => "delegate-task-" <> conversation_id,
          "created_at" => created_at
        })
      )
    end
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
