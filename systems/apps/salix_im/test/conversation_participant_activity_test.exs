defmodule SalixIM.ConversationParticipantActivityTest do
  use ExUnit.Case, async: true

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

  test "marks only a current activation made entirely of Loop inputs" do
    active = %{
      "state" => "active",
      "status" => "is thinking...",
      "updated_at" => 1,
      "_active_source_message_ids" => ["loop:lop1:poll:242", "loop:lop1:poll:243"]
    }

    assert project(active)["loop_wake"] == true
    refute Map.has_key?(project(%{active | "state" => "stopped"}), "loop_wake")

    for sources <- [[], ["loop:"], ["loop:lop1:poll:242", "local-message"]] do
      refute Map.has_key?(
               project(%{active | "_active_source_message_ids" => sources}),
               "loop_wake"
             )
    end

    refute Map.has_key?(project(active), "_active_source_message_ids")
  end

  defp project(snapshot) do
    ConversationParticipantActivity.status_result(
      "group",
      "conversation",
      "participant",
      snapshot
    )["activity"]
  end
end
