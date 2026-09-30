defmodule SalixAnalytics.TrajectoryEvalEvent do
  @moduledoc """
  Builds typed ClickHouse rows for trajectory eval findings.

  One row per `(session window, metric)`. Rows are reporting-grade (not
  billable): `charge_status` is always `unattributed`. The `source_key`
  includes the window's last message id and the metric, so a re-run over the
  same committed window is idempotent under the `(source, source_key,
  version)` dedup contract.
  """

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:trajectory_eval, attrs, %{
      source: attrs[:source] || "trajectory_eval",
      status: attrs[:status] || "ok",
      charge_status: "unattributed",
      evaluator: attrs[:evaluator] || "heuristic",
      evaluator_version: to_string(attrs[:evaluator_version] || "1"),
      metric: attrs[:metric],
      score: attrs[:score] || 0.0,
      hits: attrs[:hits] || 0,
      verdict: attrs[:verdict] || "",
      reason: attrs[:reason] || "",
      evidence: attrs[:evidence] || [],
      outcome: attrs[:outcome] || "final",
      quality: attrs[:quality] || [],
      salix_agent_id: attrs[:salix_agent_id] || attrs[:agent_id],
      session_id: attrs[:session_id],
      round_id: attrs[:round_id],
      window_from: attrs[:window_from] || 0,
      window_to: attrs[:window_to] || 0,
      window_messages: attrs[:window_messages] || 0
    })
  end
end
