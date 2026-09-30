defmodule BillingCore.Repo.Migrations.SeedJevPricing do
  use Ecto.Migration

  # https://docs.typesafe.ai/models, checked 2026-09-20.
  # $0.042 per million input tokens. Output tokens are free.
  def prices do
    Enum.map([{:input, 0.042}, {:output, 0}], fn {component, amount} ->
      %{
        resource_kind: :llm,
        provider: "typesafe",
        sku: "jev-1.13.0",
        component: component,
        meter_unit: :token,
        usd_micros_per_unit: amount,
        credits_per_usd: 1_000_000,
        effective_at: ~U[2026-09-20 00:00:00Z],
        version: "official-2026-09-20"
      }
    end)
  end

  def up do
    for price <- prices() do
      execute("""
      INSERT INTO meter_pricing_catalog
        (id, resource_kind, provider, sku, component, meter_unit,
         usd_micros_per_unit, credits_per_usd, effective_at, version, inserted_at)
      VALUES
        ('official-2026-09-20:llm:typesafe:jev-1.13.0:#{price.component}', 'llm', 'typesafe',
         'jev-1.13.0', '#{price.component}', 'token', #{price.usd_micros_per_unit}, 1000000,
         TIMESTAMPTZ '2026-09-20 00:00:00Z', 'official-2026-09-20', now())
      ON CONFLICT (id) DO NOTHING
      """)
    end
  end

  # Preserve append-only prices that charged usage can reference.
  def down, do: :ok
end
