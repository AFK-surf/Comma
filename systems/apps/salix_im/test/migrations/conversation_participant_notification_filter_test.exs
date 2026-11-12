defmodule SalixIM.Migrations.ConversationParticipantNotificationFilterTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationParticipantPGStore, ConversationServer, Conversations, Release}
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

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "name" => "Participant notification migration"
    })

    {:ok, group_id: group_id}
  end

  test "preserves an existing filter and losslessly maps the legacy boolean", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Legacy participants",
               "participants" => [
                 %{"actor_type" => "user", "user_id" => "legacy"},
                 %{"actor_type" => "user", "user_id" => "silent"},
                 %{"actor_type" => "user", "user_id" => "canonical"}
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    legacy = Enum.find(participants, &(&1["user_id"] == "legacy"))
    silent = Enum.find(participants, &(&1["user_id"] == "silent"))
    canonical = Enum.find(participants, &(&1["user_id"] == "canonical"))
    existing_filter = %{"messages" => "mentioned", "statuses" => ["completed"]}

    SalixIM.TestSupport.Fleet.stop_all!()

    rewrite_participant!(group_id, conversation_id, legacy["participant_id"], fn participant ->
      participant
      |> Map.delete("notification_filter")
      |> Map.put("wake_on_message", true)
    end)

    rewrite_participant!(group_id, conversation_id, silent["participant_id"], fn participant ->
      participant
      |> Map.delete("notification_filter")
      |> Map.put("wake_on_message", false)
    end)

    rewrite_participant!(group_id, conversation_id, canonical["participant_id"], fn participant ->
      participant
      |> Map.put("notification_filter", existing_filter)
      |> Map.put("wake_on_message", false)
    end)

    for participant <- [legacy, silent, canonical] do
      assert :migrated =
               ConversationServer.migrate_participant_notification_filter(
                 group_id,
                 conversation_id,
                 participant["participant_id"]
               )
    end

    assert {:ok, migrated_legacy} =
             Conversations.get_group_conversation_participant(
               group_id,
               conversation_id,
               legacy["participant_id"]
             )

    assert migrated_legacy["notification_filter"] == %{
             "messages" => "all",
             "statuses" => "none"
           }

    refute Map.has_key?(migrated_legacy, "wake_on_message")

    assert {:ok, migrated_silent} =
             Conversations.get_group_conversation_participant(
               group_id,
               conversation_id,
               silent["participant_id"]
             )

    assert migrated_silent["notification_filter"] == %{
             "messages" => "none",
             "statuses" => "none"
           }

    refute Map.has_key?(migrated_silent, "wake_on_message")

    assert {:ok, migrated_canonical} =
             Conversations.get_group_conversation_participant(
               group_id,
               conversation_id,
               canonical["participant_id"]
             )

    assert migrated_canonical["notification_filter"] == existing_filter
    refute Map.has_key?(migrated_canonical, "wake_on_message")

    for participant <- [legacy, silent, canonical] do
      assert :skipped =
               ConversationServer.migrate_participant_notification_filter(
                 group_id,
                 conversation_id,
                 participant["participant_id"]
               )
    end
  end

  test "release command requires the explicit no-writer gate" do
    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.migrate_participant_notification_filters()
    end
  end

  defp rewrite_participant!(group_id, conversation_id, participant_id, fun) do
    scope = ConversationParticipantPGStore.new(group_id, conversation_id, participant_id)
    assert {:ok, record, revision} = ConversationParticipantPGStore.read(scope)
    pending = ConversationParticipantPGStore.prepare(scope, revision, fun.(record), :updated)
    assert {:ok, _} = ConversationParticipantPGStore.execute(pending)
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
