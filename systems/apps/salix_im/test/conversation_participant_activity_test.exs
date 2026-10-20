defmodule SalixIM.ConversationParticipantActivityTest do
  use SystemsClock.Case, async: true

  alias SalixIM.ConversationParticipantActivity

  test "projects only the provider of the current active work without exposing source identities" do
    for provider <- ["wechat", "telegram", "signal"] do
      snapshot = %{
        "state" => "active",
        "status" => "is thinking...",
        "updated_at" => 1,
        "_active_source_message_ids" => [
          "im_provider:#{provider}:private-connect:event-one",
          "im_provider:#{provider}:private-connect:event-two"
        ]
      }

      assert project(snapshot) == %{
               "state" => "active",
               "status" => "is thinking...",
               "updated_at" => 1,
               "working_provider" => provider
             }

      for state <- ["stopped", "error"] do
        refute Map.has_key?(project(%{snapshot | "state" => state}), "working_provider")
      end

      # A local or mixed activation must replace the preceding channel label.
      for sources <- [
            [],
            ["groupconv:local:message:participant"],
            ["im_provider:wechat:c:1", "im_provider:telegram:c:2"],
            ["im_provider:signal:c:sender:1", "im_provider:telegram:c:2"],
            ["im_provider:wechat:c:1", "local"],
            ["im_provider:wechat::"]
          ] do
        refute Map.has_key?(
                 project(%{snapshot | "_active_source_message_ids" => sources}),
                 "working_provider"
               )
      end
    end
  end

  defp project(snapshot, conversation_id \\ "conversation") do
    ConversationParticipantActivity.status_result(
      "group",
      conversation_id,
      "participant",
      snapshot
    )["activity"]
  end

  defp source(conversation_id, n) do
    {:ok, source} =
      SalixIM.ConversationSourceIdentity.encode(
        conversation_id,
        "msg1_#{1_000_000_000_000_000_000 + n}",
        "ptp1_1000000000000000001"
      )

    source
  end
end
