defmodule SalixAnalytics.TrajectoryEvalRecorder do
  @moduledoc """
  Recorder seam implementation for `SalixAgent.TrajectoryEval.Recorder`
  (duck-typed — salix_analytics does not depend on salix_agent; production
  wires this module in via `:salix_agent, :trajectory_eval_recorder_mod`).

  Fans a runner fact out to one typed row per finding — plus a single `clean`
  row when there are none, so aggregation queries have a denominator — and
  enqueues them on the non-billable reporting path of the typed sink.
  """

  alias SalixAnalytics.{TrajectoryEvalEvent, TypedSinkWorker}

  def record(fact) when is_map(fact) do
    rows = Enum.map(finding_attrs(fact), &TrajectoryEvalEvent.build/1)

    case sink().enqueue(rows) do
      :ok -> :ok
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp finding_attrs(fact) do
    findings =
      case fact[:findings] || [] do
        [] -> [%{metric: "clean", score: 0.0, hits: 0, evidence: []}]
        findings -> findings
      end

    window = fact[:window] || %{}
    billing_context = fact[:billing_context] || %{}
    agent_id = fact[:agent_id]
    session_id = fact[:session_id]
    window_to = window[:to_message_id] || 0
    evaluator = fact[:evaluator] || "heuristic"

    Enum.map(findings, fn finding ->
      %{
        source: "trajectory_eval",
        source_key: "#{agent_id}:#{session_id}:#{window_to}:#{evaluator}:#{finding[:metric]}",
        entrypoint: "trajectory_eval",
        surface: context_value(billing_context, :surface) || "runtime",
        actor_type: context_value(billing_context, :actor_type) || "agent",
        tenant_id:
          fact[:tenant_id] || context_value(billing_context, :salix_tenant_id) || "unknown",
        group_id: fact[:group_id] || context_value(billing_context, :salix_group_id) || "unknown",
        salix_agent_id: agent_id,
        session_id: session_id,
        round_id: window[:round_id],
        evaluator: fact[:evaluator],
        evaluator_version: fact[:evaluator_version],
        outcome: fact[:outcome],
        metric: finding[:metric],
        score: finding[:score],
        hits: finding[:hits],
        verdict: finding[:verdict],
        reason: finding[:reason],
        evidence: finding[:evidence] || [],
        window_from: window[:from_message_id] || 0,
        window_to: window_to,
        window_messages: window[:message_count] || 0
      }
    end)
  end

  defp context_value(context, key) do
    case context[key] || context[to_string(key)] do
      "" -> nil
      value -> value
    end
  end

  defp sink do
    Application.get_env(:salix_analytics, :trajectory_eval_sink, TypedSinkWorker)
  end
end
