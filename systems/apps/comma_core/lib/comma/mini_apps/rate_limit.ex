defmodule Comma.MiniApps.RateLimit do
  @moduledoc """
  Redis-owned token buckets for Mini App runtime calls, in the style of
  `Comma.TaskShares.RateLimit`: one bucket per peer (`conn.remote_ip`) and one
  per app across all peers. Keys are hashed before they leave the process;
  an undecidable request is rejected.

  The same Redis connection keeps each app's backend error ring
  (`record_error/3`, `errors/2`): the last 200 lines, for 15 minutes.
  It runs where `:comma_core, :task_share_rate_limit_redis_url` is set.
  """

  @prefix "comma:mini-app:v1"
  @timeout 2_000
  @log_lines 200
  @log_seconds 900

  defmodule Redis do
    @moduledoc false
    use Hammer, backend: Hammer.Redis, timeout: 2_000
  end

  @default_policies %{
    peer: %{burst: 600, rate: 10.0},
    app: %{burst: 3_000, rate: 50.0}
  }
  @unavailable_retry_after 30

  def child_spec(_opts), do: Redis.child_spec(url: redis_url!())

  def configured? do
    is_binary(SystemsRuntime.get_env(:comma_core, :task_share_rate_limit_redis_url))
  end

  @doc "`:allow`, `{:deny, retry_after}` or `{:unavailable, retry_after}`."
  def check(peer, app_id) do
    with :allow <- hit(:peer, peer) do
      hit(:app, app_id)
    end
  end

  @doc "Keeps one backend error line of `app_id`'s Version `version`."
  def record_error(app_id, version, line) when is_binary(line) do
    entry =
      Jason.encode!(%{
        "at" => SystemsClock.system_time(:second),
        "version" => version,
        "line" => String.slice(line, 0, 2_000)
      })

    key = log_key(app_id)

    Redix.pipeline(
      Redis,
      [
        ["LPUSH", key, entry],
        ["LTRIM", key, "0", Integer.to_string(@log_lines - 1)],
        ["EXPIRE", key, Integer.to_string(@log_seconds)]
      ],
      timeout: @timeout
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The kept lines of an app (of one Version when given), oldest first."
  def errors(app_id, version) do
    cutoff = SystemsClock.system_time(:second) - @log_seconds

    case Redix.command(Redis, ["LRANGE", log_key(app_id), "0", "-1"], timeout: @timeout) do
      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.flat_map(fn raw ->
           case Jason.decode(raw) do
             {:ok, %{"at" => at, "line" => line, "version" => v}}
             when is_integer(at) and at >= cutoff and (is_nil(version) or v == version) ->
               ["v#{v} #{format_time(at)} #{line}"]

             _ ->
               []
           end
         end)
         |> Enum.reverse()}

      {:error, _} ->
        {:error, :temporarily_unavailable}
    end
  rescue
    _ -> {:error, :temporarily_unavailable}
  catch
    :exit, _ -> {:error, :temporarily_unavailable}
  end

  defp format_time(at), do: at |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp log_key(app_id), do: "#{@prefix}:logs:#{app_id}"

  defp hit(bucket, key) do
    %{burst: burst, rate: rate} = policy(bucket)
    scale = max(1, ceil(1 / rate))
    refill = max(1, round(rate * scale))

    case SalixStore.RedisLimit.token_bucket(
           Redis,
           @prefix,
           digest_key({bucket, key}),
           refill,
           burst * scale,
           scale,
           @timeout
         ) do
      {:allow, _remaining} -> :allow
      {:deny, _retry_after_ms} -> {:deny, max(1, ceil(1 / rate))}
    end
  rescue
    _error -> {:unavailable, @unavailable_retry_after}
  catch
    :exit, _reason -> {:unavailable, @unavailable_retry_after}
  end

  defp policy(bucket) do
    configured = SystemsRuntime.get_env(:comma_core, :mini_app_rate_limit, [])
    Map.merge(@default_policies[bucket], Map.new(Keyword.get(configured, bucket, [])))
  end

  defp digest_key(key) do
    key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp redis_url!, do: SystemsRuntime.fetch_env!(:comma_core, :task_share_rate_limit_redis_url)
end
