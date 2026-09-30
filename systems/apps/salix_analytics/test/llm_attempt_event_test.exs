defmodule SalixAnalytics.LlmAttemptEventTest do
  use ExUnit.Case, async: true

  alias SalixAnalytics.LlmAttemptEvent
  alias SalixAnalytics.Sink.ClickHouseTyped

  @attrs %{
    source: "salix_agent.llm_attempt",
    source_key: "req-1:2",
    entrypoint: "llm_attempt",
    surface: "comma",
    tenant_id: "t1",
    group_id: "g1",
    actor_type: "user",
    provider: "anthropic",
    model: "claude-opus-5",
    attempt: 2,
    max_attempts: 6,
    outcome: :retry,
    category: "retryable_provider_error",
    reason: "rate_limit_error: slow down",
    http_status: 429,
    duration_ms: 9_800,
    delay_ms: 10_000,
    started_at: ~U[2026-09-14 08:25:24.862Z],
    metered_at: ~U[2026-09-14 08:25:34.700Z],
    trace_id: "trace-1",
    request_id: "req-1",
    agent_id: "ag-1",
    session_id: "ses-1",
    round_id: "round-1",
    app_revision: "rev-1"
  }

  test "builds a row routed to llm_attempt_events with the attempt fields" do
    row = LlmAttemptEvent.build(@attrs)

    assert row["resource_kind"] == "llm_attempt"
    assert ClickHouseTyped.table_for!(row) == "llm_attempt_events"
    assert row["attempt"] == 2
    assert row["max_attempts"] == 6
    assert row["outcome"] == "retry"
    assert row["category"] == "retryable_provider_error"
    assert row["reason"] == "rate_limit_error: slow down"
    assert row["http_status"] == 429
    assert row["duration_ms"] == 9_800
    assert row["delay_ms"] == 10_000
    assert row["started_at"] == "2026-09-14T08:25:24.862Z"
    assert row["event_date"] == "2026-09-14"
    assert row["provider"] == "anthropic"
    assert row["model"] == "claude-opus-5"
    assert row["salix_agent_id"] == "ag-1"
    refute Map.has_key?(row, "agent_id")
    assert row["session_id"] == "ses-1"
    assert row["round_id"] == "round-1"
    assert row["charge_status"] == "unattributed"
  end

  test "string keys, unknown outcomes and missing numbers normalize" do
    row =
      @attrs
      |> Map.delete(:agent_id)
      |> Map.merge(%{"salix_agent_id" => "ag-2", "outcome" => "later", "delay_ms" => nil})
      |> Map.delete(:http_status)
      |> LlmAttemptEvent.build()

    assert row["salix_agent_id"] == "ag-2"
    assert row["outcome"] == "unknown"
    assert row["delay_ms"] == 0
    assert row["http_status"] == nil
  end

  test "stray fact fields never become row columns" do
    secret = "sk-live-4f8a2c9e1b7d6a3f0e5c8b2a9d1f4e7c"

    row =
      @attrs
      |> Map.merge(%{
        "message" => "Incorrect API key provided: #{secret}",
        body: ~s({"error":{"message":"Incorrect API key provided: #{secret}"}}),
        details: secret,
        exception: "RuntimeError: #{secret}"
      })
      |> LlmAttemptEvent.build()

    refute Jason.encode!(row) =~ secret

    for column <- ~w(body message details exception agent_id) do
      refute Map.has_key?(row, column), column
    end

    assert Map.keys(row) |> Enum.sort() ==
             ~w(actor_type app_revision attempt category charge_status content_deltas
                created_at delay_ms duration_ms entrypoint event_date first_body_ms
                first_content_ms group_id http_status last_body_ms last_content_ms
                max_attempts metered_at model outcome provider reason received_bytes
                received_chunks request_id resource_kind round_id salix_agent_id session_id
                source source_key started_at surface tenant_id trace_id version)
  end

  test "a killed attempt keeps its stream progress and leaves unobserved values null" do
    row =
      @attrs
      |> Map.merge(%{
        outcome: :killed,
        category: "exit",
        reason: "dependency_timeout",
        http_status: 200,
        first_body_ms: 1_450,
        last_body_ms: 599_980,
        received_bytes: 48_213,
        received_chunks: 3_101,
        first_content_ms: nil,
        content_deltas: 0
      })
      |> LlmAttemptEvent.build()

    assert row["outcome"] == "killed"
    assert row["first_body_ms"] == 1_450
    assert row["last_body_ms"] == 599_980
    assert row["received_bytes"] == 48_213
    assert row["received_chunks"] == 3_101
    assert row["first_content_ms"] == nil
    assert row["last_content_ms"] == nil
    assert row["content_deltas"] == 0

    # Rows of the other outcomes never observed a stream: null, not zero.
    row = LlmAttemptEvent.build(Map.put(@attrs, "received_bytes", -1))
    assert row["received_bytes"] == nil
    assert row["content_deltas"] == nil
  end
end
