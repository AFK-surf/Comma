defmodule SalixIM.ConversationMessageFingerprintTest do
  use ExUnit.Case, async: true

  alias SalixIM.{ConversationMessage, ConversationMessageCodec}

  test "trusted recipient identity facts stay outside a strict request fingerprint" do
    base = %{
      "kind" => "message",
      "actor_type" => "provider_user",
      "participant_id" => "prt_00000000000000000000000001",
      "user_id" => "U-human",
      "content" => [%{"type" => "text", "text" => "same provider event"}],
      "metadata" => %{
        "provider" => "slack",
        "connect_id" => "slack-connect",
        "channel_id" => "C-thread"
      }
    }

    old_fingerprint = ConversationMessage.request_fingerprint(base)

    first_identity = %{
      "provider" => "slack",
      "display_name" => "comma-old",
      "username" => "comma_old",
      "user_id" => "U-bot"
    }

    refreshed_identity = %{
      "provider" => "slack",
      "display_name" => "comma-new",
      "username" => "comma_new",
      "user_id" => "U-bot"
    }

    with_string_metadata_identity =
      put_in(base, ["metadata", "recipient_im_identity"], first_identity)

    with_refreshed_metadata_identity =
      put_in(base, ["metadata", "recipient_im_identity"], refreshed_identity)

    with_atom_metadata_identity =
      Map.update!(base, "metadata", &Map.put(&1, :recipient_im_identity, first_identity))

    refute ConversationMessage.request_fingerprint(with_string_metadata_identity) ==
             old_fingerprint

    refute ConversationMessage.request_fingerprint(with_refreshed_metadata_identity) ==
             old_fingerprint

    refute ConversationMessage.request_fingerprint(with_atom_metadata_identity) ==
             old_fingerprint

    with_request_marker =
      Map.put(base, :trusted_provider_recipient_identity_v1, first_identity)

    with_refreshed_request_marker =
      Map.put(base, :trusted_provider_recipient_identity_v1, refreshed_identity)

    with_owner_fact =
      Map.put(base, "owner_recipient_im_identity_v1", first_identity)

    assert ConversationMessage.request_fingerprint(with_request_marker) == old_fingerprint

    assert ConversationMessage.request_fingerprint(with_refreshed_request_marker) ==
             old_fingerprint

    assert ConversationMessage.request_fingerprint(with_owner_fact) == old_fingerprint

    different_content =
      Map.put(with_refreshed_request_marker, "content", [
        %{"type" => "text", "text" => "different provider event"}
      ])

    refute ConversationMessage.request_fingerprint(different_content) == old_fingerprint
  end

  test "message codec accepts only canonical owner recipient identity facts" do
    identity = %{
      "provider" => "slack",
      "display_name" => "Comma App",
      "username" => "comma_bot",
      "user_id" => "U-bot",
      "bot_id" => "B-bot",
      "app_id" => "A-app"
    }

    persisted =
      ConversationMessage.build(
        %{
          "kind" => "message",
          "content" => [%{"type" => "text", "text" => "trusted provider message"}],
          "metadata" => %{"provider" => "slack"}
        },
        %{
          "actor_type" => "provider_user",
          "owner_recipient_im_identity_v1" => identity
        },
        1
      )
      |> Map.put("seq", 1)

    assert :ok = ConversationMessageCodec.validate_row(persisted)

    assert {:error, :invalid_message_segment} =
             persisted
             |> put_in(["owner_recipient_im_identity_v1", "unknown"], "not canonical")
             |> ConversationMessageCodec.validate_row()

    assert {:error, :invalid_message_segment} =
             persisted
             |> put_in(
               ["owner_recipient_im_identity_v1", "display_name"],
               String.duplicate("x", 257)
             )
             |> ConversationMessageCodec.validate_row()

    assert {:error, :invalid_message_segment} =
             persisted
             |> Map.put("owner_recipient_im_identity_v1", %{
               "provider" => "unknown",
               "display_name" => "not a supported provider"
             })
             |> ConversationMessageCodec.validate_row()

    assert {:error, :invalid_message_segment} =
             persisted
             |> Map.put("owner_recipient_im_identity_v1", "not a map")
             |> ConversationMessageCodec.validate_row()
  end

  test "versioned inline Task provenance is owner-authored and projected to delivery" do
    conversation_id = SalixStore.Ids.new_conversation_id()

    inline_ref = %{
      "type" => "conversation_ref",
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "presentation" => "inline"
    }

    attrs = %{
      "kind" => "message",
      "content" => [inline_ref],
      "owner_inline_task_refs_v1" => [Map.put(inline_ref, "conversation_id", "forged")]
    }

    without_owner_fact =
      ConversationMessage.build(attrs, %{"actor_type" => "agent"}, 1)

    refute Map.has_key?(without_owner_fact, "owner_inline_task_refs_v1")

    with_owner_fact =
      ConversationMessage.build(
        attrs,
        %{
          "actor_type" => "agent",
          "owner_inline_task_refs_v1" => [inline_ref]
        },
        1
      )

    assert with_owner_fact["owner_inline_task_refs_v1"] == [inline_ref]

    assert with_owner_fact["request_fingerprint"] ==
             without_owner_fact["request_fingerprint"]

    delivery =
      ConversationMessage.delivery_record(
        %{
          "agent_group_id" => SalixAgent.TestSupport.new_group_id(),
          "conversation_id" => SalixStore.Ids.new_conversation_id(),
          "kind" => "user_chat"
        },
        Map.merge(with_owner_fact, %{"message_id" => SalixStore.Ids.new_message_id(), "seq" => 1}),
        %{"participant_id" => SalixStore.Ids.new_participant_id()},
        1
      )

    assert delivery["owner_inline_task_refs_v1"] == [inline_ref]
    refute Map.has_key?(delivery["message_metadata"], "validated_inline_task_refs")

    persisted = Map.put(with_owner_fact, "seq", 1)
    assert :ok = ConversationMessageCodec.validate_row(persisted)

    assert {:error, :invalid_message_segment} =
             persisted
             |> put_in(["owner_inline_task_refs_v1", Access.at(0), "extra"], "not canonical")
             |> ConversationMessageCodec.validate_row()

    assert {:error, :invalid_message_segment} =
             persisted
             |> Map.put("owner_inline_task_refs_v1", List.duplicate(inline_ref, 17))
             |> ConversationMessageCodec.validate_row()
  end
end
