defmodule SalixAnalytics.AgentPhaseEvent do
  @moduledoc """
  Builds typed ClickHouse rows for agent round phase facts: the stretches
  of a round between the model and tool calls the other telemetry tables
  record (activation, prepare, response_commit, tool_batch, tool_commit,
  boundary, finalize). Table `agent_phase_events`; see the migration header
  for what each phase measures.
  """

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)
    salix_agent_id = attrs[:salix_agent_id] || attrs[:agent_id]
    # The sink inserts every key as a column: only table columns may remain.
    attrs = Map.delete(attrs, :agent_id)

    TypedEvent.build(:agent_phase, attrs, %{
      phase: to_string(attrs[:phase] || "unknown"),
      status: attrs[:status] || "ok",
      duration_ms: attrs[:duration_ms],
      started_at: attrs[:started_at],
      trace_id: attrs[:trace_id],
      request_id: attrs[:request_id],
      salix_agent_id: salix_agent_id,
      session_id: attrs[:session_id],
      round_id: attrs[:round_id],
      activation_key: attrs[:activation_key],
      app_revision: attrs[:app_revision],
      charge_status: "unattributed"
    })
  end
end
