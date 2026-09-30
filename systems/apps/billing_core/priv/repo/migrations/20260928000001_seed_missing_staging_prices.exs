defmodule BillingCore.Repo.Migrations.SeedMissingStagingPrices do
  use Ecto.Migration

  @version "official-2026-09-28"
  @year_end ~U[2027-01-01 00:00:00Z]

  # Official sources checked 2026-09-28:
  # https://developers.openai.com/api/docs/models/gpt-6-luna
  # https://openrouter.ai/api/v1/models
  # https://docs.x.ai/developers/models/grok-4.6
  # https://openrouter.ai/x-ai/grok-4.6
  # https://openrouter.ai/google/gemini-3.7-flash
  # https://developers.openai.com/api/docs/models/gpt-6-sol
  # https://developers.openai.com/api/docs/models/gpt-6-astra
  # https://developers.openai.com/api/docs/models/gpt-live-1
  # https://platform.claude.com/docs/en/about-claude/pricing
  # https://ai.google.dev/gemini-api/docs/pricing
  # https://ai.google.dev/gemini-api/docs/gemini-3
  # https://openrouter.ai/google/gemini-3.8-flash
  # https://openrouter.ai/typesafe/jev-1.13
  # https://api-docs.deepseek.com/quick_start/pricing/
  # https://api-docs.deepseek.com/news/news260910/
  # Context-qualified components keep older binaries from charging a flat GPT-6 rate.
  def prices do
    gpt_prices("gpt-6-sol", ~U[2026-09-22 00:00:00Z], [2, 10, 0.2, 2.5]) ++
      gpt_prices("gpt-6-luna", ~U[2026-09-22 00:00:00Z], [0.1, 0.5, 0.01, 0.125]) ++
      gpt_prices("gpt-6-astra", ~U[2026-09-03 00:00:00Z], [10, 50, 1, 12.5]) ++
      llm("anthropic", "claude-opus-5", ~U[2026-08-01 00:00:00Z], [5, 25, 0.5, 6.25]) ++
      llm("anthropic", "claude-sonnet-5", ~U[2026-08-01 00:00:00Z], [2, 10, 0.2, 2.5]) ++
      llm("anthropic", "claude-sonnet-4.6", ~U[2026-08-01 00:00:00Z], [3, 15, 0.3, 3.75]) ++
      llm("gemini", "gemini-3-flash-preview", ~U[2026-07-01 00:00:00Z], [0.5, 3, 0.05]) ++
      Enum.flat_map(
        [
          {"gemini-3.7-flash", ~U[2026-08-13 00:00:00Z]},
          {"gemini-3.8-flash", ~U[2026-09-02 00:00:00Z]}
        ],
        fn {model, start} ->
          Enum.flat_map([model, "google/" <> model], fn sku ->
            llm("gemini", sku, start, [0.75, 3.75, 0.075], @year_end) ++
              llm("gemini", sku, @year_end, [1.5, 7.5, 0.15])
          end)
        end
      ) ++
      Enum.flat_map(["jev-1.13", "typesafe/jev-1.13"], fn sku ->
        llm("typesafe", sku, ~U[2026-09-18 00:00:00Z], [0.042, 0])
      end) ++
      grok_prices() ++ deepseek_prices() ++ voice_prices()
  end

  def up do
    for p <- prices() do
      expires = if p.expires_at, do: "TIMESTAMPTZ '#{p.expires_at}'", else: "NULL"

      execute("""
      INSERT INTO meter_pricing_catalog
        (id,resource_kind,provider,sku,component,meter_unit,usd_micros_per_unit,
         credits_per_usd,effective_at,expires_at,version)
      VALUES ('#{p.id}','#{p.resource_kind}','#{p.provider}','#{p.sku}',
        '#{p.component}','#{p.meter_unit}',#{p.usd_micros_per_unit},1000000,
        TIMESTAMPTZ '#{p.effective_at}',#{expires},'#{p.version}')
      ON CONFLICT (id) DO NOTHING
      """)
    end
  end

  # Charges retain their original pricing evidence.
  def down, do: :ok

  defp gpt_prices(sku, start, amounts) do
    for name <- [sku, "openai/" <> sku],
        {tier, multipliers} <- [{"short_context", [1, 1, 1, 1]}, {"long_context", [2, 1.5, 2, 2]}],
        {component, {amount, multiplier}} <-
          Enum.zip(~w(input output cache_read cache_write), Enum.zip(amounts, multipliers)) do
      price(
        "llm",
        "openai",
        name,
        component <> ":" <> tier,
        "token",
        amount * multiplier,
        start,
        nil
      )
    end
  end

  defp grok_prices do
    for sku <- ~w(grok-4.6 x-ai/grok-4.6),
        {tier, multiplier} <- [{"short_context", 1}, {"long_context", 2}],
        {component, amount} <- Enum.zip(~w(input output cache_read), [2, 6, 0.5]) do
      price(
        "llm",
        "x-ai",
        sku,
        component <> ":" <> tier,
        "token",
        amount * multiplier,
        ~U[2026-08-12 00:00:00Z],
        nil
      )
    end
  end

  defp llm(provider, sku, start, amounts, finish \\ nil) do
    for {component, amount} <- Enum.zip(~w(input output cache_read cache_write), amounts),
        do: price("llm", provider, sku, component, "token", amount, start, finish)
  end

  defp deepseek_prices do
    # Peak windows are UTC weekdays, excluding Chinese public holidays.
    # Expire at year end instead of guessing the next holiday calendar.
    for date <- Date.range(~D[2026-09-10], ~D[2026-12-31]),
        {first, last, peak?} <- windows(date),
        start = DateTime.add(DateTime.new!(date, ~T[00:00:00]), first * 3600),
        finish = DateTime.add(DateTime.new!(date, ~T[00:00:00]), last * 3600),
        DateTime.compare(start, ~U[2026-09-10 04:00:00Z]) != :lt,
        row <-
          llm(
            "deepseek",
            "deepseek-flash",
            start,
            if(peak?, do: [0.3, 1.2, 0.006], else: [0.15, 0.6, 0.003]),
            finish
          ),
        do: row
  end

  defp windows(date) do
    holiday? =
      date in Date.range(~D[2026-09-25], ~D[2026-09-27]) or
        date in Date.range(~D[2026-10-01], ~D[2026-10-07])

    if Date.day_of_week(date) <= 5 and not holiday?,
      do: [{0, 1, false}, {1, 4, true}, {4, 6, false}, {6, 10, true}, {10, 24, false}],
      else: [{0, 24, false}]
  end

  defp voice_prices do
    start = ~U[2026-09-01 00:00:00Z]

    [price("voice", "openai", "gpt-live-1", "model_seconds", "second", 50_000 / 60, start, nil)] ++
      for carrier <- ~w(signal websocket),
          do:
            price(
              "voice",
              "openai",
              "gpt-live-1",
              "carrier_seconds:" <> carrier,
              "second",
              0,
              start,
              nil
            )
  end

  defp price(kind, provider, sku, component, unit, amount, start, finish) do
    %{
      id: "#{@version}:#{kind}:#{provider}:#{sku}:#{component}:#{DateTime.to_unix(start)}",
      resource_kind: kind,
      provider: provider,
      sku: sku,
      component: component,
      meter_unit: unit,
      usd_micros_per_unit: amount,
      credits_per_usd: 1_000_000,
      effective_at: start,
      expires_at: finish,
      version: @version
    }
  end
end
