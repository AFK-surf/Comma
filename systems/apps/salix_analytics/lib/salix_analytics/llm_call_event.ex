defmodule SalixAnalytics.LLMCallEvent do
  @moduledoc "Builds typed ClickHouse rows for raw LLM provider call facts."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)
    usage = TypedEvent.atomize(attrs[:usage] || %{})

    TypedEvent.build(:llm, attrs, %{
      provider: attrs[:provider],
      sku: attrs[:sku] || attrs[:model],
      model: attrs[:model],
      status: attrs[:status] || "ok",
      charge_status: attrs[:charge_status] || "unrated",
      quality: attrs[:quality] || attrs[:quality_flags] || [],
      prompt_tokens: usage[:prompt_tokens] || attrs[:prompt_tokens] || 0,
      completion_tokens: usage[:completion_tokens] || attrs[:completion_tokens] || 0,
      total_tokens: usage[:total_tokens] || attrs[:total_tokens] || 0,
      cache_read_input_tokens:
        usage[:cache_read_input_tokens] || attrs[:cache_read_input_tokens] || 0,
      cache_write_input_tokens:
        usage[:cache_write_input_tokens] || attrs[:cache_write_input_tokens] || 0,
      usage_reported: usage[:usage_reported],
      prompt_tokens_reported: usage[:prompt_tokens_reported],
      completion_tokens_reported: usage[:completion_tokens_reported],
      cache_read_tokens_reported: usage[:cache_read_tokens_reported],
      reasoning_tokens: usage[:reasoning_tokens],
      duration_ms: attrs[:duration_ms],
      started_at: attrs[:started_at],
      first_token_ms: attrs[:first_token_ms],
      attempts: attrs[:attempts] || 1,
      response_kind: attrs[:response_kind],
      error_type: attrs[:error_type] || "none",
      http_status: attrs[:http_status],
      app_revision: attrs[:app_revision],
      trace_id: attrs[:trace_id],
      request_id: attrs[:request_id],
      salix_agent_id: attrs[:salix_agent_id],
      session_id: attrs[:session_id],
      turn_id: attrs[:turn_id],
      round_id: attrs[:round_id],
      stale: attrs[:stale] || false
    })
  end
end
