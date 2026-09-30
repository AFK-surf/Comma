defmodule BillingCore.Repo.Migrations.SeedOpenAIGpt56Pricing do
  use Ecto.Migration

  @version "official-api-2026-07-09"
  @effective_at "2026-07-09 00:00:00Z"

  def up do
    Enum.each(prices(), &insert_price/1)
  end

  # Pricing rows are append-only billing evidence. A rollback must not erase
  # prices that may already be referenced by charged usage.
  def down, do: :ok

  def prices do
    [
      {"gpt-5.6-sol", 5.0, 30.0, 0.5, 6.25},
      {"gpt-5.6-terra", 2.5, 15.0, 0.25, 3.125},
      {"gpt-5.6-luna", 1.0, 6.0, 0.1, 1.25}
    ]
    |> Enum.flat_map(fn {sku, input, output, cache_read, cache_write} ->
      [
        price(sku, "input", input),
        price(sku, "output", output),
        price(sku, "cache_read", cache_read),
        price(sku, "cache_write", cache_write)
      ]
    end)
  end

  defp price(sku, component, usd_micros_per_unit) do
    %{
      id: "#{@version}:llm:openai:#{sku}:#{component}",
      resource_kind: "llm",
      provider: "openai",
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
