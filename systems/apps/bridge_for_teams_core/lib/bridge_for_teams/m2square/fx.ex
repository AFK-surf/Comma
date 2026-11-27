defmodule BridgeForTeams.M2square.FX.Provider do
  @moduledoc """
  Behaviour for FX rate providers returning USD per 1 unit of each local currency.
  """

  @callback fetch_usd_base_rates(currencies :: [String.t()], opts :: keyword()) ::
              {:ok, %{String.t() => Decimal.t()}} | {:error, term()}
end

defmodule BridgeForTeams.M2square.FX.StripeQuotes do
  @moduledoc """
  Default FX provider backed by Stripe's FX Quotes preview API
  (`POST https://api.stripe.com/v1/fx_quotes`).

  Decodes response bodies with `Jason.decode(raw, floats: :decimals)` so no
  FX rate passes through IEEE 754 floats.
  """

  @behaviour BridgeForTeams.M2square.FX.Provider

  @default_url "https://api.stripe.com/v1/fx_quotes"
  @connect_timeout_ms 3_000
  @receive_timeout_ms 5_000

  @impl true
  def fetch_usd_base_rates(currencies, opts \\ []) when is_list(currencies) do
    secret_key =
      Keyword.get(opts, :secret_key) || SystemsRuntime.get_env(:billing_stripe, :secret_key)

    if not (is_binary(secret_key) and String.trim(secret_key) != "") do
      {:error, :stripe_secret_key_missing}
    else
      url = Keyword.get(opts, :url, @default_url)
      stripe_version = Keyword.get(opts, :stripe_version, "2026-09-30.preview")
      normalized_currencies = Enum.map(currencies, &String.upcase/1)

      form_params =
        [{"to_currency", "usd"}, {"lock_duration", "none"}] ++
          Enum.map(normalized_currencies, &{"from_currencies[]", String.downcase(&1)})

      req_opts =
        [
          headers: [
            {"content-type", "application/x-www-form-urlencoded"},
            {"authorization", "Bearer " <> secret_key},
            {"stripe-version", stripe_version}
          ],
          body: URI.encode_query(form_params),
          decode_body: false,
          retry: false,
          connect_options: [timeout: @connect_timeout_ms],
          receive_timeout: @receive_timeout_ms
        ]
        |> Keyword.merge(Keyword.get(opts, :req_options, []))

      case Req.post(url, req_opts) do
        {:ok, %Req.Response{status: 200, body: raw_body}} when is_binary(raw_body) ->
          decode_rates(raw_body, normalized_currencies)

        {:ok, %Req.Response{status: status}} ->
          {:error, {:fx_http_error, status}}

        {:error, reason} ->
          {:error, {:fx_transport_error, reason}}
      end
    end
  end

  defp decode_rates(raw_body, currencies) do
    case Jason.decode(raw_body, floats: :decimals) do
      {:ok, %{"rates" => %{} = rates_map}} ->
        extract_currencies(rates_map, currencies)

      {:ok, _other} ->
        {:error, :invalid_fx_response}

      {:error, _reason} ->
        {:error, :invalid_fx_json}
    end
  end

  defp extract_currencies(rates_map, currencies) do
    Enum.reduce_while(currencies, {:ok, %{}}, fn ccy, {:ok, acc} ->
      entry = Map.get(rates_map, String.downcase(ccy)) || Map.get(rates_map, ccy)

      with %{"rate_details" => %{"base_rate" => raw_rate}} <- entry,
           {:ok, rate} <- parse_positive_decimal(raw_rate) do
        {:cont, {:ok, Map.put(acc, ccy, rate)}}
      else
        _ -> {:halt, {:error, {:missing_fx_rate, ccy}}}
      end
    end)
  end

  defp parse_positive_decimal(%Decimal{} = value) do
    if Decimal.gt?(value, 0), do: {:ok, value}, else: :error
  end

  defp parse_positive_decimal(value) when is_integer(value) and value > 0 do
    {:ok, Decimal.new(value)}
  end

  defp parse_positive_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = d, ""} -> parse_positive_decimal(d)
      _ -> :error
    end
  end

  defp parse_positive_decimal(_), do: :error
end

