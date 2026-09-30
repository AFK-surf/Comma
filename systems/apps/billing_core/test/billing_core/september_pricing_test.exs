defmodule BillingCore.SeptemberPricingTest do
  use ExUnit.Case, async: true

  Code.require_file(
    "../../priv/repo/migrations/20260928000001_seed_missing_staging_prices.exs",
    __DIR__
  )

  alias BillingCore.{Charges, State}
  alias BillingCore.Metering.PricingBackfill
  alias BillingCore.Repo.Migrations.SeedMissingStagingPrices, as: Seed

  test "Grok's long context threshold selects the correct price" do
    assert {:ok, %{charged_credits: 400_006}, _} =
             charge(
               event("x-ai", "x-ai/grok-4.6", ~U[2026-09-17 00:00:00Z], input: 200_000, output: 1)
             )

    assert {:ok, %{charged_credits: 800_016}, _} =
             charge(
               event("x-ai", "x-ai/grok-4.6", ~U[2026-09-17 00:00:00Z], input: 200_001, output: 1)
             )
  end

  test "unpriced GPT-6 usage replays at the full request context tier exactly once" do
    for {tokens, expected} <- [{272_000, 544_010}, {272_001, 1_088_019}] do
      event = event("openai", "gpt-6-sol", ~U[2026-09-28 12:00:00Z], input: tokens, output: 1)

      assert {:pending, _, state} =
               Charges.charge_meter_event(Map.put(event, :state, State.new()))

      state = %{state | pricing_catalog: Seed.prices()}

      assert {:ok, %{charged_count: 1}, state} =
               PricingBackfill.run(%{state: state, now: event.metered_at})

      assert [charge] = state.credit_ledger
      assert charge.charged_credits == expected

      assert {:ok, %{idempotent: true}, same} =
               Charges.charge_meter_event(Map.put(event, :state, state))

      assert same.credit_ledger == state.credit_ledger
    end
  end

  test "cached input counts toward the GPT-6 context threshold without changing usage facts" do
    e =
      event("openai", "openai/gpt-6-astra", ~U[2026-09-28 12:00:00Z],
        input: 1,
        cache_read: 272_000,
        cache_write: 1,
        output: 2
      )

    assert {:ok, charge, _} = charge(e)
    assert charge.charged_credits == 544_195

    assert Enum.find(charge.pricing_components, &(&1.component == "cache_read")).quantity ==
             272_000
  end

  test "named components retain long-context and carrier pricing" do
    llm =
      event("openai", "gpt-6-sol", ~U[2026-09-28 12:00:00Z],
        input: 1,
        cache_read: 272_000,
        output: 1
      )

    voice =
      event("openai", "gpt-live-1", ~U[2026-09-28 12:00:00Z],
        model_seconds: 120,
        carrier_seconds: 125
      )
      |> Map.merge(%{resource_kind: "voice", carrier: "signal"})
      |> Map.update!(:meter_components, &Enum.map(&1, fn c -> %{c | meter_unit: "second"} end))

    for e <- [llm, voice] do
      named =
        Map.update!(
          e,
          :meter_components,
          &Enum.map(&1, fn c ->
            c |> Map.put(:name, c.component) |> Map.delete(:component)
          end)
        )

      assert {:ok, expected, _} = charge(e)
      assert {:ok, actual, _} = charge(named)
      assert actual.charged_credits == expected.charged_credits
    end
  end

  test "DeepSeek charges peak boundaries, weekends and Chinese holidays at the published rates" do
    for {at, amount} <- [
          {~U[2026-09-28 00:59:59Z], 150_000},
          {~U[2026-09-28 01:00:00Z], 300_000},
          {~U[2026-09-28 04:00:00Z], 150_000},
          {~U[2026-09-28 06:00:00Z], 300_000},
          {~U[2026-09-28 10:00:00Z], 150_000},
          {~U[2026-09-26 02:00:00Z], 150_000},
          {~U[2026-10-01 02:00:00Z], 150_000}
        ] do
      assert {:ok, %{charged_credits: ^amount}, _} =
               charge(event("deepseek", "deepseek-flash", at, input: 1_000_000))
    end

    assert {:pending, _, _} =
             charge(event("deepseek", "deepseek-flash", ~U[2027-01-01 02:00:00Z], input: 1))
  end

  test "route keys and Google's announced price transition charge their actual components" do
    for {provider, sku, at, input, output, expected} <- [
          {"typesafe", "typesafe/jev-1.13", ~U[2026-09-20 00:00:00Z], 1_000_000, 10, 42_000},
          {"gemini", "google/gemini-3.8-flash", ~U[2026-12-31 23:59:59Z], 100, 10, 112},
          {"gemini", "google/gemini-3.8-flash", ~U[2027-01-01 00:00:00Z], 100, 10, 225},
          {"anthropic", "claude-opus-5", ~U[2026-08-28 12:00:00Z], 100, 10, 750},
          {"anthropic", "claude-sonnet-5", ~U[2026-08-28 12:00:00Z], 100, 10, 300},
          {"gemini", "gemini-3-flash-preview", ~U[2026-09-04 00:00:00Z], 100, 10, 80}
        ] do
      assert {:ok, %{charged_credits: ^expected}, _} =
               charge(event(provider, sku, at, input: input, output: output))
    end
  end

  test "voice duration uses seconds and zero carrier cost only for the known direct transports" do
    e =
      event("openai", "gpt-live-1", ~U[2026-09-28 00:00:00Z],
        model_seconds: 120,
        carrier_seconds: 125
      )
      |> Map.put(:resource_kind, "voice")
      |> Map.update!(:meter_components, &Enum.map(&1, fn c -> %{c | meter_unit: "second"} end))

    for carrier <- ~w(signal websocket) do
      assert {:ok, %{charged_credits: 100_000}, _} = charge(Map.put(e, :carrier, carrier))
    end

    assert {:pending, _, _} = charge(Map.put(e, :carrier, "unknown-telephony"))
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
