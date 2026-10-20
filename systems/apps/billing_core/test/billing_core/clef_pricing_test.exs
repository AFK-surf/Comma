defmodule BillingCore.ClefPricingTest do
  use SystemsClock.Case, async: true

  Code.require_file(
    "../../priv/repo/migrations/20261002000001_seed_clef_pricing.exs",
    __DIR__
  )

  alias BillingCore.{Charges, State}
  alias BillingCore.Repo.Migrations.SeedClefPricing, as: Seed

  test "Clef SKUs charge Cloudflare's published input rates with free output" do
    at = ~U[2026-10-01 00:00:00Z]

    for {sku, expected} <- [{"clef", 240_000}, {"clef-flash", 90_000}] do
      assert {:ok, %{charged_credits: ^expected}, _} =
               charge(event(sku, at, input: 1_000_000, output: 10))
    end

    assert {:pending, _, _} = charge(event("clef", ~U[2026-09-30 23:59:59Z], input: 1))
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
      provider: "cloudflare",
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
