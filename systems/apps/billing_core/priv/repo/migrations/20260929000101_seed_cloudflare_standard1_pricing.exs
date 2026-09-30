defmodule BillingCore.Repo.Migrations.SeedCloudflareStandard1Pricing do
  use Ecto.Migration

  @version "cloudflare-standard-1-ceiling-2026-09-29"

  def up do
    execute("""
    INSERT INTO meter_pricing_catalog (
      id, resource_kind, provider, sku, component, meter_unit,
      usd_micros_per_unit, credits_per_usd, effective_at, expires_at,
      version, inserted_at
    ) VALUES (
      '#{@version}:vm:cloudflare:runtime-standard-1:runtime',
      'vm', 'cloudflare', 'runtime-standard-1', 'runtime', 'second',
      20.56, 1000000,
      TIMESTAMPTZ '2026-09-29 00:00:00Z', NULL,
      '#{@version}', now()
    )
    ON CONFLICT (id) DO NOTHING
    """)
  end

  def down, do: :ok
end
