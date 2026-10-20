defmodule SalixAgent.RepeatedToolResultGuardTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.AsyncToolResults
  alias SalixAgent.InternalSession
  alias SalixAgent.TestSupport.SessionData
  alias SalixStore.Codec

  defp base do
    "agent-repeat"
    |> InternalSession.new("ses1_0000000000000000910", %{})
    |> InternalSession.export()
  end

  defp input(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => id,
        "role" => "user",
        "source_message_id" => "src-#{id}",
        "content" => "input"
      },
      attrs
    )
  end

  defp result(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "tool_result",
        "message_id" => id,
        "tool_call_id" => "call-#{id}",
        "tool_name" => "recommendation.begin",
        "input" => %{},
        "status" => "failed",
        "error" => true,
        "error_class" => "tool_error",
        "error_message" => "recommendation run rejected: :no_recommendation_sources",
        "content" => "error: recommendation run rejected"
      },
      attrs
    )
  end

  defp failed(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "async_tool_call_failed",
        "tool_call_id" => "bg-#{id}",
        "error" => true,
        "error_class" => "tool_error",
        "error_message" => "recommendation run rejected: :no_recommendation_sources",
        "completed_at" => 1_000 + id
      },
      attrs
    )
  end

  test "five identical results in a row park the session; four do not" do
    four = SessionData.apply_events(base(), [input(1) | Enum.map(2..5, &result/1)])
    assert SessionData.query(four, :consecutive_repeated_tool_results) == 4
    refute SessionData.query(four, :repeated_tool_results_exhausted?)
    assert "stable_input_pending" in SessionData.query(four, :work_reasons)

    five = SessionData.apply_event(four, result(6))
    assert SessionData.query(five, :consecutive_repeated_tool_results) == 5
    assert SessionData.query(five, :repeated_tool_results_exhausted?)
    assert SessionData.query(five, :repeated_tool_result_tool) == "recommendation.begin"
    assert SessionData.query(five, :activity_status) == :failed
    assert SessionData.query(five, :activity_issue) == "repeated_tool_result_parked"
    refute "stable_input_pending" in SessionData.query(five, :work_reasons)
  end
end
