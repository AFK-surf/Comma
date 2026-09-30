defmodule Comma.ConversationsParticipantStatusTest do
  @moduledoc """
  The Participant status is the durable half of a failed turn: when a model
  request dies before committing an assistant message the runtime settles the
  session's own activity to `error` with a stable reason code, and chat keys
  localized copy off that code. Publishing it is what lets the client say
  "could not connect to the model" instead of echoing the runtime's English
  text — or, before this, showing nothing at all.
  """
  use ExUnit.Case, async: true

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

  test "publishes a Loop wake marker only for active Loop work" do
    for state <- ["active", "stopped", "error"] do
      public =
        Comma.Conversations.public_participant_status(
          %{
            "state" => state,
            "status" => "status",
            "updated_at" => 1,
            "loop_wake" => true
          },
          @stream_context
        )

      assert public["loop_wake"] == if(state == "active", do: true, else: nil)
    end
  end

  test "publishes the reason code for an error activity" do
    public =
      Comma.Conversations.public_participant_status(
        %{
          "state" => "error",
          "status" => "error: the model could not be reached",
          "updated_at" => 1_780_000_000.0,
          "issue" => "model_connection_failed"
        },
        @stream_context
      )

    assert public["state"] == "error"
    assert public["issue"] == "model_connection_failed"
  end

  test "omits the reason code for states that are not errors" do
    for state <- ["active", "stopped"] do
      public =
        Comma.Conversations.public_participant_status(
          %{
            "state" => state,
            "status" => "is thinking...",
            "updated_at" => 1_780_000_000.0,
            "issue" => "model_connection_failed"
          },
          @stream_context
        )

      refute Map.has_key?(public, "issue")
    end
  end

  test "omits an absent reason code" do
    public =
      Comma.Conversations.public_participant_status(
        %{"state" => "error", "status" => "error: boom", "updated_at" => 1_780_000_000.0},
        @stream_context
      )

    refute Map.has_key?(public, "issue")
  end

  # The code is a bounded runtime enum, never free text: a client matches on it
  # and an operator reads it, so anything that is not a plain snake_case token
  # is dropped rather than forwarded.
  test "drops a reason code that is not a bounded snake_case token" do
    for issue <- [
          "Model Connection Failed",
          "model-connection-failed",
          "model connection failed",
          String.duplicate("x", 65),
          "",
          123
        ] do
      public =
        Comma.Conversations.public_participant_status(
          %{
            "state" => "error",
            "status" => "error: boom",
            "updated_at" => 1_780_000_000.0,
            "issue" => issue
          },
          @stream_context
        )

      refute Map.has_key?(public, "issue"), "expected #{inspect(issue)} to be dropped"
    end
  end
end
