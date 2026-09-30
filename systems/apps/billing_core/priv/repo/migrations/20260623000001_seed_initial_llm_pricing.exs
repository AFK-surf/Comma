defmodule BillingCore.Repo.Migrations.SeedInitialLlmPricing do
  use Ecto.Migration

  @version "official-api-2026-06"
  @effective_at "2026-06-17 00:00:00Z"

  def up do
    Enum.each(prices(), &insert_price/1)
  end

  def down, do: :ok

  def prices do
    []
    |> add_openai()
    |> add_anthropic()
    |> add_gemini()
    |> add_deepseek()
    |> add_kimi()
    |> add_glm()
  end

  defp add_openai(rows) do
    rows ++
      flat_llm("openai", [
        {"gpt-5.5", 5.0, 30.0, 0.5},
        {"gpt-5.5-pro", 30.0, 180.0, nil},
        {"gpt-5.4", 2.5, 15.0, 0.25},
        {"gpt-5.4-mini", 0.75, 4.5, 0.075},
        {"gpt-5.4-nano", 0.2, 1.25, 0.02},
        {"gpt-5.4-pro", 30.0, 180.0, nil}
      ])
  end

  defp add_anthropic(rows) do
    rows ++
      flat_llm("anthropic", [
        {"claude-fable-5", 10.0, 50.0, 1.0, 12.5},
        {"claude-mythos-5", 10.0, 50.0, 1.0, 12.5},
        {"claude-opus-4-8", 5.0, 25.0, 0.5, 6.25},
        {"claude-opus-4-7", 5.0, 25.0, 0.5, 6.25},
        {"claude-opus-4-6", 5.0, 25.0, 0.5, 6.25},
        {"claude-opus-4-5", 5.0, 25.0, 0.5, 6.25},
        {"claude-sonnet-4-6", 3.0, 15.0, 0.3, 3.75},
        {"claude-sonnet-4-5", 3.0, 15.0, 0.3, 3.75},
        {"claude-haiku-4-5", 1.0, 5.0, 0.1, 1.25},
        {"claude-haiku-4-5-20251001", 1.0, 5.0, 0.1, 1.25}
      ])
  end

  defp add_gemini(rows) do
    rows ++
      flat_llm(["gemini", "google"], [
        {"gemini-3.1-flash-lite", 0.25, 1.5, 0.025},
        {"gemini-2.5-pro", 1.25, 10.0, 0.125},
        {"gemini-2.5-flash", 0.3, 2.5, 0.03},
        {"gemini-2.5-flash-lite", 0.1, 0.4, 0.01}
      ])
  end

  defp add_deepseek(rows) do
    rows ++
      flat_llm("deepseek", [
        {"deepseek-chat", 0.27, 1.1, 0.07},
        {"deepseek-reasoner", 0.55, 2.19, 0.14}
      ])
  end

  defp add_kimi(rows) do
    rows ++
      flat_llm(["kimi", "moonshot"], [
        {"kimi-k2.7-code", 0.95, 4.0, 0.19},
        {"kimi-k2.7-code-highspeed", 1.9, 8.0, 0.38},
        {"kimi-k2.6", 0.95, 4.0, 0.16},
        {"kimi-k2.5", 0.6, 3.0, 0.1},
        {"moonshot-v1-8k", 0.2, 2.0, nil},
        {"moonshot-v1-32k", 1.0, 3.0, nil},
        {"moonshot-v1-128k", 2.0, 5.0, nil}
      ])
  end

  defp add_glm(rows) do
    rows ++
      flat_llm(["glm", "zai"], [
        {"glm-5.2", 1.4, 4.4, 0.26},
        {"glm-5.1", 1.4, 4.4, 0.26},
        {"glm-5", 1.0, 3.2, 0.2},
        {"glm-5-turbo", 1.2, 4.0, 0.24},
        {"glm-4.7", 0.6, 2.2, 0.11},
        {"glm-4.7-flashx", 0.07, 0.4, 0.01},
        {"glm-4.6", 0.6, 2.2, 0.11},
        {"glm-4.5", 0.6, 2.2, 0.11},
        {"glm-4.5-x", 2.2, 8.9, 0.45},
        {"glm-4.5-air", 0.2, 1.1, 0.03},
        {"glm-4.5-airx", 1.1, 4.5, 0.22},
        {"glm-4-32b-0414-128k", 0.1, 0.1, nil}
      ])
  end

  defp flat_llm(providers, specs) when is_list(providers) do
    Enum.flat_map(providers, &flat_llm(&1, specs))
  end

  defp flat_llm(provider, specs) do
    Enum.flat_map(specs, fn
      {sku, input, output, cache_read} ->
        llm_prices(provider, sku, input, output, cache_read, input)

      {sku, input, output, cache_read, cache_write} ->
        llm_prices(provider, sku, input, output, cache_read, cache_write)
    end)
  end

  defp llm_prices(provider, sku, input, output, cache_read, cache_write) do
    [
      price(provider, sku, "input", input),
      price(provider, sku, "output", output),
      price(provider, sku, "cache_read", cache_read),
      price(provider, sku, "cache_write", cache_write)
    ]
    |> Enum.reject(&is_nil(&1.usd_micros_per_unit))
  end

  defp price(provider, sku, component, usd_micros_per_unit) do
    %{
      id: "#{@version}:llm:#{provider}:#{sku}:#{component}",
      resource_kind: "llm",
      provider: provider,
      sku: sku,
      component: component,
      meter_unit: "token",
      usd_micros_per_unit: usd_micros_per_unit,
      version: @version,
      effective_at: @effective_at
    }
  end

  defp insert_price(price) do
    execute("""
    INSERT INTO meter_pricing_catalog (
      id,
      resource_kind,
      provider,
      sku,
      component,
      meter_unit,
      usd_micros_per_unit,
      credits_per_usd,
      effective_at,
      expires_at,
      version,
      inserted_at
    ) VALUES (
      '#{escape(price.id)}',
      '#{escape(price.resource_kind)}',
      '#{escape(price.provider)}',
      '#{escape(price.sku)}',
      '#{escape(price.component)}',
      '#{escape(price.meter_unit)}',
      #{price.usd_micros_per_unit},
      1000000,
      TIMESTAMPTZ '#{price.effective_at}',
      NULL,
      '#{escape(price.version)}',
      now()
    )
    ON CONFLICT (id) DO NOTHING
    """)
  end

  defp escape(value), do: value |> to_string() |> String.replace("'", "''")
end
