defmodule BillingCore.Repo.Migrations.SeedCloudflareVmPricing do
  use Ecto.Migration

  # Cloudflare standard-2: 6 GiB memory, 12 GB disk, up to 1 vCPU.
  # The approved fixed rate uses the full CPU ceiling because the VM meter
  # records runtime seconds, not actual CPU seconds. The provider rates are
  # $0.0000025/GiB-second, $0.00000007/GB-second, and $0.000020/vCPU-second.
  # https://developers.cloudflare.com/containers/platform/pricing/
  @usd_micros_per_second 35.84
  @version "cloudflare-standard-2-ceiling-2026-09-24"

  def up do
    execute("""
    INSERT INTO meter_pricing_catalog (
      id, resource_kind, provider, sku, component, meter_unit,
      usd_micros_per_unit, credits_per_usd, effective_at, expires_at,
      version, inserted_at
    ) VALUES (
      '#{@version}:vm:cloudflare:runtime-minimum:runtime',
      'vm', 'cloudflare', 'runtime-minimum', 'runtime', 'second',
      #{@usd_micros_per_second}, 1000000,
      TIMESTAMPTZ '2026-09-20 00:00:00Z', NULL,
      '#{@version}', now()
    )
    ON CONFLICT (id) DO NOTHING
    """)
  end

  # Price rows remain available for the charges that reference them.
  def down, do: :ok
end
