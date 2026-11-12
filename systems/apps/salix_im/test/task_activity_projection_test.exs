defmodule SalixIM.TaskActivityProjectionTest do
  use SystemsClock.Case, async: false
  alias SalixIM.{ConversationPGStore, ConversationServer, Conversations}
  alias SalixStore.{Ids, S3}

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    group = Ids.new_group_id(SalixAgent.TestSupport.new_tenant_id())
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Task activity"})
    %{group: group}
  end

  test "the two latest active or attention Tasks include every source with stable tie order", %{
    group: group
  } do
    for {id, status, updated, provider} <- [
          {1, "in_progress", 10, "wechat"},
          {2, "ready_for_review", 20, "comma"},
          {3, "escalated", 20, "slack"}
        ] do
      create(group, id, status, updated, provider)
    end

    for id <- 4..64, do: create(group, id, "completed", id + 100, "comma")
    assert {:ok, %{"data" => [first, second]}} = Conversations.list_group_activity_tasks(group)
    assert first["conversation_id"] == id(3)
    assert second["conversation_id"] == id(2)
    assert first["metadata"]["origin"]["provider"] == "slack"
  end

  test "canonical Task transitions change activity immediately", %{group: group} do
    assert {:ok, task} =
             ConversationServer.create_group_conversation(group, %{
               "kind" => "agent_task",
               "status" => "in_progress",
               "title" => "Running"
             })

    assert {:ok, %{"data" => [_]}} = Conversations.list_group_activity_tasks(group)

    assert {:ok, _} =
             ConversationServer.update_group_conversation(group, task["conversation_id"], %{
               "status" => "ready_for_review"
             })

    assert {:ok, %{"data" => [%{"status" => "ready_for_review"}]}} =
             Conversations.list_group_activity_tasks(group)

    assert {:ok, _} =
             ConversationServer.update_group_conversation(group, task["conversation_id"], %{
               "status" => "completed"
             })

    assert {:ok, %{"data" => []}} = Conversations.list_group_activity_tasks(group)
  end

  test "Group keyset filters in SQL and archived Tasks keep their frozen list position", %{
    group: group
  } do
    a = create(group, 71, "archived", 999, "comma", %{"archived_at" => 10})
    b = create(group, 72, "completed", 20, "comma")
    c = create(group, 73, "completed", 20, "comma")
    create(group, 74, "active", 30, "comma", %{"kind" => "user_chat"})

    assert {:ok, %{"data" => [first], "has_more" => true, "next_cursor" => cursor}} =
             Conversations.list_group_conversations(group, kind: "agent_task", limit: 1)

    assert first["conversation_id"] == b["conversation_id"]

    assert {:ok, %{"data" => [second, third], "has_more" => false}} =
             Conversations.list_group_conversations(group,
               kind: "agent_task",
               limit: 2,
               cursor: cursor
             )

    assert second["conversation_id"] == c["conversation_id"]
    assert third["conversation_id"] == a["conversation_id"]

    assert {:ok, raw, revision} =
             ConversationPGStore.read(ConversationPGStore.new(group, a["conversation_id"]))

    assert {:ok, _, _, _} =
             ConversationPGStore.update(
               ConversationPGStore.new(group, a["conversation_id"]),
               revision,
               fn _ -> Map.put(raw, "updated_at", 5_000) end
             )

    assert {:ok, %{"data" => list}} =
             Conversations.list_group_conversations(group, kind: "agent_task")

    assert Enum.map(list, & &1["conversation_id"]) == [id(72), id(73), id(71)]
  end

  defp create(group, n, status, updated, provider, extra \\ %{}) do
    record =
      Map.merge(
        %{
          "kind" => "agent_task",
          "status" => status,
          "title" => "Task #{n}",
          "created_at" => 1,
          "updated_at" => updated,
          "metadata" => %{"origin" => %{"provider" => provider}},
          "participants" => []
        },
        extra
      )

    assert {:ok, :inserted, stored, _} =
             ConversationPGStore.create(ConversationPGStore.new(group, id(n)), record)

    stored
  end

  defp id(n), do: "cnv1_" <> String.pad_leading(to_string(n), 19, "0")
end
