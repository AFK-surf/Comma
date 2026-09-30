defmodule SalixAnalytics.TrajectoryEvalTest do
  @moduledoc """
  Trajectory eval findings become reporting-grade typed rows: unattributed
  (never billable), idempotent per `(window, metric)` source key, and fanned
  out one row per finding — plus a `clean` denominator row when a round has
  no findings.
  """
  use ExUnit.Case, async: false

  alias SalixAnalytics.{TrajectoryEvalEvent, TrajectoryEvalRecorder}

  defmodule CaptureSink do
    @moduledoc false
    def enqueue(rows, _opts \\ []) do
      send(:persistent_term.get({SalixAnalytics.TrajectoryEvalTest, :test_pid}), {:rows, rows})
      :ok
    end
  end

  setup do
    prev = Application.get_env(:salix_analytics, :trajectory_eval_sink)
    Application.put_env(:salix_analytics, :trajectory_eval_sink, CaptureSink)
    :persistent_term.put({__MODULE__, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})

      if prev,
        do: Application.put_env(:salix_analytics, :trajectory_eval_sink, prev),
        else: Application.delete_env(:salix_analytics, :trajectory_eval_sink)
    end)

    :ok
  end

  defp fact(findings) do
    %{
      agent_id: "agent-1",
      session_id: "sess-1",
      tenant_id: "tenant-1",
      group_id: "group-1",
      billing_context: %{"surface" => "commaboard", "actor_type" => "agent"},
      outcome: "final",
      evaluator: "heuristic",
      evaluator_version: "1",
      window: %{from_message_id: 2, to_message_id: 9, message_count: 8, round_id: "round-z"},
      findings: findings
    }
  end

  test "unattributed rows build without a billing account id" do
    row =
      TrajectoryEvalEvent.build(%{
        source: "trajectory_eval",
        source_key: "a:s:9:confusion",
        entrypoint: "trajectory_eval",
        surface: "commaboard",
        tenant_id: "t",
        group_id: "g",
        actor_type: "agent",
        metric: "confusion",
        score: 0.66,
        hits: 2,
        evidence: [%{message_id: 9, quote: "Wait, that is wrong."}]
      })

    assert row["resource_kind"] == "trajectory_eval"
    assert row["charge_status"] == "unattributed"
    assert row["metric"] == "confusion"
    assert row["score"] == 0.66
    assert row["evidence"] =~ "Wait, that is wrong."
  end

  test "recorder fans one row out per finding with idempotent source keys" do
    findings = [
      %{metric: "confusion", score: 0.5, hits: 1, evidence: []},
      %{metric: "tool_loop", score: 0.6, hits: 4, evidence: []}
    ]

    assert :ok = TrajectoryEvalRecorder.record(fact(findings))
    assert_receive {:rows, rows}

    assert Enum.map(rows, & &1["metric"]) == ["confusion", "tool_loop"]

    assert Enum.map(rows, & &1["source_key"]) ==
             ["agent-1:sess-1:9:heuristic:confusion", "agent-1:sess-1:9:heuristic:tool_loop"]

    assert Enum.all?(rows, &(&1["tenant_id"] == "tenant-1"))
    assert Enum.all?(rows, &(&1["group_id"] == "group-1"))
    assert Enum.all?(rows, &(&1["round_id"] == "round-z"))
    assert Enum.all?(rows, &(&1["surface"] == "commaboard"))
    assert Enum.all?(rows, &(&1["window_to"] == 9))
  end

  test "a clean round still emits a denominator row" do
    assert :ok = TrajectoryEvalRecorder.record(fact([]))
    assert_receive {:rows, [row]}

    assert row["metric"] == "clean"
    assert row["score"] == 0.0
    assert row["source_key"] == "agent-1:sess-1:9:heuristic:clean"
  end

  test "judge facts carry verdicts under evaluator-scoped source keys" do
    judge_fact =
      fact([
        %{
          metric: "confusion",
          score: 0.8,
          hits: 1,
          verdict: "confirmed",
          reason: "The agent restarted its plan twice.",
          evidence: [%{quote: "Wait, that is wrong."}]
        },
        %{metric: "goal_drift", score: 0.1, hits: 1, verdict: "rejected", reason: "On track."}
      ])
      |> Map.merge(%{evaluator: "judge", evaluator_version: "1"})

    assert :ok = TrajectoryEvalRecorder.record(judge_fact)
    assert_receive {:rows, rows}

    assert Enum.map(rows, & &1["source_key"]) ==
             ["agent-1:sess-1:9:judge:confusion", "agent-1:sess-1:9:judge:goal_drift"]

    assert Enum.map(rows, & &1["verdict"]) == ["confirmed", "rejected"]
    assert Enum.all?(rows, &(&1["evaluator"] == "judge"))
    assert hd(rows)["reason"] =~ "restarted"
  end

  test "tenant and group fall back to the billing context, then unknown" do
    fact =
      fact([])
      |> Map.merge(%{tenant_id: nil, group_id: nil})
      |> Map.put(:billing_context, %{"salix_tenant_id" => "bc-tenant"})

    assert :ok = TrajectoryEvalRecorder.record(fact)
    assert_receive {:rows, [row]}

    assert row["tenant_id"] == "bc-tenant"
    assert row["group_id"] == "unknown"
  end
end
