defmodule SalixAnalytics.LlmAttemptEvent do
  @moduledoc """
  Builds typed ClickHouse rows for failed provider attempts: every attempt
  of a logical model request that failed, whether a later attempt
  recovered from it or not. Table `llm_attempt_events`; see the migration
  header for the column meanings. `llm_call_events_v2` keeps the one row
  per logical request; this table explains its `attempts` count and covers
  requests that never reached it.
  """

  alias SalixAnalytics.TypedEvent

  # `killed`: the session actor ended the attempt at the job deadline; its
  # stream-progress columns say what had arrived by then (20260929000001).
  @outcomes ~w(retry abandoned exhausted killed)

  # The sink inserts every key as a column, so the row is built from this
  # list plus the resource fields below and nothing else. A fact that grows
  # a stray field (`body`, `message`, `details`) cannot widen the row: the
  # `reason` summary is the only free-form column, and `SalixAgent.AttemptTelemetry`
  # admits only identifier tokens into it.
  @common ~w(source source_key entrypoint surface tenant_id group_id actor_type
             metered_at created_at started_at version dedup)a

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)
    salix_agent_id = attrs[:salix_agent_id] || attrs[:agent_id]
    common = Map.take(attrs, @common)

    TypedEvent.build(:llm_attempt, common, %{
      provider: attrs[:provider],
      model: attrs[:model],
      attempt: positive(attrs[:attempt], 1),
      max_attempts: positive(attrs[:max_attempts], 1),
      outcome: outcome(attrs[:outcome]),
      category: to_string(attrs[:category] || "unknown"),
      reason: to_string(attrs[:reason] || ""),
      http_status: attrs[:http_status],
      duration_ms: non_negative(attrs[:duration_ms]),
      delay_ms: non_negative(attrs[:delay_ms]),
      started_at: attrs[:started_at],
      trace_id: attrs[:trace_id],
      request_id: attrs[:request_id],
      salix_agent_id: salix_agent_id,
      session_id: attrs[:session_id],
      round_id: attrs[:round_id],
      app_revision: attrs[:app_revision],
      charge_status: "unattributed",
      first_body_ms: optional_non_negative(attrs[:first_body_ms]),
      last_body_ms: optional_non_negative(attrs[:last_body_ms]),
      received_bytes: optional_non_negative(attrs[:received_bytes]),
      received_chunks: optional_non_negative(attrs[:received_chunks]),
      first_content_ms: optional_non_negative(attrs[:first_content_ms]),
      last_content_ms: optional_non_negative(attrs[:last_content_ms]),
      content_deltas: optional_non_negative(attrs[:content_deltas])
    })
  end

  defp outcome(value) do
    text = to_string(value || "")
    if text in @outcomes, do: text, else: "unknown"
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  # Nullable columns: absent means "not observed", which is not zero.
  defp optional_non_negative(value) when is_integer(value) and value >= 0, do: value
  defp optional_non_negative(_value), do: nil
end
