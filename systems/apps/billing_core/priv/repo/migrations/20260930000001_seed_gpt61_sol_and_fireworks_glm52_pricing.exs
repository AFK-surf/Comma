defmodule BillingCore.Repo.Migrations.SeedGpt61SolAndFireworksGlm52Pricing do
  use Ecto.Migration

  @version "official-2026-09-30"

  # Official sources checked 2026-09-30:
  # https://developers.openai.com/api/docs/models/gpt-6.1-sol
  #   $2 input, $0.1 cached input, $10 output per 1M tokens; prompts above
  #   272K input tokens cost 2x input and cache rates and 1.5x output.
  # https://fireworks.ai/models/fireworks/glm-5p2
  #   $1.40 input, $0.14 cached input, $4.40 output per 1M tokens (serverless).
  #
  # The production GLM-5.2 template routes through the Cloudflare AI Gateway
  # custom-fireworks endpoint with provider `openai` and model
  # `accounts/fireworks/models/glm-5p2`, so its metering key is
  # (openai, accounts/fireworks/models/glm-5p2). The `fireworks` provider key
  # is seeded as well for a template that names the provider directly.
  def prices do
    gpt_prices("gpt-6.1-sol", ~U[2026-09-29 00:00:00Z], [2, 10, 0.1, 2.5]) ++
      Enum.flat_map(~w(openai fireworks), fn provider ->
        llm(
          provider,
          "accounts/fireworks/models/glm-5p2",
          ~U[2026-09-01 00:00:00Z],
          [1.4, 4.4, 0.14]
        )
      end)
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

  # Context-qualified components match the GPT-6 seed shape so the existing
  # long-context selection keeps working for GPT-6.1.
  defp gpt_prices(sku, start, amounts) do
    for name <- [sku, "openai/" <> sku],
        {tier, multipliers} <- [{"short_context", [1, 1, 1, 1]}, {"long_context", [2, 1.5, 2, 2]}],
        {component, {amount, multiplier}} <-
          Enum.zip(~w(input output cache_read cache_write), Enum.zip(amounts, multipliers)) do
      price("openai", name, component <> ":" <> tier, amount * multiplier, start)
    end
  end

  defp llm(provider, sku, start, amounts) do
    for {component, amount} <- Enum.zip(~w(input output cache_read cache_write), amounts),
        do: price(provider, sku, component, amount, start)
  end

  defp price(provider, sku, component, amount, start) do
    %{
      id: "#{@version}:llm:#{provider}:#{sku}:#{component}:#{DateTime.to_unix(start)}",
      resource_kind: "llm",
      provider: provider,
      sku: sku,
      component: component,
      meter_unit: "token",
      usd_micros_per_unit: amount,
      effective_at: start,
      version: @version
    }
  end
end
