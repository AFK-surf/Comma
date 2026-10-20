defmodule SalixIM.ConversationMessageFingerprintTest do
  use SystemsClock.Case, async: true

  alias SalixIM.{ConversationMessage, ConversationMessageCodec}

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
end
