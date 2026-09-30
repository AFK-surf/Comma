defmodule BillingCore.FeeControl.Request do
  @moduledoc "Typed hard fee-control request."

  defstruct billing_account_id: nil,
            resource_kind: nil,
            action: nil,
            provider: nil,
            sku: nil,
            mode: :shadow,
            estimated_credits: 0,
            balance_snapshot: 0,
            checked_at: nil,
            row_context: %{},
            cache_ttl_ms: nil,
            force_refresh: false,
            source: nil,
            source_key: nil,
            typed_sink: nil,
            policy_context: %{}
end
