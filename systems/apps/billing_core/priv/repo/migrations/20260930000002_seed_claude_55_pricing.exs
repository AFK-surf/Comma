defmodule BillingCore.Repo.Migrations.SeedClaude55Pricing do
  use Ecto.Migration

  @version "official-2026-09-30-claude-5.5"

  # Official source checked 2026-09-30:
  # https://platform.claude.com/docs/en/about-claude/pricing
  #   Claude Opus 5.5: $4 input, $0.20 cache read (0.05x), $5 5m cache write,
  #   $20 output per 1M tokens.
  #   Claude Sonnet 5.5: $2 input, $0.20 cache read, $2.50 5m cache write,
  #   $10 output per 1M tokens.
  #   The 1M context window is standard priced, so there are no context tiers.
  def prices do
    llm("claude-opus-5-5", ~U[2026-09-22 00:00:00Z], [4, 20, 0.2, 5]) ++
      llm("claude-sonnet-5-5", ~U[2026-09-28 00:00:00Z], [2, 10, 0.2, 2.5])
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

  defp llm(sku, start, amounts) do
    for {component, amount} <- Enum.zip(~w(input output cache_read cache_write), amounts) do
      %{
        id: "#{@version}:llm:anthropic:#{sku}:#{component}:#{DateTime.to_unix(start)}",
        resource_kind: "llm",
        provider: "anthropic",
        sku: sku,
        component: component,
        meter_unit: "token",
        usd_micros_per_unit: amount,
        effective_at: start,
        version: @version
      }
    end
  end
end
