defmodule SalixIM.ConversationSourceIdentityTest do
  use SystemsClock.Case, async: true

  alias SalixIM.ConversationSourceIdentity

  test "decodes only canonical message ids from the exact conversation" do
    conversation_id = SalixStore.Ids.new_conversation_id()
    other_conversation_id = SalixStore.Ids.new_conversation_id()
    message_id = SalixStore.Ids.new_message_id()
    participant_id = SalixStore.Ids.new_participant_id()

    assert {:ok, source_identity} =
             ConversationSourceIdentity.encode(conversation_id, message_id, participant_id)

    assert {:ok, %{message_id: ^message_id, participant_id: ^participant_id}} =
             ConversationSourceIdentity.decode(source_identity, conversation_id)

    assert ConversationSourceIdentity.message_ids(
             [source_identity, source_identity, "not-an-identity"],
             conversation_id
           ) == [message_id]

    assert ConversationSourceIdentity.message_ids([source_identity], other_conversation_id) == []

    assert ConversationSourceIdentity.conversation_id(source_identity) == {:ok, conversation_id}

    assert ConversationSourceIdentity.conversation_id("groupconv:nope:" <> message_id) ==
             {:error, :invalid_source_identity}

    assert ConversationSourceIdentity.conversation_id(nil) == {:error, :invalid_source_identity}
  end
end
