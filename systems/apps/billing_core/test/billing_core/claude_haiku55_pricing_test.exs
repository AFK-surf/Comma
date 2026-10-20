defmodule BillingCore.ClaudeHaiku55PricingTest do
  use SystemsClock.Case, async: true

  Code.require_file(
    "../../priv/repo/migrations/20261008000001_seed_claude_haiku_55_pricing.exs",
    __DIR__
  )

  alias BillingCore.{Charges, State}
  alias BillingCore.Repo.Migrations.SeedClaudeHaiku55Pricing, as: Seed

  test "Claude Haiku 5.5 charges the published rate for the prompt length" do
    at = ~U[2026-10-08 00:00:00Z]
    short = [input: 89_000, cache_read: 10_000, cache_write: 1_000, output: 1_000]
    long = [input: 89_001, cache_read: 10_000, cache_write: 1_000, output: 1_000]

    for sku <- ~w(claude-haiku-5-5 claude-haiku-5.5 anthropic/claude-haiku-5.5) do
      assert {:ok, %{charged_credits: 9_625}, _} = charge(event(sku, at, short))
      assert {:ok, %{charged_credits: 48_125}, _} = charge(event(sku, at, long))
    end

    assert {:pending, _, _} =
             charge(event("claude-haiku-5-5", ~U[2026-10-06 23:59:59Z], input: 1))
  end

  defp charge(event),
    do:
      Charges.charge_meter_event(
        Map.put(event, :state, State.new(pricing_catalog: Seed.prices()))
      )

  defp event(sku, at, usage) do
    %{
      billing_account_id: "pricing-test",
      source_key: "usage",
      resource_kind: "llm",
      provider: "anthropic",
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
