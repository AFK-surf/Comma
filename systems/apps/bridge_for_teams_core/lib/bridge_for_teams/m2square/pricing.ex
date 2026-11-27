defmodule BridgeForTeams.M2square.Pricing do
  @moduledoc """
  Pure `Decimal` USD-anchored dynamic pricing for M2square Teams orders.

  All calculations avoid IEEE floating-point arithmetic. For a given country and
  seat count `n in 30..48`:

    * `usd_net = 240 * n` (USD 80/seat/month × 3 months)
    * `local_target = usd_net * (1 + markup_rate) / base_rate`
    * `EC` (`gateway_currency == "ECS"`) is pegged 1:1 to USD with `rate = 1`
      and `markup = 0`.
    * Per M2square fee rules, each order fee is rounded UP to 2 decimal places
      (`ceil(G * fee_rate, 2)`), while customer gross amount `G` is rounded UP
      to the country's currency `scale` (`0` for `CLP`, `2` for others).
    * Finds the minimum `G` at currency `scale` satisfying:
      `G - ceil(G * fee_rate, 2) >= local_target`
      (checked via exact cross-multiplication `(G - fee) * base_rate >= usd_net * (1 + markup_rate)`
      to prevent division truncation error).
  """

  @min_seats 30
  @max_seats 48
  @usd_per_seat_per_quarter 240
  @usd_minor_per_seat_per_quarter 24_000
  @fee_scale 2

  @type quote_result :: %{
          seats: integer(),
          usd_net_minor: pos_integer(),
          usd_net: String.t(),
          local_amount: Decimal.t(),
          formatted_amount: String.t(),
          fee_rate: String.t(),
          fx_rate: String.t(),
          markup_rate: String.t()
        }

  @doc "Minimum seat count allowed for M2square Teams orders."
  @spec min_seats() :: pos_integer()
  def min_seats, do: @min_seats

  @doc "Maximum seat count allowed for M2square Teams orders."
  @spec max_seats_limit() :: pos_integer()
  def max_seats_limit, do: @max_seats

  @doc """
  Computes an exact order quote for `seats` in `country_cfg`.
  """
  @spec quote_order(map(), integer(), Decimal.t() | String.t(), Decimal.t() | String.t()) ::
          {:ok, quote_result()}
          | {:error, :invalid_seats | :amount_out_of_bounds | :invalid_rate}
  def quote_order(country_cfg, seats, base_rate, markup_rate \\ "0")

  def quote_order(%{} = country_cfg, seats, base_rate, markup_rate)
      when is_integer(seats) and seats in @min_seats..@max_seats do
    with {:ok, fee_rate} <- parse_decimal(Map.get(country_cfg, :fee_rate)),
         true <- valid_fee_rate?(fee_rate),
         {:ok, min_amount} <- parse_decimal(Map.get(country_cfg, :min_amount)),
         {:ok, max_amount} <- parse_decimal(Map.get(country_cfg, :max_amount)),
         scale when is_integer(scale) and scale >= 0 <- Map.get(country_cfg, :scale),
         {:ok, effective_rate, effective_markup} <-
           effective_fx_and_markup(country_cfg, base_rate, markup_rate) do
      usd_net = Decimal.new(seats * @usd_per_seat_per_quarter)
      usd_net_minor = seats * @usd_minor_per_seat_per_quarter
      usd_target = Decimal.mult(usd_net, Decimal.add(Decimal.new(1), effective_markup))

      gross = solve_gross_for_usd_target(usd_target, effective_rate, fee_rate, scale)

      if Decimal.compare(gross, min_amount) != :lt and Decimal.compare(gross, max_amount) != :gt do
        {:ok,
         %{
           seats: seats,
           usd_net_minor: usd_net_minor,
           usd_net: format_decimal(usd_net, 2),
           local_amount: gross,
           formatted_amount: format_decimal(gross, scale),
           fee_rate: Decimal.to_string(fee_rate, :normal),
           fx_rate: Decimal.to_string(effective_rate, :normal),
           markup_rate: Decimal.to_string(effective_markup, :normal)
         }}
      else
        {:error, :amount_out_of_bounds}
      end
    else
      _ -> {:error, :invalid_rate}
    end
  end

  def quote_order(_country_cfg, _seats, _base_rate, _markup_rate) do
    {:error, :invalid_seats}
  end

  @doc """
  Solves for the minimum gross amount `G` at `scale` decimal places such that
  `G - ceil(G * fee_rate, 2) >= local_target`.
  """
  @spec gross_for_local_target(
          Decimal.t() | String.t(),
          Decimal.t() | String.t(),
          non_neg_integer()
        ) :: {:ok, Decimal.t(), String.t()} | {:error, :invalid_rate}
  def gross_for_local_target(local_target, fee_rate, scale)
      when is_integer(scale) and scale >= 0 do
    with {:ok, target} <- parse_decimal(local_target),
         true <- Decimal.compare(target, 0) != :lt,
         {:ok, fee} <- parse_decimal(fee_rate),
         true <- valid_fee_rate?(fee) do
      gross = solve_gross_for_usd_target(target, Decimal.new(1), fee, scale)
      {:ok, gross, format_decimal(gross, scale)}
    else
      _ -> {:error, :invalid_rate}
    end
  end

  def gross_for_local_target(_local_target, _fee_rate, _scale), do: {:error, :invalid_rate}

  @doc """
  Computes the maximum valid seat count (`30..48`) for `country_cfg` at the given
  `base_rate` and `markup_rate`.
  """
  @spec max_seats(map(), Decimal.t() | String.t(), Decimal.t() | String.t()) ::
          {:ok, 30..48} | {:error, :country_limit_below_minimum_seats | :invalid_rate}
  def max_seats(%{} = country_cfg, base_rate, markup_rate \\ "0") do
    case quote_order(country_cfg, @min_seats, base_rate, markup_rate) do
      {:error, :invalid_rate} ->
        {:error, :invalid_rate}

      {:error, :amount_out_of_bounds} ->
        {:error, :country_limit_below_minimum_seats}

      {:ok, _min_quote} ->
        max_valid =
          Enum.reduce_while((@min_seats + 1)..@max_seats, @min_seats, fn seats, best ->
            case quote_order(country_cfg, seats, base_rate, markup_rate) do
              {:ok, _quote} -> {:cont, seats}
              {:error, :amount_out_of_bounds} -> {:halt, best}
              {:error, _} -> {:halt, best}
            end
          end)

        {:ok, max_valid}
    end
  end

  @doc """
  Computes availability metadata for a country given its FX result and markup rate.
  Returns `{:ok, availability_map}` if `max_seats >= 30`, or `{:error, reason}`.
  """
  @spec country_availability(
          map(),
          %{rate: Decimal.t(), source: String.t()},
          String.t() | Decimal.t()
        ) ::
          {:ok, map()} | {:error, term()}
  def country_availability(%{} = country_cfg, %{rate: rate, source: source}, markup_rate \\ "0") do
    with {:ok, min_quote} <- quote_order(country_cfg, @min_seats, rate, markup_rate),
         {:ok, max_valid_seats} <- max_seats(country_cfg, rate, markup_rate) do
      {:ok,
       %{
         "code" => country_cfg.code,
         "name_en" => country_cfg.name_en,
         "name_zh" => country_cfg.name_zh,
         "currency" => country_cfg.gateway_currency,
         "display_currency" => country_cfg.display_currency,
         "scale" => country_cfg.scale,
         "min_seats" => @min_seats,
         "max_seats" => max_valid_seats,
         "sample_min_amount" => min_quote.formatted_amount,
         "fee_rate" => min_quote.fee_rate,
         "fx_rate" => min_quote.fx_rate,
         "fx_source" => source,
         "markup_rate" => min_quote.markup_rate,
         "payment_types" => country_cfg.payment_types,
         "id_types" => country_cfg.id_types
       }}
    end
  end

  @doc """
  Applies a minimum seat floor (`min_m2_seats`) to a country availability map.

  Returns:
    * `:ineligible` when `effective_min > max_seats`,
    * `{:ok, availability_map}` unchanged when `effective_min == min_seats`,
    * `{:ok, updated}` with `min_seats` raised to `effective_min` and
      `sample_min_amount` recomputed for `effective_min` seats using the
      availability map's locked quote parameters.
  """
  @spec apply_min_seats_floor(map(), integer()) :: {:ok, map()} | :ineligible
  def apply_min_seats_floor(
        %{"min_seats" => min_seats, "max_seats" => max_seats} = availability_map,
        min_m2_seats
      )
      when is_integer(min_seats) and is_integer(max_seats) and is_integer(min_m2_seats) do
    effective_min = max(min_seats, min_m2_seats)

    cond do
      effective_min > max_seats ->
        :ineligible

      effective_min == min_seats ->
        {:ok, availability_map}

      true ->
        country_stub = %{gateway_currency: availability_map["currency"]}

        with {:ok, fee_rate} <- parse_decimal(availability_map["fee_rate"]),
             true <- valid_fee_rate?(fee_rate),
             scale when is_integer(scale) and scale >= 0 <- availability_map["scale"],
             {:ok, effective_rate, effective_markup} <-
               effective_fx_and_markup(
                 country_stub,
                 availability_map["fx_rate"],
                 availability_map["markup_rate"]
               ) do
          usd_net = Decimal.new(effective_min * @usd_per_seat_per_quarter)
          usd_target = Decimal.mult(usd_net, Decimal.add(Decimal.new(1), effective_markup))
          gross = solve_gross_for_usd_target(usd_target, effective_rate, fee_rate, scale)

          {:ok,
           availability_map
           |> Map.put("min_seats", effective_min)
           |> Map.put("sample_min_amount", format_decimal(gross, scale))}
        else
          _ -> :ineligible
        end
    end
  end

  def apply_min_seats_floor(_availability_map, _min_m2_seats), do: :ineligible

  @doc "Formats a `Decimal` to a fixed-scale plain string (no scientific notation)."
  @spec format_decimal(Decimal.t(), non_neg_integer()) :: String.t()
  def format_decimal(%Decimal{} = value, 0) do
    value
    |> Decimal.round(0, :half_up)
    |> Decimal.to_string(:normal)
  end

  def format_decimal(%Decimal{} = value, scale) when is_integer(scale) and scale > 0 do
    zero_at_scale = Decimal.new(1, 0, -scale)

    value
    |> Decimal.round(scale, :half_up)
    |> Decimal.add(zero_at_scale)
    |> Decimal.to_string(:normal)
  end

  defp effective_fx_and_markup(%{gateway_currency: "ECS"}, _base_rate, _markup_rate) do
    {:ok, Decimal.new(1), Decimal.new(0)}
  end

  defp effective_fx_and_markup(_country_cfg, base_rate, markup_rate) do
    with {:ok, rate} <- parse_decimal(base_rate),
         true <- Decimal.gt?(rate, 0),
         {:ok, markup} <- parse_decimal(markup_rate),
         true <- Decimal.compare(markup, 0) != :lt do
      {:ok, rate, markup}
    else
      _ -> {:error, :invalid_rate}
    end
  end

  # Computes minimum G at `scale` such that:
  #   (G - ceil(G * fee_rate, 2)) * effective_rate >= usd_target
  # Starts from a floor estimate so stepping up by 10^(-scale) never overshoots.
  defp solve_gross_for_usd_target(usd_target, effective_rate, fee_rate, scale) do
    one_minus_fee = Decimal.sub(Decimal.new(1), fee_rate)
    denom = Decimal.mult(effective_rate, one_minus_fee)
    g0 = Decimal.div(usd_target, denom) |> Decimal.round(scale, :floor)
    step = Decimal.new(1, 1, -scale)

    step_until_sufficient(g0, step, usd_target, effective_rate, fee_rate)
  end

  defp step_until_sufficient(g, step, usd_target, effective_rate, fee_rate) do
    fee = Decimal.mult(g, fee_rate) |> Decimal.round(@fee_scale, :ceiling)
    net_local = Decimal.sub(g, fee)
    net_usd = Decimal.mult(net_local, effective_rate)

    if Decimal.compare(net_usd, usd_target) != :lt do
      g
    else
      step_until_sufficient(Decimal.add(g, step), step, usd_target, effective_rate, fee_rate)
    end
  end

  defp valid_fee_rate?(%Decimal{} = fee_rate) do
    Decimal.compare(fee_rate, 0) != :lt and Decimal.lt?(fee_rate, 1)
  end

  defp parse_decimal(%Decimal{} = value), do: {:ok, value}
  defp parse_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp parse_decimal(_), do: :error
end
