defmodule CommaWeb.RecommendationRuntimePolicyTest do
  use ExUnit.Case, async: true

  alias CommaWeb.RecommendationRuntime

  test "malformed renderer run ids are refused without raising in tool authorization" do
    ctx = %{agent_id: "recommendation-agent", session_id: "recommendation-session"}

    for run_id <- ["call_1426726", "no-sources-rejected-run", "", nil, 42, %{}],
        tool <- ["recommendation.publish", "recommendation.fail"] do
      assert {:error, :forbidden} =
               RecommendationRuntime.authorize_tool(ctx, tool, %{"run_id" => run_id})
    end
  end

  test "legacy schedule delivery cannot start a conversational renderer after cutover" do
    scheduled = "schedule:sch1_1:1757577600000"
    replacement = "recommendation:run:2b7c0d38-8f7f-4a1e-9d34-2e6f2f4c1a10"

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(
               %{source_message_id: scheduled, source_message_ids: [scheduled]},
               "recommendation.begin",
               %{}
             )

    # Historical deliveries remain readable but no longer own generation.
    # The product schedule receiver owns new durable occurrences.
    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(
               %{source_message_id: replacement, source_message_ids: [scheduled, replacement]},
               "recommendation.begin",
               %{}
             )

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(
               %{source_message_id: replacement, source_message_ids: [replacement]},
               "recommendation.begin",
               %{}
             )

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(%{}, "recommendation.begin", %{})
  end

  test "the renderer agent cannot invoke source or unknown tools" do
    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(%{}, "composio.execute", %{
               "tool_slug" => "GMAIL_FETCH_EMAILS",
               "connected_account_id" => "account-1"
             })

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(%{}, "script.run", %{"source" => "int x;"})

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(%{}, "im_api.slack.post_message", %{
               "connect_id" => "slack-1"
             })

    assert {:error, :forbidden} =
             RecommendationRuntime.authorize_tool(%{}, "im_api.slack.list_channel_members", %{
               "connect_id" => "slack-1"
             })

    assert {:error, :forbidden} = RecommendationRuntime.authorize_disclosure(%{}, "web.search")
  end
end
