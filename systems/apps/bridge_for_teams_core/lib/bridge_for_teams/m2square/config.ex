defmodule BridgeForTeams.M2square.Config do
  @moduledoc """
  Runtime configuration and dynamic country availability for M2square Teams billing.

  All four supported LATAM countries (`PE`, `EC`, `BR`, `CL`) default to
  `enabled: false` and must be explicitly enabled via `:bridge_for_teams_core, :m2square`
  (or `billing.m2square` in `config.json`).
  """

  alias BridgeForTeams.M2square.FX
  alias BridgeForTeams.M2square.Pricing
  alias BridgeForTeams.Salix.Client, as: SalixClient

  @country_order ["PE", "EC", "BR", "CL"]
  @max_fx_hard_ttl_ms 86_400_000

  @supported_payment_types %{
    "PE" => ["NET_BANKING", "TD", "TC", "CASH"],
    "EC" => ["NET_BANKING", "CASH"],
    "BR" => ["PIX"],
    "CL" => ["NET_BANKING", "TD", "TC", "CASH"]
  }

  @default_payment_types %{
    "PE" => ["NET_BANKING", "TD", "TC"],
    "EC" => ["NET_BANKING"],
    "BR" => ["PIX"],
    "CL" => ["NET_BANKING", "TD", "TC"]
  }

  @supported_id_types %{
    "PE" => ["DNI", "CE", "RUC", "PAS"],
    "EC" => ["CI", "RUC", "PAS"],
    "BR" => ["CPF"],
    "CL" => ["RUT", "PP"]
  }

  @top_level_keys %{
    :base_url => :base_url,
    "base_url" => :base_url,
    :mch_id => :mch_id,
    "mch_id" => :mch_id,
    :secret_key => :secret_key,
    "secret_key" => :secret_key,
    :client => :client,
    "client" => :client,
    :fx_provider => :fx_provider,
    "fx_provider" => :fx_provider,
    :fx_stripe_version => :fx_stripe_version,
    "fx_stripe_version" => :fx_stripe_version,
    :fx_soft_ttl_ms => :fx_soft_ttl_ms,
    "fx_soft_ttl_ms" => :fx_soft_ttl_ms,
    :fx_hard_ttl_ms => :fx_hard_ttl_ms,
    "fx_hard_ttl_ms" => :fx_hard_ttl_ms,
    :fx_failure_backoff_ms => :fx_failure_backoff_ms,
    "fx_failure_backoff_ms" => :fx_failure_backoff_ms,
    :markup_rate => :markup_rate,
    "markup_rate" => :markup_rate,
    :no_pay_page => :no_pay_page,
    "no_pay_page" => :no_pay_page,
    :req_options => :req_options,
    "req_options" => :req_options,
    :fx_req_options => :fx_req_options,
    "fx_req_options" => :fx_req_options
  }

  @country_keys %{
    :code => :code,
    "code" => :code,
    :name_en => :name_en,
    "name_en" => :name_en,
    :name_zh => :name_zh,
    "name_zh" => :name_zh,
    :enabled => :enabled,
    "enabled" => :enabled,
    :gateway_currency => :gateway_currency,
    "gateway_currency" => :gateway_currency,
    :display_currency => :display_currency,
    "display_currency" => :display_currency,
    :scale => :scale,
    "scale" => :scale,
    :min_amount => :min_amount,
    "min_amount" => :min_amount,
    :max_amount => :max_amount,
    "max_amount" => :max_amount,
    :fee_rate => :fee_rate,
    "fee_rate" => :fee_rate,
    :payment_types => :payment_types,
    "payment_types" => :payment_types,
    :id_types => :id_types,
    "id_types" => :id_types,
    :brazil_doc_type => :brazil_doc_type,
    "brazil_doc_type" => :brazil_doc_type,
    :extra_pay_fields => :extra_pay_fields,
    "extra_pay_fields" => :extra_pay_fields,
    :payment_method => :payment_method,
    "payment_method" => :payment_method
  }

  @default_config %{
    base_url: "https://latinapi.m2square.xyz/gateway/base/biz",
    mch_id: nil,
    secret_key: nil,
    client: BridgeForTeams.M2square.HTTP,
    fx_provider: BridgeForTeams.M2square.FX.StripeQuotes,
    fx_stripe_version: "2026-09-30.preview",
    fx_soft_ttl_ms: 3_600_000,
    fx_hard_ttl_ms: 86_400_000,
    fx_failure_backoff_ms: 30_000,
    markup_rate: "0",
    no_pay_page: "false",
    countries: %{
      "PE" => %{
        code: "PE",
        name_en: "Peru",
        name_zh: "秘鲁",
        enabled: false,
        gateway_currency: "PEN",
        display_currency: "PEN",
        scale: 2,
        min_amount: "1",
        max_amount: "40000",
        fee_rate: "0.04",
        payment_types: ["NET_BANKING", "TD", "TC"],
        id_types: ["DNI", "CE", "RUC", "PAS"]
      },
      "EC" => %{
        code: "EC",
        name_en: "Ecuador",
        name_zh: "厄瓜多尔",
        enabled: false,
        gateway_currency: "ECS",
        display_currency: "USD",
        scale: 2,
        min_amount: "6",
        max_amount: "10000",
        fee_rate: "0.055",
        payment_types: ["NET_BANKING"],
        id_types: ["CI", "RUC", "PAS"]
      },
      "BR" => %{
        code: "BR",
        name_en: "Brazil",
        name_zh: "巴西",
        enabled: false,
        gateway_currency: "BRL",
        display_currency: "BRL",
        scale: 2,
        min_amount: "10",
        max_amount: "50000",
        fee_rate: "0.04",
        payment_types: ["PIX"],
        id_types: ["CPF"],
        brazil_doc_type: "PIX",
        extra_pay_fields: %{}
      },
      "CL" => %{
        code: "CL",
        name_en: "Chile",
        name_zh: "智利",
        enabled: false,
        gateway_currency: "CLP",
        display_currency: "CLP",
        scale: 0,
        min_amount: "1000",
        max_amount: "8000000",
        fee_rate: "0.04",
        payment_types: ["NET_BANKING", "TD", "TC"],
        id_types: ["RUT", "PP"],
        payment_method: "CHECKOUT_URL"
      }
    }
  }

  @doc "Returns the default M2square configuration map."
  @spec defaults() :: map()
  def defaults, do: @default_config

  @doc "Returns the fixed display order of supported M2square country codes."
  @spec country_order() :: [String.t()]
  def country_order, do: @country_order

  @doc """
  Returns the static catalog of supported M2square countries in fixed display order,
  including `supported_payment_types`, `default_payment_types`, and `supported_id_types`.
  """
  @spec catalog() :: [map()]
  def catalog do
    Enum.map(@country_order, fn code ->
      base = Map.fetch!(@default_config.countries, code)

      %{
        code: code,
        name_en: base.name_en,
        name_zh: base.name_zh,
        gateway_currency: base.gateway_currency,
        display_currency: base.display_currency,
        scale: base.scale,
        supported_payment_types: Map.fetch!(@supported_payment_types, code),
        default_payment_types: Map.fetch!(@default_payment_types, code),
        supported_id_types: Map.fetch!(@supported_id_types, code)
      }
    end)
  end

  @doc """
  Returns the local M2square configuration by deep-merging defaults with
  `:bridge_for_teams_core, :m2square` runtime configuration.

  Purely local (zero `:erpc` / zero S3) — safe for webhooks, reconciliation,
  return-page verification, and FX resolution.
  """
  @spec get() :: map()
  def get do
    override =
      case SystemsRuntime.get_env(:bridge_for_teams_core, :m2square, %{}) do
        %{} = map -> map
        kw when is_list(kw) -> Map.new(kw)
        _ -> %{}
      end

    merge_config(@default_config, override)
  end

  @doc """
  Returns the effective M2square configuration for new-order admission by
  overlaying authoritative Salix Console toggles (`Salix.Control.M2squareSettings`)
  onto local `get/0`.

  Strictly fail-closed: when Console settings are `:unconfigured`, unavailable,
  invalid, or the Salix client does not export `get_m2square_settings/0`, all
  four countries are forced to `enabled: false`.
  """
  @spec effective_config() :: map()
  def effective_config do
    cfg = get()

    case SalixClient.call_optional(:get_m2square_settings, []) do
      {:ok, {:configured, %{} = console_countries}} ->
        updated_countries =
          Map.new(cfg.countries, fn {code, base_country} ->
            {code, apply_console_country(code, base_country, Map.get(console_countries, code))}
          end)

        Map.put(cfg, :countries, updated_countries)

      _unconfigured_or_error ->
        disable_all_countries(cfg)
    end
  end

  @doc "Returns `true` when both `mch_id` and `secret_key` are configured non-empty strings."
  @spec credentials_configured?() :: boolean()
  def credentials_configured?, do: credentials_configured?(get())

  @doc "Returns `true` when both `mch_id` and `secret_key` are configured on `cfg`."
  @spec credentials_configured?(map()) :: boolean()
  def credentials_configured?(%{} = cfg) do
    non_empty_binary?(cfg.mch_id) and non_empty_binary?(cfg.secret_key)
  end

  @doc "Looks up a supported country configuration by ISO-3166-1 alpha-2 code (local)."
  @spec country(binary()) :: {:ok, map()} | {:error, :unsupported_country}
  def country(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    case Map.fetch(get().countries, normalized) do
      {:ok, country_cfg} -> {:ok, country_cfg}
      :error -> {:error, :unsupported_country}
    end
  end

  def country(_), do: {:error, :unsupported_country}

  @doc "Looks up an enabled country from an already-resolved `effective_config/0` map."
  @spec enabled_country(map(), term()) ::
          {:ok, map()} | {:error, :unsupported_country | :m2square_country_disabled}
  def enabled_country(%{} = cfg, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    case Map.fetch(cfg.countries, normalized) do
      {:ok, %{enabled: true} = country_cfg} -> {:ok, country_cfg}
      {:ok, _disabled} -> {:error, :m2square_country_disabled}
      :error -> {:error, :unsupported_country}
    end
  end

  def enabled_country(_cfg, _code), do: {:error, :unsupported_country}

  @doc """
  Returns the currently available countries in fixed order `["PE", "EC", "BR", "CL"]`.

  Calls `effective_config/0` once and fixes a single `required_until_ms` deadline
  (default `now + 3_600_000`) shared across all four countries so every returned
  country's FX rate remains within its 24h hard TTL for the entire 1-hour quote window.
  """
  @spec available_countries(keyword()) :: [map()]
  def available_countries(opts \\ []) when is_list(opts) do
    cfg = effective_config()

    required_until_ms =
      Keyword.get_lazy(opts, :required_until_ms, fn ->
        SystemsClock.monotonic_time(:millisecond) + 3_600_000
      end)

    if credentials_configured?(cfg) do
      Enum.flat_map(@country_order, fn code ->
        country_cfg = Map.fetch!(cfg.countries, code)

        if country_cfg.enabled == true do
          with {:ok, fx_info} <-
                 FX.rate_for_country(country_cfg, required_until_ms: required_until_ms),
               {:ok, availability} <-
                 Pricing.country_availability(country_cfg, fx_info, cfg.markup_rate) do
            [availability]
          else
            _ -> []
          end
        else
          []
        end
      end)
    else
      []
    end
  end

  defp disable_all_countries(cfg) do
    disabled =
      Map.new(cfg.countries, fn {code, country_cfg} ->
        {code, Map.put(country_cfg, :enabled, false)}
      end)

    Map.put(cfg, :countries, disabled)
  end

  defp apply_console_country(code, base_country, %{
         "enabled" => enabled,
         "payment_types" => payment_types
       })
       when is_boolean(enabled) and is_list(payment_types) do
    supported = Map.fetch!(@supported_payment_types, code)
    effective_payment_types = Enum.filter(supported, &(&1 in payment_types))
    effective_enabled = enabled and effective_payment_types != []

    effective_id_types =
      if code == "EC" and "NET_BANKING" not in effective_payment_types do
        Enum.filter(base_country.id_types, &(&1 in ["CI", "RUC"]))
      else
        base_country.id_types
      end

    base_country
    |> Map.put(:enabled, effective_enabled)
    |> Map.put(:payment_types, effective_payment_types)
    |> Map.put(:id_types, effective_id_types)
  end

  defp apply_console_country(_code, base_country, _invalid_or_missing) do
    Map.put(base_country, :enabled, false)
  end

  defp merge_config(base, override) do
    top_updates =
      Enum.reduce(override, %{}, fn {key, value}, acc ->
        case Map.fetch(@top_level_keys, key) do
          {:ok, :fx_hard_ttl_ms} ->
            clamped =
              if is_integer(value) and value > 0 do
                min(value, @max_fx_hard_ttl_ms)
              else
                @max_fx_hard_ttl_ms
              end

            Map.put(acc, :fx_hard_ttl_ms, clamped)

          {:ok, atom_key} ->
            Map.put(acc, atom_key, value)

          :error ->
            acc
        end
      end)

    countries_override =
      case Map.get(override, :countries) || Map.get(override, "countries") do
        %{} = map -> map
        _ -> %{}
      end

    merged_countries =
      Map.new(base.countries, fn {code, default_country} ->
        country_override =
          Map.get(countries_override, code) ||
            Map.get(countries_override, String.downcase(code)) ||
            find_atom_country(countries_override, code) ||
            %{}

        {code, merge_country(default_country, country_override)}
      end)

    base
    |> Map.merge(top_updates)
    |> Map.put(:countries, merged_countries)
  end

  defp merge_country(base_country, override) when is_list(override) do
    merge_country(base_country, Map.new(override))
  end

  defp merge_country(base_country, %{} = override) do
    updates =
      Enum.reduce(override, %{}, fn {key, value}, acc ->
        case Map.fetch(@country_keys, key) do
          {:ok, :extra_pay_fields} when is_map(value) ->
            Map.put(acc, :extra_pay_fields, stringify_keys(value))

          {:ok, atom_key} ->
            Map.put(acc, atom_key, value)

          :error ->
            acc
        end
      end)

    Map.merge(base_country, updates)
  end

  defp merge_country(base_country, _), do: base_country

  defp find_atom_country(countries_map, code) do
    Enum.find_value(countries_map, fn
      {k, v} when is_atom(k) ->
        if String.upcase(Atom.to_string(k)) == code, do: v

      _ ->
        nil
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
end
