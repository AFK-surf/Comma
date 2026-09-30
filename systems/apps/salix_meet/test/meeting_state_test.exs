defmodule SalixMeet.MeetingStateTest do
  use ExUnit.Case, async: true

  alias SalixMeet.MeetingState

  test "requires an explicit runtime selector" do
    assert {:error, :meeting_runtime_source_required} =
             MeetingState.new_slack("meeting", meeting_agent(), attrs())
  end

  test "persists the explicitly selected runtime" do
    assert {:ok, state} =
             MeetingState.new_slack(
               "meeting",
               meeting_agent(),
               Map.put(attrs(), "runtime_source", "connected_runtime")
             )

    assert state["runtime_source"] == "connected_runtime"
    assert state["runtime_policy"] == %{"source" => "connected_runtime"}
  end

  defp meeting_agent do
    %{"meeting_agent_id" => "agent", "meeting_session_id" => "session"}
  end

  defp attrs do
    %{
      "tenant_id" => "tenant",
      "group_id" => "group",
      "connect_id" => "connect",
      "slack_ref" => %{"channel_id" => "channel", "thread_ts" => "thread"},
      "meet_url" => "https://meet.example.test/meeting",
      "title" => "Meeting",
      "caption_language" => "en-US",
      "bot_name" => "Comma",
      "start_at" => 1,
      "end_at" => 2,
      "source" => %{}
    }
  end
end
