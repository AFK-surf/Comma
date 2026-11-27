defmodule BridgeForTeams.TeamsPricing do
  @moduledoc "Product-owned Teams seat pricing and explicit provider synchronization."

  @package "bridge_for_teams_seat"
  @version "2026-11-quarterly"
  @lookup "bridge_for_teams_seat_quarterly_v1"

  def package, do: @package
  def version, do: @version
  def lookup_key, do: @lookup

  def catalog do
    %{
      packages: [%{code: @package, surface: "bridge", name: "Comma for Teams", status: "active"}],
      versions: [
        %{
          package_code: @package,
          version: @version,
          surface: "bridge",
          name: "Comma for Teams",
          kind: "subscription",
          billing_period: "quarter",
          grant_period: "current_period",
          grant_credits: 0,
          currency: "usd",
          amount_minor: 24_000,
          usage_policy: %{},
          provider_lookup_key: @lookup,
          effective_at: ~U[2026-11-17 00:00:00Z],
          status: "active"
        }
      ]
    }
  end

  @doc "Run explicitly after release. Dry-run reads Stripe and does not write either catalog."
  def sync(opts \\ []) do
    with {:ok, config} <- config(),
         {:ok, prices} <- config.api.list_prices(%{lookup_keys: [@lookup], limit: 2}, config.opts),
         {:ok, price} <- resolve_price(prices, config, opts),
         :ok <- if(is_nil(price) and opts[:dry_run], do: :ok, else: validate_price(price)) do
      if opts[:dry_run] do
        {:ok, %{action: if(price, do: :reuse, else: :create), lookup_key: @lookup}}
      else
        with {:ok, _} <- BillingCommerce.sync_local_pricing_catalog(catalog(), opts),
             {:ok, mapping} <-
               BillingCommerce.put_provider_price(%{
                 repo: opts[:repo],
                 package_code: @package,
                 package_version: @version,
                 provider: "stripe",
                 provider_lookup_key: @lookup,
                 provider_price_id: price["id"],
                 currency: "usd",
                 amount_minor: 24_000,
                 metadata: %{"stripe_product_id" => price["product"]}
               }) do
          {:ok, mapping}
        end
      end
    end
  end

  def config do
    case SystemsRuntime.get_env(:billing_stripe, :secret_key) do
      key when is_binary(key) and key != "" ->
        {:ok,
         %{
           api: SystemsRuntime.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI),
           opts: [api_key: key, response_as: :map]
         }}

      _ ->
        {:error, :stripe_not_configured}
    end
  end

  def validate_price(%{"active" => true, "lookup_key" => @lookup} = price),
    do: validate_terms(price)

  def validate_price(_), do: {:error, :teams_price_drift}

  def validate_terms(%{
        "currency" => "usd",
        "unit_amount" => 24_000,
        "billing_scheme" => "per_unit",
        "transform_quantity" => nil,
        "recurring" => %{"interval" => "month", "interval_count" => 3, "usage_type" => "licensed"}
      }),
      do: :ok

  def validate_terms(_), do: {:error, :teams_price_drift}

  defp resolve_price(%{"data" => [price], "has_more" => false}, _config, _opts), do: {:ok, price}

  defp resolve_price(%{"data" => [], "has_more" => false}, config, opts) do
    with {:ok,
          %{
            "data" => [
              %{
                "product" => product,
                "unit_amount" => 8_000,
                "currency" => "usd",
                "recurring" => %{"interval" => "month", "interval_count" => 1}
              }
            ],
            "has_more" => false
          }} <-
           config.api.list_prices(
             %{lookup_keys: ["bridge_for_teams_seat"], active: true, limit: 2},
             config.opts
           ) do
      if opts[:dry_run] do
        {:ok, nil}
      else
        config.api.create_price(
          %{
            product: product,
            currency: "usd",
            unit_amount: 24_000,
            recurring: %{interval: "month", interval_count: 3, usage_type: "licensed"},
            lookup_key: @lookup,
            nickname: "Comma for Teams quarterly seats",
            metadata: %{surface: "bridge", package_code: @package, package_version: @version}
          },
          Keyword.put(config.opts, :idempotency_key, "teams:price:#{@lookup}")
        )
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :teams_monthly_price_missing}
    end
  end

  defp resolve_price(_, _, _), do: {:error, :teams_price_ambiguous}
end
