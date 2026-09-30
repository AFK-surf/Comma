defmodule BillingCore.Repo.Migrations.SeedResourcePricing do
  use Ecto.Migration

  @version "resource-metering-2026-06"
  @effective_at "2026-06-17 00:00:00Z"

  def up do
    Enum.each(prices(), &insert_price/1)
  end

  def down, do: :ok

  def prices do
    [
      price("vm", "sprites", "runtime-minimum", "runtime", "second", 4.253472222),
      price("storage", "gcs", "regional", "byte_second", "byte_second", 0.000000000007087623494),
      price("storage", "gcs", "standard", "byte_second", "byte_second", 0.000000000007087623494),
      price("storage", "s3", "standard", "byte_second", "byte_second", 0.000000000008751902588)
    ]
  end

  defp price(resource_kind, provider, sku, component, meter_unit, usd_micros_per_unit) do
    %{
      id: "#{@version}:#{resource_kind}:#{provider}:#{sku}:#{component}",
      resource_kind: resource_kind,
      provider: provider,
      sku: sku,
      component: component,
      meter_unit: meter_unit,
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
