defmodule BillingCore.Repo.Migrations.SeedClefPricing do
  use Ecto.Migration

  @version "official-2026-10-01-clef"
  @start ~U[2026-10-01 00:00:00Z]

  # Salix `decide` can call Cloudflare's Clef decision models on Workers AI.
  # The metered SKU is the configured `decide.model` (`clef` or `clef-flash`).
  #
  # Official sources checked 2026-10-02:
  # https://developers.cloudflare.com/workers-ai/models/clef/
  # https://developers.cloudflare.com/workers-ai/models/clef-flash/
  # https://developers.cloudflare.com/changelog/post/2026-10-01-clef-workers-ai/
  #   Clef: $0.24, Clef-flash: $0.09 per 1M input tokens. Only input is priced.
  def prices do
    for {sku, input} <- [{"clef", 0.24}, {"clef-flash", 0.09}],
        {component, amount} <- [{"input", input}, {"output", 0}] do
      %{
        id: "#{@version}:llm:cloudflare:#{sku}:#{component}",
        resource_kind: "llm",
        provider: "cloudflare",
        sku: sku,
        component: component,
        meter_unit: "token",
        usd_micros_per_unit: amount,
        effective_at: @start,
        version: @version
      }
    end
  end

  def up do
    for p <- prices() do
      execute("""
      INSERT INTO meter_pricing_catalog
        (id,resource_kind,provider,sku,component,meter_unit,usd_micros_per_unit,
         credits_per_usd,effective_at,expires_at,version)
      VALUES ('#{p.id}','#{p.resource_kind}','#{p.provider}','#{p.sku}',
        '#{p.component}','#{p.meter_unit}',#{p.usd_micros_per_unit},1000000,
        TIMESTAMPTZ '#{p.effective_at}',NULL,'#{p.version}')
      ON CONFLICT (id) DO NOTHING
      """)
    end
  end

  # Charges retain their original pricing evidence.
  def down, do: :ok
end
