defmodule BridgeForTeams.TriagePeerReviewObservationTest do
  use ExUnit.Case, async: true
  alias BridgeForTeams.TriagePeerReviewObservation, as: Observation

  test "default and supplemental call budgets preserve strict count and deadline boundaries" do
    baseline = %{provider_calls: 39, deadline: 100}
    assert Observation.provider_allowed?(baseline, 99)
    refute Observation.provider_allowed?(%{baseline | provider_calls: 40}, 99)
    refute Observation.provider_allowed?(baseline, 100)
    supplemental = Map.merge(baseline, %{provider_calls: 55, provider_call_limit: 56})
    assert Observation.provider_allowed?(supplemental, 99)
    refute Observation.provider_allowed?(%{supplemental | provider_calls: 56}, 99)
    refute Observation.provider_allowed?(supplemental, 100)
  end

  test "report receipt must precede exactly one relay and the revised original Task result" do
    report = returned("review", "report")
    revision = returned("original", "revision")

    relay = %{
      tool_calls: [
        %{
          args: %{
            "tool" => "im_api.internal.send_message",
            "params" => %{"conversation_id" => "original"}
          }
        }
      ]
    }

    ordered? = &Observation.ordered_revision?(&1, "review", "report", "original", "revision", &2)
    assert ordered?.([report, relay, revision], 0)

    refute ordered?.(
             [report, %{relay | tool_calls: relay.tool_calls ++ relay.tool_calls}, revision],
             0
           )

    for messages <- [
          [relay, report, revision],
          [report, revision, relay],
          [report, relay, relay, revision],
          [report, revision],
          [returned("other", "report"), relay, revision]
        ] do
      refute ordered?.(messages, 0)
    end

    refute ordered?.([report, relay, revision], 1)
  end

  test "provider identity comes only from the actual same-process Round context" do
    assert Observation.request_identity() == %{}
    context = %{agent_id: "worker", session_id: "fresh", round_id: 4, request_id: "request"}
    Process.put({SalixAgent.Round, :llm_meter_tracker}, %{history_context: context})
    assert Observation.request_identity() == context
    Process.delete({SalixAgent.Round, :llm_meter_tracker})
    assert Observation.request_identity() == %{}
  end

  defp returned(task, result),
    do: %{
      role: "user",
      trusted_origin: %{
        "provider" => "internal",
        "conversation_id" => task,
        "message_id" => result
      }
    }
end
