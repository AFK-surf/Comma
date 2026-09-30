defmodule SalixAnalytics.BillingChargeEvent do
  @moduledoc "Builds typed ClickHouse rows for ledger charge projections."

  alias SalixAnalytics.TypedEvent

  def build(attrs) do
    attrs = TypedEvent.atomize(attrs)

    TypedEvent.build(:charge, attrs, %{
      provider: attrs[:provider],
      sku: attrs[:sku],
      status: attrs[:status] || "charged",
      charge_status: attrs[:charge_status] || attrs[:status] || "charged",
      pricing_status: attrs[:pricing_status] || "priced",
      calculated_credits: attrs[:calculated_credits] || 0,
      charged_credits: attrs[:charged_credits] || 0,
      grace_credits: attrs[:grace_credits] || 0,
      balance_after: attrs[:balance_after],
      entitlement_mode: attrs[:entitlement_mode] || "metered",
      pricing_components: attrs[:pricing_components] || [],
      credits_per_usd: attrs[:credits_per_usd] || 1_000_000
    })
  end
end
