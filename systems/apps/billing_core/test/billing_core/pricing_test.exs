defmodule BillingCore.PricingTest do
  use ExUnit.Case, async: true

  alias BillingCore.Pricing

  @now ~U[2026-06-17 00:00:00Z]

  test "resolve/5 chooses account-specific pricing over defaults" do
    catalog = [
      %{
        provider: "openai",
        sku: "tokens",
        credits_per_unit: 10,
        effective_at: ~U[2026-01-01 00:00:00Z]
      },
      %{
        billing_account_id: "acct_1",
        provider: "openai",
        sku: "tokens",
        credits_per_unit: 7,
        effective_at: ~U[2026-01-01 00:00:00Z]
      }
    ]

    assert {:ok, price} = Pricing.resolve(catalog, "acct_1", "openai", "tokens", @now)
    assert price.credits_per_unit == 7
  end

  test "resolve/5 returns missing pricing when no effective catalog row matches" do
    catalog = [
      %{
        provider: "openai",
        sku: "tokens",
        credits_per_unit: 10,
        effective_at: ~U[2026-07-01 00:00:00Z]
      }
    ]

    assert {:error, :missing_pricing} =
             Pricing.resolve(catalog, "acct_1", "openai", "tokens", @now)
  end
end
