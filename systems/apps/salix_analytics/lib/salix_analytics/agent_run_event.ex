defmodule SalixAnalytics.AgentRunEvent do
  @moduledoc "Builds typed ClickHouse rows for agent run terminal facts."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:agent_run, attrs, %{
      status: attrs[:status],
      duration_ms: attrs[:duration_ms],
      started_at: attrs[:started_at],
      trace_id: attrs[:trace_id],
      request_id: attrs[:request_id],
      salix_agent_id: attrs[:salix_agent_id] || attrs[:agent_id],
      session_id: attrs[:session_id],
      round_id: attrs[:round_id],
      app_revision: attrs[:app_revision],
      task_origin: attrs[:task_origin],
      platform: attrs[:platform],
      source_schedule_id: attrs[:source_schedule_id],
      charge_status: "unattributed"
    })
  end
end
