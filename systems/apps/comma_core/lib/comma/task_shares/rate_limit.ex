defmodule Comma.TaskShares.RateLimit do
  @moduledoc """
  Redis-owned token buckets for public Task Share reads.

  Follows `Comma.OauthIdp.RateLimit`: keys are hashed before they leave the
  process, every pod shares one bucket, and an undecidable request is rejected.
  One bucket limits a peer (`conn.remote_ip`, never forwarding headers); a
  second limits one share across all peers.
  """

  defmodule Redis do
    @moduledoc false
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :token_bucket,
      prefix: "comma:task-share:v1",
      timeout: 2_000
  end

  # burst = bucket size, rate = tokens per second. One page view reads the
  # summary, a few message pages, and its visible images.
  @default_policies %{
    peer: %{burst: 120, rate: 2.0},
    share: %{burst: 600, rate: 10.0}
  }
  @unavailable_retry_after 30

  def child_spec(_opts), do: Redis.child_spec(url: redis_url!())

  @doc "True when a Redis URL is configured, i.e. the limiter child runs."
  @spec configured?() :: boolean()
  def configured? do
    is_binary(Application.get_env(:comma_core, :task_share_rate_limit_redis_url))
  end

  @doc """
  Consumes one token from the peer bucket, then one from the share bucket.
  Returns `:allow`, `{:deny, retry_after}`, or `{:unavailable, retry_after}`.
  Callers must treat `:unavailable` as a rejection.
  """
  @spec check(peer :: term(), token :: String.t()) ::
          :allow | {:deny, pos_integer()} | {:unavailable, pos_integer()}
  def check(peer, token) do
    with :allow <- hit(:peer, peer) do
      hit(:share, token)
    end
  end

  defp hit(bucket, key) do
    %{burst: burst, rate: rate} = policy(bucket)

    if is_integer(burst) and burst > 0 and is_number(rate) and rate > 0 do
      scale = max(1, ceil(1 / rate))
      refill = max(1, round(rate * scale))

      case Redis.hit(digest_key({bucket, key}), refill, burst * scale, scale) do
        {:allow, _remaining} -> emit(bucket, :allow)
        {:deny, _retry_after_ms} -> emit(bucket, :deny, {:deny, max(1, ceil(1 / rate))})
      end
    else
      emit(bucket, :unavailable, {:unavailable, @unavailable_retry_after})
    end
  rescue
    _error -> emit(bucket, :unavailable, {:unavailable, @unavailable_retry_after})
  catch
    :exit, _reason -> emit(bucket, :unavailable, {:unavailable, @unavailable_retry_after})
  end

  defp policy(bucket) do
    configured = Application.get_env(:comma_core, :task_share_rate_limit, [])
    Map.merge(@default_policies[bucket], Map.new(Keyword.get(configured, bucket, [])))
  end

  defp digest_key(key) do
    key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp emit(bucket, outcome, result \\ :allow) do
    :telemetry.execute(
      [:comma_product, :task_share, :rate_limit],
      %{count: 1},
      %{kind: bucket, outcome: outcome}
    )

    result
  end

  defp redis_url!, do: Application.fetch_env!(:comma_core, :task_share_rate_limit_redis_url)
end