defmodule BridgeForTeams.M2square.FX do
  @moduledoc """
  Single-flight cached FX rate resolver backed by `BridgeForTeams.Cache` and
  `BridgeForTeams.TaskSupervisor`.

  Behavior:
    * `ECS` (Ecuador) returns `{:ok, %{rate: Decimal.new(1), source: "usd_peg"}}`
      immediately without consulting any external FX provider.
    * Other currencies (`PEN`, `BRL`, `CLP`) use node-local `BridgeForTeams.Cache`
      with a 24h hard TTL, 1h soft TTL (triggers one async single-flight refresh
      under `BridgeForTeams.TaskSupervisor`), and 30s failure backoff.
    * All timestamps use `SystemsClock.monotonic_time(:millisecond)`. No
      background polling GenServer is started.
  """

  alias BridgeForTeams.Cache
  alias BridgeForTeams.M2square.Config

  @rates_key {:m2square_fx, :rates}
  @backoff_key {:m2square_fx, :backoff}
  @inflight_key {:m2square_fx, :inflight}
  @waiter_tag {:m2square_fx, :waiter}
  @inflight_lease_ms 15_000
  @waiter_timeout_ms 5_000
  @max_fx_hard_ttl_ms 86_400_000
  @non_usd_currencies ["BRL", "CLP", "PEN"]

  @doc """
  Returns `{:ok, %{rate: Decimal.t(), source: String.t()}}` for `country_cfg`,
  or `{:error, :fx_rate_unavailable}`.

  Options:
    * `:min_remaining_ms` — minimum remaining lifetime required before the 24h hard TTL (default `0`).
    * `:required_until_ms` — explicit monotonic millisecond deadline the cached/fetched rate must remain valid until (overrides `:min_remaining_ms`).
  """
  @spec rate_for_country(map(), keyword()) ::
          {:ok, %{rate: Decimal.t(), source: String.t()}} | {:error, term()}
  def rate_for_country(country_cfg, opts \\ [])

  def rate_for_country(%{gateway_currency: "ECS"}, _opts) do
    {:ok, %{rate: Decimal.new(1), source: "usd_peg"}}
  end

  def rate_for_country(%{gateway_currency: currency}, opts)
      when is_binary(currency) and is_list(opts) do
    rate_for_currency(String.upcase(currency), opts)
  end

  def rate_for_country(_, _opts), do: {:error, :fx_rate_unavailable}

  @doc "Returns the cached or freshly fetched USD base rate for a currency code."
  @spec rate_for_currency(String.t(), keyword()) ::
          {:ok, %{rate: Decimal.t(), source: String.t()}} | {:error, term()}
  def rate_for_currency(currency, opts \\ [])

  def rate_for_currency("ECS", _opts) do
    {:ok, %{rate: Decimal.new(1), source: "usd_peg"}}
  end

  def rate_for_currency(currency, opts) when is_binary(currency) and is_list(opts) do
    cfg = Config.get()
    now = now_ms()

    required_until_ms =
      Keyword.get_lazy(opts, :required_until_ms, fn ->
        now + Keyword.get(opts, :min_remaining_ms, 0)
      end)

    case Cache.get(@rates_key) do
      {:ok, {rates_map, fetched_at_ms, source}} ->
        if cache_eligible?(fetched_at_ms, cfg, now, required_until_ms) do
          if now - fetched_at_ms >= cfg.fx_soft_ttl_ms do
            maybe_trigger_async_refresh(cfg, now)
          end

          lookup_currency(rates_map, currency, source)
        else
          if in_failure_backoff?(cfg, now) do
            {:error, :fx_rate_unavailable}
          else
            fetch_sync(cfg, currency, now, required_until_ms)
          end
        end

      _miss ->
        if in_failure_backoff?(cfg, now) do
          {:error, :fx_rate_unavailable}
        else
          fetch_sync(cfg, currency, now, required_until_ms)
        end
    end
  end

  @doc "Clears cached FX rates, failure backoff, and in-flight markers (primarily for tests)."
  @spec clear_cache() :: :ok
  def clear_cache do
    Cache.delete(@rates_key)
    Cache.delete(@backoff_key)
    Cache.delete(@inflight_key)

    try do
      SystemsRuntime.ETS.match_delete(Cache, {{@waiter_tag, :_, :_}, :_})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp effective_hard_ttl_ms(%{fx_hard_ttl_ms: val}) when is_integer(val) and val > 0 do
    min(val, @max_fx_hard_ttl_ms)
  end

  defp effective_hard_ttl_ms(_), do: @max_fx_hard_ttl_ms

  defp cache_eligible?(fetched_at_ms, cfg, current_now, required_until_ms) do
    hard_ttl = effective_hard_ttl_ms(cfg)
    current_now - fetched_at_ms < hard_ttl and fetched_at_ms + hard_ttl >= required_until_ms
  end

  defp maybe_trigger_async_refresh(cfg, now) do
    unless in_failure_backoff?(cfg, now) or inflight_active?(now) do
      _ =
        SystemsRuntime.TaskSupervisor.start_child(BridgeForTeams.TaskSupervisor, fn ->
          case claim_or_join_inflight(now_ms()) do
            {:leader, ref} -> run_leader_fetch(cfg, ref)
            _ -> :ok
          end
        end)
    end
  end

  defp fetch_sync(cfg, currency, now, required_until_ms) do
    case claim_or_join_inflight(now) do
      {:leader, ref} ->
        case run_leader_fetch(cfg, ref) do
          {:ok, rates_map, fetched_at_ms, source} ->
            if cache_eligible?(fetched_at_ms, cfg, now_ms(), required_until_ms) do
              lookup_currency(rates_map, currency, source)
            else
              {:error, :fx_rate_unavailable}
            end

          {:error, _} ->
            {:error, :fx_rate_unavailable}
        end

      {:waiter, ref, leader_pid} ->
        wait_for_leader(cfg, currency, ref, leader_pid, required_until_ms)

      :retry ->
        cached_rate_for_deadline(cfg, currency, required_until_ms)
    end
  end

  defp cached_rate_for_deadline(cfg, currency, required_until_ms) do
    now = now_ms()

    case Cache.get(@rates_key) do
      {:ok, {rates_map, fetched_at_ms, source}} ->
        if cache_eligible?(fetched_at_ms, cfg, now, required_until_ms) do
          lookup_currency(rates_map, currency, source)
        else
          {:error, :fx_rate_unavailable}
        end

      _ ->
        {:error, :fx_rate_unavailable}
    end
  end

  defp run_leader_fetch(cfg, ref) do
    result =
      try do
        fetch_and_store(cfg)
      rescue
        _ -> {:error, :fx_rate_unavailable}
      catch
        _, _ -> {:error, :fx_rate_unavailable}
      end

    notify_and_release_inflight(ref, result)
    result
  end

  defp wait_for_leader(cfg, currency, ref, leader_pid, required_until_ms) do
    mref = Process.monitor(leader_pid)
    waiter_key = {@waiter_tag, ref, self()}

    try do
      register_waiter(waiter_key)

      case cached_rate_for_deadline(cfg, currency, required_until_ms) do
        {:ok, _} = hit ->
          hit

        {:error, _} ->
          receive do
            {:m2square_fx_done, ^ref, {:ok, _rates_map, _fetched_at_ms, _source}} ->
              cached_rate_for_deadline(cfg, currency, required_until_ms)

            {:m2square_fx_done, ^ref, _err} ->
              {:error, :fx_rate_unavailable}

            {:DOWN, ^mref, :process, ^leader_pid, _reason} ->
              cached_rate_for_deadline(cfg, currency, required_until_ms)
          after
            SystemsClock.timeout(@waiter_timeout_ms) ->
              {:error, :fx_rate_unavailable}
          end
      end
    after
      Process.demonitor(mref, [:flush])
      unregister_waiter(waiter_key)
    end
  end

  defp fetch_and_store(cfg) do
    provider = cfg.fx_provider
    opts = [stripe_version: cfg.fx_stripe_version, req_options: Map.get(cfg, :fx_req_options, [])]

    case provider.fetch_usd_base_rates(@non_usd_currencies, opts) do
      {:ok, %{} = rates} ->
        normalized = normalize_rates(rates)

        if map_size(normalized) > 0 do
          fetched_at = now_ms()
          source = fx_source_name(provider)
          Cache.put(@rates_key, {normalized, fetched_at, source}, ttl: effective_hard_ttl_ms(cfg))
          Cache.delete(@backoff_key)
          {:ok, normalized, fetched_at, source}
        else
          record_failure_backoff(cfg)
          {:error, :fx_rate_unavailable}
        end

      {:error, reason} ->
        record_failure_backoff(cfg)
        {:error, reason}
    end
  rescue
    _ ->
      record_failure_backoff(cfg)
      {:error, :fx_rate_unavailable}
  end

  defp normalize_rates(rates) do
    Enum.reduce(rates, %{}, fn {ccy, raw_rate}, acc ->
      case parse_positive_decimal(raw_rate) do
        {:ok, dec} -> Map.put(acc, String.upcase(to_string(ccy)), dec)
        :error -> acc
      end
    end)
  end

  defp lookup_currency(rates_map, currency, source) do
    case Map.fetch(rates_map, currency) do
      {:ok, %Decimal{} = rate} -> {:ok, %{rate: rate, source: source}}
      _ -> {:error, :fx_rate_unavailable}
    end
  end

  defp in_failure_backoff?(cfg, now) do
    case Cache.get(@backoff_key) do
      {:ok, failed_at_ms} when is_integer(failed_at_ms) ->
        now - failed_at_ms < cfg.fx_failure_backoff_ms

      _ ->
        false
    end
  end

  defp record_failure_backoff(cfg) do
    Cache.put(@backoff_key, now_ms(), ttl: cfg.fx_failure_backoff_ms)
  end

  defp inflight_active?(now) do
    evict_expired_inflight(now)

    case SystemsRuntime.ETS.lookup(Cache, @inflight_key) do
      [{@inflight_key, _ref, leader_pid, expires_at}] when now < expires_at ->
        Process.alive?(leader_pid)

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp claim_or_join_inflight(now) do
    evict_expired_inflight(now)
    ref = make_ref()

    if SystemsRuntime.ETS.insert_new(
         Cache,
         {@inflight_key, ref, self(), now + @inflight_lease_ms}
       ) do
      {:leader, ref}
    else
      case SystemsRuntime.ETS.lookup(Cache, @inflight_key) do
        [{@inflight_key, existing_ref, leader_pid, _expires_at}] ->
          {:waiter, existing_ref, leader_pid}

        _ ->
          :retry
      end
    end
  rescue
    ArgumentError -> {:leader, make_ref()}
  end

  defp evict_expired_inflight(now) do
    case SystemsRuntime.ETS.lookup(Cache, @inflight_key) do
      [{@inflight_key, ref, leader_pid, expires_at}] ->
        if now >= expires_at or not Process.alive?(leader_pid) do
          SystemsRuntime.ETS.match_delete(Cache, {@inflight_key, ref, :_, :_})
        end

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp register_waiter(waiter_key) do
    SystemsRuntime.ETS.insert(Cache, {waiter_key, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp unregister_waiter(waiter_key) do
    SystemsRuntime.ETS.delete(Cache, waiter_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp notify_and_release_inflight(ref, result) do
    try do
      SystemsRuntime.ETS.match_delete(Cache, {@inflight_key, ref, :_, :_})

      waiters = SystemsRuntime.ETS.match_object(Cache, {{@waiter_tag, ref, :_}, :_})
      SystemsRuntime.ETS.match_delete(Cache, {{@waiter_tag, ref, :_}, :_})

      Enum.each(waiters, fn {{@waiter_tag, ^ref, pid}, _} ->
        send(pid, {:m2square_fx_done, ref, result})
      end)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp fx_source_name(BridgeForTeams.M2square.FX.StripeQuotes), do: "stripe_fx_quotes"

  defp fx_source_name(provider) when is_atom(provider) do
    if function_exported?(provider, :source_name, 0) do
      provider.source_name()
    else
      "stripe_fx_quotes"
    end
  end

  defp parse_positive_decimal(%Decimal{} = d) do
    if Decimal.gt?(d, 0), do: {:ok, d}, else: :error
  end

  defp parse_positive_decimal(v) when is_binary(v) do
    case Decimal.parse(String.trim(v)) do
      {%Decimal{} = d, ""} -> parse_positive_decimal(d)
      _ -> :error
    end
  end

  defp parse_positive_decimal(_), do: :error

  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
