defmodule BillingCore.Gpt61FireworksPricingTest do
  use ExUnit.Case, async: true

  Code.require_file(
    "../../priv/repo/migrations/20260930000001_seed_gpt61_sol_and_fireworks_glm52_pricing.exs",
    __DIR__
  )

  alias BillingCore.{Charges, State}
  alias BillingCore.Repo.Migrations.SeedGpt61SolAndFireworksGlm52Pricing, as: Seed

  test "GPT-6.1 Sol charges the published rate and switches tiers above 272K input" do
    at = ~U[2026-09-30 00:00:00Z]

    for sku <- ["gpt-6.1-sol", "openai/gpt-6.1-sol"] do
      assert {:ok, %{charged_credits: 544_010}, _} =
               charge(event("openai", sku, at, input: 272_000, output: 1))

      assert {:ok, %{charged_credits: 1_088_019}, _} =
               charge(event("openai", sku, at, input: 272_001, output: 1))

      assert {:ok, %{charged_credits: 20_010}, _} =
               charge(event("openai", sku, at, cache_read: 200_000, output: 1))
    end
  end

  test "the production GLM-5.2 Fireworks route is priced under its actual metering key" do
    for provider <- ~w(openai fireworks) do
      assert {:ok, %{charged_credits: 1_854}, _} =
               charge(
                 event(provider, "accounts/fireworks/models/glm-5p2", ~U[2026-09-30 00:00:00Z],
                   input: 1_000,
                   cache_read: 100,
                   output: 100
                 )
               )
    end

    assert {:pending, _, _} =
             charge(
               event("openai", "accounts/fireworks/models/glm-5p2", ~U[2026-08-31 23:59:59Z],
                 input: 1
               )
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
          %{component: Atom.to_string(c), quantity: n, meter_unit: "token"}
        end)
    }
  end
end
