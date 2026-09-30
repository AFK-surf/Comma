defmodule SalixAgent.MeetingSummaryScopeTest do
  use ExUnit.Case, async: true
  alias SalixAgent.{MeetingSummaryScope, IFC.Destination}

  defp origin do
    %{
      "source_actor_type" => "provider_system",
      "provider" => "slack",
      "source_message_id" => "meeting-summary:meeting:request",
      "agent_group_id" => "group",
      "provider_context" => %{
        "event_type" => "meeting.summary_requested",
        "meeting_id" => "meeting",
        "summary_request_id" => "request",
        "connect_id" => "connection",
        "channel_id" => "original-channel",
        "thread_ts" => "original-thread"
      }
    }
  end

  test "only sealed matching product origin authorizes submission" do
    ctx = %{trusted_origin: origin()}
    params = %{"meeting_id" => "meeting", "request_id" => "request"}
    assert MeetingSummaryScope.origin(ctx, params) == origin()
    assert MeetingSummaryScope.origin(ctx, %{params | "request_id" => "fake"}) == nil
    forged = put_in(ctx, [:trusted_origin, "source_actor_type"], "provider_user")
    assert MeetingSummaryScope.origin(forged, params) == nil
  end

  test "a summary event cannot grant generic side effects, including in a multi-source batch" do
    ctx = %{
      trusted_origins: %{
        "summary" => origin(),
        "human" => %{"source_actor_type" => "provider_user"}
      }
    }

    for name <-
          ~w(meeting.join script.run im_api.slack.post_message task.create schedule.create memory.write) do
      assert_raise RuntimeError, fn -> MeetingSummaryScope.authorize_tool!(name, ctx) end
    end

    for name <- ~w(help meeting.read_summary_materials meeting.submit_summary memory.search) do
      assert :ok = MeetingSummaryScope.authorize_tool!(name, ctx)
    end

    assert :ok =
             MeetingSummaryScope.authorize_tool!("task.create", %{
               trusted_origin: %{"source_actor_type" => "provider_user"}
             })
  end

  test "IFC submission destination is the sealed original scope, not model arguments" do
    assert {:egress, target} =
             Destination.describe(
               "meeting.submit_summary",
               %{"meeting_id" => "meeting", "request_id" => "request", "channel" => "attacker"},
               %{trusted_origin: origin()}
             )

    assert target["scope_id"] == "original-channel"
    assert target["thread_id"] == "original-thread"
    assert {:read, %{}} = Destination.describe("meeting.read_summary_materials", %{}, %{})
  end
end
