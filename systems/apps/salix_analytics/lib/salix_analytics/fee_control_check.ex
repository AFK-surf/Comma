defmodule SalixAnalytics.FeeControlCheck do
  @moduledoc "Builds typed ClickHouse rows for fee-control shadow/enforce checks."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:fee_control, attrs, %{
      provider: attrs[:provider],
      sku: attrs[:sku],
      status: attrs[:status] || "checked",
      mode: attrs[:mode] || "shadow",
      action: attrs[:action],
      target_resource_kind: attrs[:target_resource_kind] || attrs[:resource_kind],
      allowed: Map.get(attrs, :allowed, not (attrs[:would_block] || false)),
      reason: attrs[:reason] || "allowed",
      entitlement_mode: attrs[:entitlement_mode] || "metered",
      decision_id: attrs[:decision_id],
      cache_hit: attrs[:cache_hit] || false,
      cache_age_ms: attrs[:cache_age_ms],
      cache_ttl_ms: attrs[:cache_ttl_ms],
      query_performed: attrs[:query_performed] || false,
      query_duration_ms: attrs[:query_duration_ms],
      result_source: attrs[:result_source] || attrs[:source_type] || "cache",
      would_block: attrs[:would_block] || false,
      would_exceed: attrs[:would_exceed] || false,
      balance_snapshot: attrs[:balance_snapshot],
      trace_id: attrs[:trace_id],
      log_correlation_id: attrs[:log_correlation_id]
    })
  end
end
