defmodule SalixAnalytics.StorageUsageEvent do
  @moduledoc "Builds typed ClickHouse rows for object-storage byte-second facts."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:storage, attrs, %{
      provider: attrs[:provider],
      sku: attrs[:sku] || attrs[:storage_tier],
      storage_tier: attrs[:storage_tier],
      status: attrs[:status] || "sampled",
      charge_status: attrs[:charge_status] || "unrated",
      quality: attrs[:quality] || attrs[:quality_flags] || [],
      bucket: attrs[:bucket],
      prefix: attrs[:prefix],
      bytes: attrs[:bytes] || 0,
      object_count: attrs[:object_count] || 0,
      sample_window_seconds: attrs[:sample_window_seconds] || 0,
      byte_seconds: attrs[:byte_seconds] || 0,
      tier_source: attrs[:tier_source],
      tier_cache_hit: attrs[:tier_cache_hit] || false
    })
  end
end
