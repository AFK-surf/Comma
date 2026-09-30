defmodule Comma.Billing.PricingV1 do
  @moduledoc "First Comma billing catalog shipped with the 2026-06 billing launch."

  @effective_at ~U[2026-06-01 00:00:00Z]
  @annual_effective_at ~U[2026-09-01 00:00:00Z]
  @policy %{"llm_models" => %{"mode" => "unrestricted", "models" => []}}

  @spec catalog() :: map()
  def catalog do
    %{
      name: "comma_pricing_v1",
      provider: "stripe",
      packages: [
        package("comma_value", "Comma Value", "Comma subscription for regular personal usage."),
        package("comma_pro", "Comma Pro", "Comma subscription for heavier personal usage."),
        package("comma_max", "Comma Max", "Comma subscription for high-volume personal usage."),
        package(
          "comma_addon_4m",
          "Comma 4M Credit Pack",
          "One-time Comma credits for the current billing period."
        ),
        package(
          "comma_addon_8m",
          "Comma 8M Credit Pack",
          "One-time Comma credits for the current billing period."
        ),
        package(
          "comma_addon_20m",
          "Comma 20M Credit Pack",
          "One-time Comma credits for the current billing period."
        )
      ],
      versions: [
        version(
          "comma_value",
          "Comma Value",
          lookup_key("value_v1"),
          "subscription",
          "month",
          20_000_000,
          "current_period",
          2_000,
          "Comma Value monthly plan: 20M credits per month."
        ),
        version(
          "comma_pro",
          "Comma Pro",
          lookup_key("pro_v1"),
          "subscription",
          "month",
          60_000_000,
          "current_period",
          6_000,
          "Comma Pro monthly plan: 60M credits per month."
        ),
        version(
          "comma_max",
          "Comma Max",
          lookup_key("max_v1"),
          "subscription",
          "month",
          500_000_000,
          "current_period",
          20_000,
          "Comma Max monthly plan: 500M credits per month."
        ),
        version(
          "comma_value",
          "Comma Value",
          lookup_key("value_annual_v1"),
          "subscription",
          "year",
          20_000_000,
          "current_period",
          20_000,
          "Comma Value annual plan: billed yearly with 20M credits granted per month."
        )
        |> annual_version(),
        version(
          "comma_pro",
          "Comma Pro",
          lookup_key("pro_annual_v1"),
          "subscription",
          "year",
          60_000_000,
          "current_period",
          60_000,
          "Comma Pro annual plan: billed yearly with 60M credits granted per month."
        )
        |> annual_version(),
        version(
          "comma_max",
          "Comma Max",
          lookup_key("max_annual_v1"),
          "subscription",
          "year",
          500_000_000,
          "current_period",
          200_000,
          "Comma Max annual plan: billed yearly with 500M credits granted per month."
        )
        |> annual_version(),
        version(
          "comma_addon_4m",
          "Comma 4M Credit Pack",
          lookup_key("addon_4m_v1"),
          "one_time",
          "once",
          4_000_000,
          "current_month",
          499,
          "Comma 4M one-time credit pack for the current billing period."
        ),
        version(
          "comma_addon_8m",
          "Comma 8M Credit Pack",
          lookup_key("addon_8m_v1"),
          "one_time",
          "once",
          8_000_000,
          "current_month",
          999,
          "Comma 8M one-time credit pack for the current billing period."
        ),
        version(
          "comma_addon_20m",
          "Comma 20M Credit Pack",
          lookup_key("addon_20m_v1"),
          "one_time",
          "once",
          20_000_000,
          "current_month",
          1_999,
          "Comma 20M one-time credit pack for the current billing period."
        )
      ]
    }
  end

  # Stripe price lookup keys are provider-registered names. The prefix is
  # deploy-time configuration (`:comma_core, :stripe_lookup_key_prefix`).
  defp lookup_key(suffix) do
    prefix = Application.get_env(:comma_core, :stripe_lookup_key_prefix, "comma")
    prefix <> "_" <> suffix
  end

  defp package(code, name, description) do
    %{
      code: code,
      surface: "comma",
      name: name,
      status: "active",
      metadata: %{"description" => description}
    }
  end

  defp annual_version(version) do
    %{version | version: "2026-09-annual", effective_at: @annual_effective_at}
  end

  defp version(
         package_code,
         name,
         lookup_key,
         kind,
         billing_period,
         credits,
         grant_period,
         amount,
         description
       ) do
    %{
      package_code: package_code,
      name: name,
      version: "2026-06",
      surface: "comma",
      kind: kind,
      billing_period: billing_period,
      grant_credits: credits,
      grant_period: grant_period,
      currency: "usd",
      amount_minor: amount,
      usage_policy:
        Map.merge(@policy, %{"stripe_lookup_key" => lookup_key, "description" => description}),
      effective_at: @effective_at,
      status: "active",
      provider_lookup_key: lookup_key
    }
  end
end
