defmodule SalixAnalytics.ToolCallEvent do
  @moduledoc "Builds typed ClickHouse rows for agent tool call terminal facts."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:tool_call, attrs, %{
      tool_name: attrs[:tool_name],
      tool_source: attrs[:tool_source] || "other",
      status: attrs[:status],
      error_type: attrs[:error_type],
      guidance_reason: attrs[:guidance_reason],
      duration_ms: attrs[:duration_ms],
      started_at: attrs[:started_at],
      args_fingerprint: attrs[:args_fingerprint],
      result_fingerprint: attrs[:result_fingerprint],
      call_index: attrs[:call_index],
      async: attrs[:async] || false,
      trace_id: attrs[:trace_id],
      request_id: attrs[:request_id],
      salix_agent_id: attrs[:salix_agent_id] || attrs[:agent_id],
      session_id: attrs[:session_id],
      round_id: attrs[:round_id],
      app_revision: attrs[:app_revision],
      charge_status: "unattributed"
    })
  end
end
