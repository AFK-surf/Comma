defmodule BillingCore.PricingSeedTest do
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(BillingCore.Repo.Migrations.SeedInitialLlmPricing) do
    Code.require_file(
      "../../priv/repo/migrations/20260623000001_seed_initial_llm_pricing.exs",
      __DIR__
    )
  end

  unless Code.ensure_loaded?(BillingCore.Repo.Migrations.CreateBillingCommerceTables) do
    Code.require_file(
      "../../priv/repo/migrations/20260623000003_create_billing_commerce_tables.exs",
      __DIR__
    )
  end

  unless Code.ensure_loaded?(BillingCore.Repo.Migrations.SeedOpenAIGpt56Pricing) do
    Code.require_file(
      "../../priv/repo/migrations/20260710000001_seed_openai_gpt56_pricing.exs",
      __DIR__
    )
  end

  alias BillingCore.Repo.Migrations.CreateBillingCommerceTables
  alias BillingCore.Repo.Migrations.SeedInitialLlmPricing
  alias BillingCore.Repo.Migrations.SeedOpenAIGpt56Pricing

  test "initial LLM pricing seed covers the investigated official providers" do
    prices = SeedInitialLlmPricing.prices()
    providers = prices |> Enum.map(& &1.provider) |> MapSet.new()

    for provider <- ~w(openai anthropic gemini deepseek kimi glm) do
      assert MapSet.member?(providers, provider)
    end

    assert price(prices, "openai", "gpt-5.5", "input").usd_micros_per_unit == 5.0
    assert price(prices, "openai", "gpt-5.5", "cache_read").usd_micros_per_unit == 0.5
    assert price(prices, "openai", "gpt-5.5", "output").usd_micros_per_unit == 30.0

    assert price(prices, "anthropic", "claude-sonnet-4-6", "cache_write").usd_micros_per_unit ==
             3.75

    assert price(prices, "gemini", "gemini-2.5-pro", "cache_read").usd_micros_per_unit ==
             0.125

    assert price(prices, "deepseek", "deepseek-reasoner", "output").usd_micros_per_unit ==
             2.19

    assert price(prices, "kimi", "kimi-k2.7-code", "cache_read").usd_micros_per_unit ==
             0.19

    assert price(prices, "glm", "glm-4.6", "output").usd_micros_per_unit == 2.2

    assert prices |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(prices)
  end

  test "follow-up OpenAI pricing seed carries post-initial gpt-5.x additions" do
    prices = CreateBillingCommerceTables.openai_gpt52_prices()

    assert price(prices, "openai", "gpt-5.2", "input").usd_micros_per_unit == 1.75
    assert price(prices, "openai", "gpt-5.2", "output").usd_micros_per_unit == 14.0
    assert price(prices, "openai", "gpt-5.2", "cache_read").usd_micros_per_unit == 0.175
    assert price(prices, "openai", "gpt-5.2", "cache_write").usd_micros_per_unit == 1.75

    assert price(prices, "openai", "gpt-5.1", "input").usd_micros_per_unit == 1.25
    assert price(prices, "openai", "gpt-5-mini", "input").usd_micros_per_unit == 0.25
    assert price(prices, "openai", "gpt-5-nano", "input").usd_micros_per_unit == 0.05

    assert prices |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(prices)
  end

  test "GPT-5.6 pricing covers every canonical tier and cache writes" do
    prices = SeedOpenAIGpt56Pricing.prices()

    assert price(prices, "openai", "gpt-5.6-sol", "input").usd_micros_per_unit == 5.0
    assert price(prices, "openai", "gpt-5.6-sol", "output").usd_micros_per_unit == 30.0
    assert price(prices, "openai", "gpt-5.6-sol", "cache_read").usd_micros_per_unit == 0.5
    assert price(prices, "openai", "gpt-5.6-sol", "cache_write").usd_micros_per_unit == 6.25

    assert price(prices, "openai", "gpt-5.6-terra", "input").usd_micros_per_unit == 2.5
    assert price(prices, "openai", "gpt-5.6-terra", "output").usd_micros_per_unit == 15.0
    assert price(prices, "openai", "gpt-5.6-terra", "cache_read").usd_micros_per_unit == 0.25
    assert price(prices, "openai", "gpt-5.6-terra", "cache_write").usd_micros_per_unit == 3.125

    assert price(prices, "openai", "gpt-5.6-luna", "input").usd_micros_per_unit == 1.0
    assert price(prices, "openai", "gpt-5.6-luna", "output").usd_micros_per_unit == 6.0
    assert price(prices, "openai", "gpt-5.6-luna", "cache_read").usd_micros_per_unit == 0.1
    assert price(prices, "openai", "gpt-5.6-luna", "cache_write").usd_micros_per_unit == 1.25

    assert length(prices) == 12
    assert prices |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(prices)
  end

  defp price(prices, provider, sku, component) do
    Enum.find(prices, fn price ->
      price.provider == provider and price.sku == sku and price.component == component
    end) || flunk("missing price #{provider}/#{sku}/#{component}")
  end
end
