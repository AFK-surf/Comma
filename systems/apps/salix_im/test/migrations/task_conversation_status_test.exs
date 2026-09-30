defmodule SalixIM.Migrations.TaskConversationStatusTest do
  use ExUnit.Case, async: false

  alias SalixIM.Migrations.TaskConversationStatus
  alias SalixIM.{Conversations, Release}
  alias SalixStore.{Ids, Keys, S3}

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_placement = Application.get_env(:salix_im, :conversation_placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
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

    assert {:ok, stats} = TaskConversationStatus.run(limit: 1)
    assert stats.migrated == 2
    assert stats.skipped >= 1
    assert stats.complete

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

    assert {:ok, rerun} = TaskConversationStatus.run(limit: 2)
    assert rerun.migrated == 0
    assert rerun.failed == []
  end

  test "release command requires an explicit no-writer gate", %{group_id: group_id} do
    _conversation_id = create_task!(group_id, "Release migration Task")

    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.migrate_task_statuses()
    end

    assert %{complete: true} =
             Release.migrate_task_statuses(confirm_no_writers: true, limit: 1)
  end

  test "migration does not accumulate one live owner tree per scanned Conversation", %{
    group_id: group_id
  } do
    conversation_ids =
      for index <- 1..3 do
        create_task!(group_id, "Bounded migration Task #{index}")
      end

    SalixIM.TestSupport.Fleet.stop_all!()
    refute Enum.any?(conversation_ids, &SalixIM.ConversationFleet.running?(group_id, &1))

    assert {:ok, %{complete: true}} = TaskConversationStatus.run(limit: 1)

    assert eventually(fn ->
             not Enum.any?(
               conversation_ids,
               &SalixIM.ConversationFleet.running?(group_id, &1)
             )
           end)
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
    key = Keys.ctl_group_conversation(group_id, conversation_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(key)
    current = Jason.decode!(body)
    assert {:ok, _} = S3.put(key, Jason.encode!(Map.merge(current, fields)), if_match: etag)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
