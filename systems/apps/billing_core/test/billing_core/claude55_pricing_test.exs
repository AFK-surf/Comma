defmodule BillingCore.Claude55PricingTest do
  use ExUnit.Case, async: true

  Code.require_file(
    "../../priv/repo/migrations/20260930000002_seed_claude_55_pricing.exs",
    __DIR__
  )

  alias BillingCore.{Charges, State}
  alias BillingCore.Repo.Migrations.SeedClaude55Pricing, as: Seed

  test "Claude 5.5 models charge the published Anthropic rates" do
    at = ~U[2026-09-30 00:00:00Z]
    usage = [input: 1_000, cache_read: 1_000, cache_write: 100, output: 100]

    assert {:ok, %{charged_credits: 6_700}, _} =
             charge(event("anthropic", "claude-opus-5-5", at, usage))

    assert {:ok, %{charged_credits: 3_450}, _} =
             charge(event("anthropic", "claude-sonnet-5-5", at, usage))

    assert {:pending, _, _} =
             charge(event("anthropic", "claude-opus-5-5", ~U[2026-09-21 23:59:59Z], input: 1))
  end

  defp charge(event),
    do:
      Charges.charge_meter_event(
        Map.put(event, :state, State.new(pricing_catalog: Seed.prices()))
      )

  defp event(provider, sku, at, usage) do
    %{
      billing_account_id: "pricing-test",
      source_key: "usage",
      resource_kind: "llm",
      provider: provider,
      sku: sku,
      metered_at: at,
      quantity: 0,
      typed_sink: false,
      meter_components:
        Enum.map(usage, fn {c, n} ->
          %{component: to_string(c), quantity: n, meter_unit: "token"}
        end)
    }
  end
end
