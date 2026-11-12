defmodule SalixIM.Migrations.TaskConversationStatusTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationPGStore, ConversationServer, Conversations, Release}
  alias SalixStore.Ids

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous_backend)
        restore(:salix_im, :conversation_placement, previous_placement)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Task status migration"})

    {:ok, group_id: group_id}
  end

  test "materializes legacy display status without losing facts and can rerun", %{
    group_id: group_id
  } do
    completed_id = create_task!(group_id, "Completed legacy Task")
    reopened_id = create_task!(group_id, "Reopened legacy Task")
    manually_completed_id = create_task!(group_id, "Manually completed legacy Task")
    escalated_id = create_task!(group_id, "Escalated legacy Task")
    scheduled_id = create_task!(group_id, "Recurring legacy Task")

    completion = %{
      "outcome" => "succeeded",
      "message_id" => Ids.new_message_id(),
      "seq" => 2,
      "by_agent_id" => Ids.new_agent_id(group_id),
      "at" => 1_000
    }

    put_meta!(group_id, completed_id, %{
      "status" => "active",
      "task_last_command_seq" => 1,
      "task_completion" => completion
    })

    put_meta!(group_id, reopened_id, %{
      "status" => "completed",
      "task_last_command_seq" => 3,
      "task_completion" => completion
    })

    put_meta!(group_id, manually_completed_id, %{
      "status" => "completed",
      "task_last_command_seq" => 1,
      "task_completion" => completion
    })

    put_meta!(group_id, escalated_id, %{
      "status" => "escalated",
      "task_last_command_seq" => 1,
      "task_completion" => completion
    })

    put_meta!(group_id, scheduled_id, %{
      "status" => "active",
      "task_last_command_seq" => 1,
      "task_completion" => completion,
      "schedule" => %{"schedule_id" => Ids.new_schedule_id()}
    })

    task_ids = [completed_id, reopened_id, manually_completed_id, escalated_id, scheduled_id]

    results =
      Enum.map(task_ids, fn id ->
        assert {:ok, result} = ConversationServer.migrate_legacy_task_status(group_id, id)
        result
      end)

    assert Enum.count(results, & &1["migrated"]) == 2

    assert {:ok, completed} = Conversations.get_group_conversation(group_id, completed_id)
    assert completed["status"] == "ready_for_review"
    assert completed["task_completion"] == completion
    assert completed["task_last_command_seq"] == 1

    assert {:ok, reopened} = Conversations.get_group_conversation(group_id, reopened_id)
    assert reopened["status"] == "active"
    assert reopened["task_completion"] == completion

    assert {:ok, manually_completed} =
             Conversations.get_group_conversation(group_id, manually_completed_id)

    assert manually_completed["status"] == "completed"
    assert manually_completed["task_completion"] == completion

    assert {:ok, escalated} = Conversations.get_group_conversation(group_id, escalated_id)
    assert escalated["status"] == "escalated"
    assert escalated["task_completion"] == completion

    assert {:ok, scheduled} = Conversations.get_group_conversation(group_id, scheduled_id)
    assert scheduled["status"] == "active"
    assert scheduled["task_completion"] == completion

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.find(listed, &(&1["conversation_id"] == completed_id))["status"] ==
             "ready_for_review"

    assert Enum.find(listed, &(&1["conversation_id"] == reopened_id))["status"] == "active"

    assert Enum.find(listed, &(&1["conversation_id"] == manually_completed_id))["status"] ==
             "completed"

    assert Enum.find(listed, &(&1["conversation_id"] == escalated_id))["status"] ==
             "escalated"

    for id <- task_ids do
      assert {:ok, %{"migrated" => false}} =
               ConversationServer.migrate_legacy_task_status(group_id, id)
    end
  end

  test "release command requires an explicit no-writer gate" do
    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.migrate_task_statuses()
    end
  end

  defp create_task!(group_id, title) do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => title
             })

    conversation_id
  end

  defp put_meta!(group_id, conversation_id, fields) do
    scope = ConversationPGStore.new(group_id, conversation_id)
    assert {:ok, _, revision} = ConversationPGStore.read(scope)
    assert {:ok, _, _, _} = ConversationPGStore.update(scope, revision, &Map.merge(&1, fields))
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
