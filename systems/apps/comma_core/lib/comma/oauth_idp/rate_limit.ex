defmodule Comma.OauthIdp.RateLimit do
  @moduledoc """
  Redis-owned token buckets for the OAuth IdP entry points
  (docs/identity-security.md, PR 9/10).

  Follows the `BridgeForTeams.RateLimit` contract: keys are hashed
  before leaving the process (peer IPs never appear in Redis), Redis
  unavailability **fails closed** and is observable, and there is no
  node-local fallback counter — every pod shares one bucket.

  The peer key is derived from `conn.remote_ip`, never from
  caller-controlled forwarding headers, matching the user-system RFC's
  peer-limit rule. Budgets are deliberately coarse backstops against
  abuse, not per-client fairness: the authorize endpoints see human
  browser navigation, the token endpoint sees app backends redeeming
  one code per login.
  """

  defmodule Redis do
    @moduledoc false
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :token_bucket,
      prefix: "comma:oauth-idp:v1",
      timeout: 2_000
  end

  # burst = bucket size, rate = tokens per second per peer.
  @default_policies %{
    authorize: %{burst: 30, rate: 0.5},
    token: %{burst: 60, rate: 1.0}
  }
  @zero_rate_scale 86_400

  def child_spec(_opts) do
    Redis.child_spec(url: redis_url!())
  end

  def start_link(_opts \\ []) do
    Redis.start_link(url: redis_url!())
  end

  @doc "True when a Redis URL is configured, i.e. the limiter child runs."
  @spec configured?() :: boolean()
  def configured? do
    is_binary(Application.get_env(:comma_core, :oauth_idp_rate_limit_redis_url))
  end

  @doc """
  Consumes one token from the per-peer bucket for the given endpoint.

  Returns `:allow`, `{:deny, retry_after_seconds}`, or
  `{:unavailable, retry_after_seconds}` when the decision cannot be
  made (Redis down, limiter not running, invalid policy) — callers
  must treat that as a rejection, never as a pass.
  """
  @spec check(:authorize | :token, peer :: term()) ::
          :allow | {:deny, pos_integer()} | {:unavailable, pos_integer()}
  def check(endpoint, peer) when endpoint in [:authorize, :token] do
    %{burst: burst, rate: rate} = policy(endpoint)

    if valid_policy?(burst, rate) do
      {refill_rate, scale} = scaled_rate(rate)

      case Redis.hit(digest_key({endpoint, peer}), refill_rate, burst * scale, scale) do
        {:allow, _remaining} ->
          emit(endpoint, :allow)
          :allow

        {:deny, _retry_after_ms} ->
          emit(endpoint, :deny)
          {:deny, retry_after_seconds(rate)}
      end
    else
      emit(endpoint, :unavailable)
      {:unavailable, retry_after_seconds(rate)}
    end
  rescue
    _error ->
      emit(endpoint, :unavailable)
      {:unavailable, unavailable_retry_after()}
  catch
    :exit, _reason ->
      emit(endpoint, :unavailable)
      {:unavailable, unavailable_retry_after()}
  end

  # The upper bound on the next token's arrival, independent of the
  # backend's deny payload semantics.
  defp retry_after_seconds(rate) when rate > 0, do: max(1, ceil(1 / rate))
  defp retry_after_seconds(_zero_rate), do: unavailable_retry_after()

  defp unavailable_retry_after, do: 30

  defp policy(endpoint) do
    configured = Application.get_env(:comma_core, :oauth_idp_rate_limit, [])
    Map.merge(@default_policies[endpoint], Map.new(Keyword.get(configured, endpoint, [])))
  end

  defp valid_policy?(burst, rate) do
    is_integer(burst) and burst > 0 and is_number(rate) and rate >= 0
  end

  defp scaled_rate(rate) when rate == 0 or rate == 0.0, do: {1, @zero_rate_scale}

  defp scaled_rate(rate) do
    scale = max(1, ceil(1 / rate))
    {max(1, round(rate * scale)), scale}
  end

  defp digest_key(key) do
    key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp emit(endpoint, outcome) do
    :telemetry.execute(
      [:comma_product, :oauth_idp, :rate_limit],
      %{count: 1},
      %{endpoint: endpoint, outcome: outcome}
    )
  end

  defp redis_url! do
    Application.fetch_env!(:comma_core, :oauth_idp_rate_limit_redis_url)
  end
end
