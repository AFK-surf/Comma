defmodule BillingCore.Repo.Migrations.SeedClaudeHaiku55Pricing do
  use Ecto.Migration

  @version "official-2026-10-08-claude-haiku-5.5"
  @start ~U[2026-10-07 00:00:00Z]

  # Anthropic names the model `claude-haiku-5-5`. OpenRouter names it
  # `anthropic/claude-haiku-5.5` and passes the Anthropic list price through.
  #
  # Official sources checked 2026-10-08:
  # https://platform.claude.com/docs/en/about-claude/pricing
  # https://openrouter.ai/api/v1/models
  #   Prompts up to 100,000 tokens: $0.10 input, $0.01 cache read, $0.125 5m
  #   cache write, $0.50 output per 1M tokens.
  #   Prompts over 100,000 tokens: $0.50 input, $0.05 cache read, $0.625 5m
  #   cache write, $2.50 output per 1M tokens.
  # `BillingCore.Pricing` selects the tier from input plus cached tokens.
  def prices do
    for sku <- ~w(claude-haiku-5-5 claude-haiku-5.5 anthropic/claude-haiku-5.5),
        {tier, amounts} <- [
          {"short_context", [0.1, 0.5, 0.01, 0.125]},
          {"long_context", [0.5, 2.5, 0.05, 0.625]}
        ],
        {component, amount} <- Enum.zip(~w(input output cache_read cache_write), amounts) do
      component = component <> ":" <> tier

      %{
        id: "#{@version}:llm:anthropic:#{sku}:#{component}:#{DateTime.to_unix(@start)}",
        resource_kind: "llm",
        provider: "anthropic",
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
