defmodule SalixIM.Migrations.ConversationStorageSegmentedTest do
  use ExUnit.Case, async: false

  alias SalixIM.{Conversations, ConversationServer, Release}
  alias SalixIM.Migrations.ConversationStorageSegmented

  alias SalixStore.{Ids, Keys, S3}

  @group_id "grp1_1000000000000000001_1000000000000000002"
  @conversation_id "cnv1_1000000000000000003"
  @user_participant_id "ptp1_1000000000000000004"
  @worker_participant_id "ptp1_1000000000000000005"
  @runtime_participant_id "ptp1_1000000000000000006"
  @first_message_id "msg1_1000000000000000007"
  @second_message_id "msg1_1000000000000000008"
  @worker_agent_id "agt1_1000000000000000001_1000000000000000002_1000000000000000009"
  @runtime_agent_id "agt1_1000000000000000001_1000000000000000002_1000000000000000010"
  @worker_session_id "ses1_1000000000000000011"
  @runtime_session_id "ses1_1000000000000000012"

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    put_json!(Keys.ctl_group(@group_id), %{
      "group_id" => @group_id,
      "tenant_id" => Ids.tenant_id_from_group!(@group_id),
      "router_conversation_id" => @conversation_id
    })

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_s3)
    end)

    {:ok, %{group_id: @group_id, conversation_id: @conversation_id}}
  end

  test "migrates legacy flat conversation into segmented storage and can rerun", %{
    group_id: group_id,
    conversation_id: conversation_id
  } do
    legacy_key = legacy_conversation_key(group_id, conversation_id)
    now = System.system_time(:millisecond)

    put_json!(legacy_key, legacy_conversation(group_id, conversation_id, now))

    put_json!(
      legacy_dispatch_key(
        group_id,
        conversation_id,
        @first_message_id,
        @worker_participant_id
      ),
      legacy_dispatch(group_id, conversation_id, now)
    )

    assert {:migrated, %{migrated: 1, failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert {:ok, conversation} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert conversation["conversation_id"] == conversation_id
    assert conversation["agent_group_id"] == group_id
    refute Map.has_key?(conversation, "messages")
    refute Map.has_key?(conversation, "participants")
    refute Map.has_key?(conversation, "participant_count")
    refute Map.has_key?(conversation, "storage_migration")

    assert {:ok, %{"data" => listed_conversations}} =
             Conversations.list_group_conversations(group_id, limit: 10)

    assert Enum.any?(listed_conversations, &(&1["conversation_id"] == conversation_id))

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert Enum.map(messages, & &1["message_id"]) == [@first_message_id, @second_message_id]
    assert Enum.map(messages, & &1["seq"]) == [1, 2]

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation_id,
               limit: 10
             )

    assert Enum.find(participants, &(&1["participant_id"] == @worker_participant_id))[
             "delivery_cursor_seq"
           ] == 2

    assert {:ok, %{"deliveries" => [delivery]}} =
             Conversations.group_conversation_delivery_status(
               group_id,
               conversation_id,
               participant_id: @worker_participant_id,
               limit: 10
             )

    assert delivery["delivery_id"] == "legacy-dispatch-1"
    assert delivery["delivery_kind"] == "group_conversation"
    assert delivery["participant_actor_type"] == "agent"
    assert delivery["participant_id"] == @worker_participant_id
    assert delivery["participant_agent_id"] == @worker_agent_id
    assert delivery["participant_role_label"] == "worker"
    assert delivery["participant_payload"]["session_id"] == @worker_session_id
    assert delivery["message_id"] == @first_message_id
    assert delivery["status"] == "pending"

    migrated_delivery =
      Keys.ctl_group_conversation_participant_delivery_state(
        group_id,
        conversation_id,
        @worker_participant_id,
        delivery["delivery_id"]
      )
      |> read_json!()

    assert migrated_delivery["delivery_session_name"] == "Migrated task"
    assert migrated_delivery["delivery_billing_context"] == "legacy-billing"
    assert migrated_delivery["message_seq"] == 1

    assert {:skipped, %{migrated: 0, failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert {:ok, rerun_messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert Enum.map(rerun_messages, & &1["message_id"]) == [
             @first_message_id,
             @second_message_id
           ]
  end

  test "migration advances participant cursors so historical messages are not redelivered", %{
    group_id: group_id,
    conversation_id: conversation_id
  } do
    legacy_key = legacy_conversation_key(group_id, conversation_id)

    put_json!(
      legacy_key,
      legacy_conversation(group_id, conversation_id, System.system_time(:millisecond))
    )

    assert {:migrated, %{failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert :ok =
             ConversationServer.wake_participant(
               group_id,
               conversation_id,
               @worker_participant_id
             )

    assert {:ok, %{"deliveries" => []}} =
             Conversations.group_conversation_delivery_status(
               group_id,
               conversation_id,
               participant_id: @worker_participant_id,
               limit: 10
             )

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert Enum.map(messages, & &1["message_id"]) == [@first_message_id, @second_message_id]
  end

  test "release cutover requires quiesced writers and executes the owner path", %{
    group_id: group_id,
    conversation_id: conversation_id
  } do
    legacy_key = legacy_conversation_key(group_id, conversation_id)

    put_json!(
      legacy_key,
      legacy_conversation(group_id, conversation_id, System.system_time(:millisecond))
    )

    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.migrate_conversation_storage()
    end

    assert %{segmented: %{migrated: 1}, deliveries: %{failed: 0}} =
             Release.migrate_conversation_storage(confirm_no_writers: true)

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             Conversations.get_group_conversation(group_id, conversation_id)
  end

  test "rerun skips completed segmented migration with pre-canonical identities" do
    legacy_group_id = "proj_legacy"
    legacy_conversation_id = "conv_legacy"
    legacy_key = legacy_conversation_key(legacy_group_id, legacy_conversation_id)
    legacy_target_key = Keys.ctl_group_conversation(legacy_group_id, legacy_conversation_id)

    legacy_target_meta = %{
      "agent_group_id" => legacy_group_id,
      "conversation_id" => legacy_conversation_id,
      "title" => "Legacy conversation",
      "storage_migration" => %{
        "name" => "conversation_storage_segmented",
        "status" => "in_progress",
        "source_key" => legacy_key
      }
    }

    put_json!(legacy_key, %{
      "agent_group_id" => legacy_group_id,
      "conversation_id" => legacy_conversation_id
    })

    put_json!(legacy_target_key, legacy_target_meta)

    put_json!(
      "ctl/migrations/conversation_storage_segmented/" <>
        SalixStore.Crypto.hex(legacy_key) <> ".json",
      %{
        "name" => "conversation_storage_segmented",
        "source_key" => legacy_key,
        "agent_group_id" => legacy_group_id,
        "conversation_id" => legacy_conversation_id
      }
    )

    assert {:skipped, %{migrated: 0, resumed: 0, skipped: 0, failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert {:ok, %{body: body}} = S3.get(legacy_target_key)
    assert {:ok, meta} = Jason.decode(body)
    assert meta["title"] == "Legacy conversation"
    refute Map.has_key?(meta, "storage_migration")

    put_json!(legacy_target_key, legacy_target_meta)
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, legacy_target_key})

    assert {:skipped, %{failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert {:ok, %{body: body}} = S3.get(legacy_target_key)
    assert {:ok, meta} = Jason.decode(body)
    refute Map.has_key?(meta, "storage_migration")

    assert {:skipped, %{failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert :ok = S3.delete(legacy_target_key)

    assert {:skipped, %{failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)
  end

  test "resume upserts legacy participants without removing participants already in new storage",
       %{
         group_id: group_id,
         conversation_id: conversation_id
       } do
    legacy_key = legacy_conversation_key(group_id, conversation_id)
    now = System.system_time(:millisecond)
    legacy = legacy_conversation(group_id, conversation_id, now)
    put_json!(legacy_key, legacy)

    partial_participants = [
      List.first(legacy["participants"]),
      runtime_updated_worker_participant(conversation_id),
      extra_participant(conversation_id)
    ]

    partial =
      legacy
      |> Map.drop(["messages"])
      |> Map.put("message_count", 0)
      |> Map.put("target_message_count", 0)
      |> Map.put("participants", partial_participants)
      |> Map.put("storage_migration", %{
        "name" => "conversation_storage_segmented",
        "status" => "in_progress",
        "source_key" => legacy_key,
        "started_at" => now
      })

    Enum.each(partial_participants, fn participant ->
      participant = Map.put(participant, "conversation_id", conversation_id)

      put_json!(
        Keys.ctl_group_conversation_participant_state(
          group_id,
          conversation_id,
          participant["participant_id"]
        ),
        participant
      )
    end)

    put_json!(
      Keys.ctl_group_conversation(group_id, conversation_id),
      Map.drop(partial, ["participants", "participant_count"])
    )

    assert {:resumed, %{failed: 0}} =
             ConversationStorageSegmented.migrate_conversation(legacy_key)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation_id,
               limit: 10
             )

    assert Enum.any?(participants, &(&1["participant_id"] == @worker_participant_id))
    assert Enum.any?(participants, &(&1["participant_id"] == @runtime_participant_id))

    worker = Enum.find(participants, &(&1["participant_id"] == @worker_participant_id))
    assert worker["payload"] == %{"session_id" => @runtime_session_id}
  end

  defp legacy_conversation_key(group_id, conversation_id) do
    "ctl/group_conversations/#{group_id}/#{conversation_id}.json"
  end

  defp legacy_dispatch_key(group_id, conversation_id, message_id, participant_id) do
    "ctl/group_conversation_dispatch/#{group_id}/#{conversation_id}/" <>
      "#{SalixStore.Crypto.hex(message_id)}/#{SalixStore.Crypto.hex(participant_id)}.json"
  end

  defp legacy_conversation(group_id, conversation_id, now) do
    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "title" => "Migrated task",
      "status" => "active",
      "activity_status" => "idle",
      "participant_count" => 2,
      "created_at" => now,
      "updated_at" => now + 2,
      "participants" => [
        %{
          "participant_id" => @user_participant_id,
          "actor_type" => "user",
          "user_id" => "user-1",
          "state" => "active",
          "notification_filter" => %{"messages" => "none", "statuses" => "none"}
        },
        %{
          "participant_id" => @worker_participant_id,
          "actor_type" => "agent",
          "agent_id" => @worker_agent_id,
          "role_label" => "worker",
          "state" => "active",
          "notification_filter" => %{"messages" => "all", "statuses" => "none"},
          "payload" => %{"session_id" => @worker_session_id}
        }
      ],
      "messages" => [
        %{
          "message_id" => @first_message_id,
          "kind" => "message",
          "participant_id" => @user_participant_id,
          "actor_type" => "user",
          "user_id" => "user-1",
          "content" => "first",
          "created_at" => now + 1,
          "metadata" => %{}
        },
        %{
          "message_id" => @second_message_id,
          "kind" => "message",
          "participant_id" => @user_participant_id,
          "actor_type" => "user",
          "user_id" => "user-1",
          "content" => "second",
          "created_at" => now + 2,
          "metadata" => %{}
        }
      ]
    }
  end

  defp legacy_dispatch(group_id, conversation_id, now) do
    %{
      "dispatch_id" => "legacy-dispatch-1",
      "dispatch_kind" => "group_conversation",
      "status" => "pending",
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "conversation_kind" => "agent_task",
      "conversation_title" => "Migrated task",
      "message_id" => @first_message_id,
      "target_actor_type" => "agent",
      "target_participant_id" => @worker_participant_id,
      "target_agent_id" => @worker_agent_id,
      "target_role_label" => "worker",
      "target_session_id" => @worker_session_id,
      "target_session_name" => "Migrated task",
      "target_billing_context" => "legacy-billing",
      "source_participant_id" => @user_participant_id,
      "source_actor_type" => "user",
      "source_user_id" => "user-1",
      "message_content" => "first",
      "message_metadata" => %{},
      "message_created_at" => now + 1,
      "operation_ref" => "legacy-operation-ref",
      "attempts" => 0,
      "created_at" => now + 1,
      "updated_at" => now + 1
    }
  end

  defp extra_participant(conversation_id) do
    %{
      "participant_id" => @runtime_participant_id,
      "conversation_id" => conversation_id,
      "actor_type" => "agent",
      "agent_id" => @runtime_agent_id,
      "role_label" => "worker",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "payload" => %{"session_id" => @runtime_session_id}
    }
  end

  defp runtime_updated_worker_participant(conversation_id) do
    0
    |> then(&legacy_conversation("runtime-group", conversation_id, &1))
    |> Map.fetch!("participants")
    |> Enum.find(&(&1["participant_id"] == @worker_participant_id))
    |> Map.put("payload", %{"session_id" => @runtime_session_id})
    |> Map.put("updated_at", System.system_time(:millisecond) + 1000)
  end

  defp put_json!(key, value) do
    assert {:ok, _} = S3.put(key, Jason.encode!(value))
  end

  defp read_json!(key) do
    assert {:ok, %{body: body}} = S3.get(key)
    Jason.decode!(body)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
