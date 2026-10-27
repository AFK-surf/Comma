defmodule Comma.ConversationsParticipantStatusTest do
  @moduledoc """
  The Participant status is the durable half of a failed turn: when a model
  request dies before committing an assistant message the runtime settles the
  session's own activity to `error` with a stable reason code, and chat keys
  localized copy off that code. Publishing it is what lets the client say
  "could not connect to the model" instead of echoing the runtime's English
  text — or, before this, showing nothing at all.
  """
  use SystemsClock.Case, async: true

  @stream_context %{participant_id: "ptp_1", conversation_id: "cnv_1"}

  test "publishes a channel only for active work and supported providers" do
    for provider <- ["wechat", "telegram", "signal", "unknown"],
        state <- ["active", "stopped", "error"] do
      public =
        Comma.Conversations.public_participant_status(
          %{
            "state" => state,
            "status" => "status",
            "updated_at" => 1,
            "working_provider" => provider
          },
          @stream_context
        )

      assert public["working_provider"] ==
               if(state == "active" and provider in ["wechat", "telegram", "signal"],
                 do: provider,
                 else: nil
               )
    end
  end

  test "publishes bounded funding detail only for an error funding stop" do
    detail = %{
      "source" => "anthropic",
      "profile_id" => "prof_1-A",
      "profile_name" => "Team Claude key",
      "reset_at" => 1_790_000_000,
      "message" => "provider text"
    }

    public =
      Comma.Conversations.public_participant_status(
        %{
          "state" => "error",
          "status" => "error",
          "updated_at" => 1,
          "issue" => "provider_quota_exhausted",
          "issue_detail" => detail
        },
        @stream_context
      )

    assert public["issue_detail"] == Map.delete(detail, "message")

    for {issue, bad} <- [
          {"model_connection_failed", detail},
          {"provider_quota_exhausted",
           %{"source" => "Bad Source!", "profile_name" => "line\nbreak", "reset_at" => -1}}
        ] do
      public =
        Comma.Conversations.public_participant_status(
          %{
            "state" => "error",
            "status" => "error",
            "updated_at" => 1,
            "issue" => issue,
            "issue_detail" => bad
          },
          @stream_context
        )

      refute Map.has_key?(public, "issue_detail")
    end
  end

  test "publishes the tool a call runs and when a wait began only for active work" do
    for state <- ["active", "stopped", "error"] do
      tool =
        Comma.Conversations.public_participant_status(
          %{
            "state" => state,
            "status" => "status",
            "updated_at" => 1,
            "wait_tool" => "cloud_vm.start",
            "wait_started_at" => 1_780_000_000_000
          },
          @stream_context
        )

      assert tool["wait_tool"] == if(state == "active", do: "cloud_vm.start")
      assert tool["wait_started_at"] == if(state == "active", do: 1_780_000_000_000)
      refute Map.has_key?(tool, "waiting")

      wait =
        Comma.Conversations.public_participant_status(
          %{
            "state" => state,
            "status" => "status",
            "updated_at" => 1,
            "waiting" => true,
            "wait_started_at" => 1_780_000_000_000
          },
          @stream_context
        )

      assert wait["wait_started_at"] == if(state == "active", do: 1_780_000_000_000)
    end

    # A start without a wait or a tool, or an oversized tool name, is not published.
    public =
      Comma.Conversations.public_participant_status(
        %{
          "state" => "active",
          "status" => "status",
          "updated_at" => 1,
          "wait_started_at" => 1,
          "wait_tool" => String.duplicate("a", 129)
        },
        @stream_context
      )

    refute Map.has_key?(public, "wait_started_at")
    refute Map.has_key?(public, "wait_tool")
  end

  test "publishes the reason code for an error activity" do
    public =
      Comma.Conversations.public_participant_status(
        %{
          "state" => "error",
          "status" => "error: the model request failed",
          "updated_at" => 1_780_000_000.0,
          "issue" => "model_connection_failed"
        },
        @stream_context
      )

    assert public["state"] == "error"
    assert public["issue"] == "model_connection_failed"
  end
end
