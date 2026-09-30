defmodule SalixAnalytics.VMUsageEvent do
  @moduledoc "Builds typed ClickHouse rows for VM runtime interval facts."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:vm, attrs, %{
      provider: attrs[:provider],
      sku: attrs[:sku],
      status: attrs[:status] || "completed",
      charge_status: attrs[:charge_status] || "unrated",
      quality: attrs[:quality] || attrs[:quality_flags] || [],
      interval_start: attrs[:interval_start] || attrs[:started_at],
      interval_end: attrs[:interval_end] || attrs[:ended_at],
      duration_seconds: attrs[:duration_seconds] || 0,
      env_id: attrs[:env_id],
      sprite_name: attrs[:sprite_name]
    })
  end
end
