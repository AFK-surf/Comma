defmodule BridgeForTeams.RateLimit do
  @moduledoc """
  Redis-owned token buckets for magic-link abuse limits.

  Keys are hashed before leaving the process, so requester IPs and email
  addresses do not appear in Redis. Redis unavailability fails closed and is
  observable; this module never falls back to a node-local counter.
  """

  defmodule Redis do
    @moduledoc false
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :token_bucket,
      prefix: "bft:magic-link:v1",
      timeout: 2_000
  end

  @default_burst 60
  @default_rate 1.0
  @zero_rate_scale 86_400

  def child_spec(_opts) do
    Redis.child_spec(url: redis_url())
  end

  def start_link(_opts \\ []) do
    Redis.start_link(url: redis_url())
  end

  @spec hit(term(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, :rate_limited | :rate_limiter_unavailable}
  def hit(key, cost \\ 1, opts \\ []) do
    burst = Keyword.get(opts, :burst, @default_burst)
    rate = Keyword.get(opts, :rate, @default_rate)

    with :ok <- validate(burst, rate, cost) do
      {refill_rate, scale} = scaled_rate(rate)

      result =
        Redis.hit(
          digest_key(key),
          refill_rate,
          burst * scale,
          cost * scale
        )

      case result do
        {:allow, remaining} ->
          emit(:allow)
          {:ok, div(remaining, scale)}

        {:deny, _retry_after} ->
          emit(:deny)
          {:error, :rate_limited}
      end
    end
  rescue
    _error ->
      emit(:unavailable)
      {:error, :rate_limiter_unavailable}
  catch
    :exit, _reason ->
      emit(:unavailable)
      {:error, :rate_limiter_unavailable}
  end

  defp scaled_rate(rate) when rate == 0 or rate == 0.0, do: {1, @zero_rate_scale}

  defp scaled_rate(rate) do
    scale = max(1, ceil(1 / rate))
    {max(1, round(rate * scale)), scale}
  end

  defp validate(burst, rate, cost)
       when is_integer(burst) and burst > 0 and is_number(rate) and rate >= 0 and
              is_integer(cost) and cost > 0,
       do: :ok

  defp validate(_burst, _rate, _cost), do: {:error, :rate_limiter_unavailable}

  defp digest_key(key) do
    key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp emit(outcome) do
    :telemetry.execute(
      [:bridge_for_teams, :rate_limit, :decision],
      %{count: 1},
      %{policy: :magic_link, outcome: outcome}
    )
  end

  defp redis_url do
    Application.fetch_env!(:bridge_for_teams_core, :rate_limit_redis_url)
  end
end
