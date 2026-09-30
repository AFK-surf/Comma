defmodule BillingCore.FeeControl.Decision do
  @moduledoc "Typed fee-control authorization decision."

  defstruct decision_id: nil,
            billing_account_id: nil,
            mode: :shadow,
            allowed?: true,
            would_block: false,
            reason: "allowed",
            resource_kind: nil,
            action: nil,
            provider: nil,
            sku: nil,
            balance_snapshot: 0,
            entitlement_mode: :metered,
            entitlement_policy: %{},
            cache_hit: false,
            cache_age_ms: nil,
            cache_ttl_ms: nil,
            query_performed: false,
            query_duration_ms: 0,
            checked_at: nil
end
