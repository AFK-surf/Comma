defmodule BillingCore.Repo.Migrations.SeedClaude55OpenRouterPricing do
  use Ecto.Migration

  @version "official-2026-09-30-claude-5.5-openrouter"

  # Production reaches Claude 5.5 through the Cloudflare AI Gateway OpenRouter
  # route. OpenRouter names the models `anthropic/claude-opus-5.5` and
  # `anthropic/claude-sonnet-5.5`, so the metered SKU differs from the
  # Anthropic API ids seeded by 20260930000002 (`claude-opus-5-5`,
  # `claude-sonnet-5-5`). OpenRouter passes the Anthropic list price through.
  #
  # Official sources checked 2026-09-30:
  # https://platform.claude.com/docs/en/about-claude/pricing
  # https://openrouter.ai/anthropic/claude-opus-5.5
  # https://openrouter.ai/anthropic/claude-sonnet-5.5
  #   Claude Opus 5.5: $4 input, $0.20 cache read, $5 cache write, $20 output
  #   per 1M tokens. Claude Sonnet 5.5: $2 input, $0.20 cache read, $2.50 cache
  #   write, $10 output per 1M tokens. No context tiers.
  def prices do
    Enum.flat_map(
      [
        {"claude-opus-5.5", ~U[2026-09-22 00:00:00Z], [4, 20, 0.2, 5]},
        {"claude-sonnet-5.5", ~U[2026-09-28 00:00:00Z], [2, 10, 0.2, 2.5]}
      ],
      fn {model, start, amounts} ->
        Enum.flat_map([model, "anthropic/" <> model], &llm(&1, start, amounts))
      end
    )
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
