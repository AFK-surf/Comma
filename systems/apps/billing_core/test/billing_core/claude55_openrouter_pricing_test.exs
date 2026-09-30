defmodule BillingCore.Claude55OpenRouterPricingTest do
  use ExUnit.Case, async: true

  Code.require_file(
    "../../priv/repo/migrations/20260930000007_seed_claude_55_openrouter_pricing.exs",
    __DIR__
  )

  alias BillingCore.{Charges, State}
  alias BillingCore.Repo.Migrations.SeedClaude55OpenRouterPricing, as: Seed

  test "OpenRouter Claude 5.5 SKUs charge the published Anthropic rates" do
    at = ~U[2026-09-30 00:00:00Z]
    usage = [input: 1_000, cache_read: 1_000, cache_write: 100, output: 100]

    for sku <- ["anthropic/claude-opus-5.5", "claude-opus-5.5"] do
      assert {:ok, %{charged_credits: 6_700}, _} = charge(event("anthropic", sku, at, usage))
    end

    for sku <- ["anthropic/claude-sonnet-5.5", "claude-sonnet-5.5"] do
      assert {:ok, %{charged_credits: 3_450}, _} = charge(event("anthropic", sku, at, usage))
    end

    assert {:pending, _, _} =
             charge(
               event("anthropic", "anthropic/claude-opus-5.5", ~U[2026-09-21 23:59:59Z], input: 1)
             )
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
