defmodule SalixStore.SlackRouterThreadParticipations do
  @moduledoc """
  Durable tri-state cache of a Router bot's Slack thread participation status.

  One exact `(group, connect, workspace, bot, channel, thread)` row stores
  either `participating` or `not_participating`; an absent or expired row means
  `unknown`. Participating rows use a renewable 30-day idle TTL. Confirmed
  not-participating rows use a fixed 24-hour TTL that reads never renew.

  During the mixed-version rollout, the original `expires_at` column remains
  the old runtime's visibility fence. A not-participating write sets it to the
  observation time, so old readers treat that row as expired, while new readers
  use `status_expires_at`. An old participating write makes `expires_at` live;
  new readers then normalize the row back to `participating`. This preserves
  one physical table without letting either runtime misclassify the status.

  The cross-Pod status handoff is modeled in
  `tla/salix/SlackRouterParticipation.tla`.
  """

  require Logger

  alias SalixStore.Repo

  @participating_ttl_days 30
  @not_participating_ttl_hours 24
  @default_query_timeout_ms 250
  @default_cleanup_limit 1_000
  @max_cleanup_limit 10_000

  @mark_participating_sql """
  WITH cache_clock AS (
    SELECT timezone('UTC', clock_timestamp()) AS now
  )
  INSERT INTO slack_router_thread_participations (
    group_id,
    connect_id,
    workspace_id,
    bot_user_id,
    channel_id,
    thread_ts,
    participation_status,
    last_active_at,
    expires_at,
    status_expires_at
  )
  SELECT
    $1, $2, $3, $4, $5, $6,
    'participating',
    cache_clock.now,
    cache_clock.now + interval '#{@participating_ttl_days} days',
    cache_clock.now + interval '#{@participating_ttl_days} days'
  FROM cache_clock
  ON CONFLICT (group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts)
  DO UPDATE SET
    participation_status = 'participating',
    last_active_at = GREATEST(
      slack_router_thread_participations.last_active_at,
      EXCLUDED.last_active_at
    ),
    expires_at = GREATEST(
      slack_router_thread_participations.expires_at,
      EXCLUDED.expires_at
    ),
    status_expires_at = GREATEST(
      COALESCE(
        slack_router_thread_participations.status_expires_at,
        slack_router_thread_participations.expires_at
      ),
      EXCLUDED.status_expires_at
    )
  """

  @mark_not_participating_sql """
  WITH cache_clock AS (
    SELECT timezone('UTC', clock_timestamp()) AS now
  )
  INSERT INTO slack_router_thread_participations (
    group_id,
    connect_id,
    workspace_id,
    bot_user_id,
    channel_id,
    thread_ts,
    participation_status,
    last_active_at,
    expires_at,
    status_expires_at
  )
  SELECT
    $1, $2, $3, $4, $5, $6,
    'not_participating',
    cache_clock.now,
    cache_clock.now,
    cache_clock.now + interval '#{@not_participating_ttl_hours} hours'
  FROM cache_clock
  ON CONFLICT (group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts)
  DO UPDATE SET
    participation_status = 'not_participating',
    last_active_at = EXCLUDED.last_active_at,
    expires_at = EXCLUDED.expires_at,
    status_expires_at = EXCLUDED.status_expires_at
  WHERE slack_router_thread_participations.expires_at <= EXCLUDED.last_active_at
    AND (
      slack_router_thread_participations.participation_status = 'not_participating'
      OR COALESCE(
        slack_router_thread_participations.status_expires_at,
        slack_router_thread_participations.expires_at
      ) <= EXCLUDED.last_active_at
    )
  RETURNING participation_status
  """

  @status_sql """
  WITH cache_clock AS (
    SELECT timezone('UTC', clock_timestamp()) AS now
  ),
  renewed_participating AS (
    UPDATE slack_router_thread_participations AS participation
    SET
      participation_status = 'participating',
      last_active_at = GREATEST(participation.last_active_at, cache_clock.now),
      expires_at = GREATEST(
        participation.expires_at,
        cache_clock.now + interval '#{@participating_ttl_days} days'
      ),
      status_expires_at = GREATEST(
        COALESCE(participation.status_expires_at, participation.expires_at),
        cache_clock.now + interval '#{@participating_ttl_days} days'
      )
    FROM cache_clock
    WHERE participation.group_id = $1
      AND participation.connect_id = $2
      AND participation.workspace_id = $3
      AND participation.bot_user_id = $4
      AND participation.channel_id = $5
      AND participation.thread_ts = $6
      AND (
        participation.expires_at > cache_clock.now
        OR (
          participation.participation_status = 'participating'
          AND COALESCE(participation.status_expires_at, participation.expires_at) > cache_clock.now
        )
      )
    RETURNING participation.participation_status
  ),
  cached_not_participating AS (
    SELECT participation.participation_status
    FROM slack_router_thread_participations AS participation, cache_clock
    WHERE participation.group_id = $1
      AND participation.connect_id = $2
      AND participation.workspace_id = $3
      AND participation.bot_user_id = $4
      AND participation.channel_id = $5
      AND participation.thread_ts = $6
      AND participation.participation_status = 'not_participating'
      AND participation.expires_at <= cache_clock.now
      AND COALESCE(participation.status_expires_at, participation.expires_at) > cache_clock.now
  )
  SELECT COALESCE(
    (SELECT participation_status FROM renewed_participating),
    (SELECT participation_status FROM cached_not_participating),
    'unknown'
  )
  """

  @cleanup_sql """
  WITH expired AS (
    SELECT
      group_id,
      connect_id,
      workspace_id,
      bot_user_id,
      channel_id,
      thread_ts
    FROM slack_router_thread_participations
    WHERE status_expires_at <= timezone('UTC', statement_timestamp())
      AND expires_at <= timezone('UTC', statement_timestamp())
    ORDER BY
      status_expires_at,
      group_id,
      connect_id,
      workspace_id,
      bot_user_id,
      channel_id,
      thread_ts
    LIMIT $1
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM slack_router_thread_participations AS participation
  USING expired
  WHERE participation.group_id = expired.group_id
    AND participation.connect_id = expired.connect_id
    AND participation.workspace_id = expired.workspace_id
    AND participation.bot_user_id = expired.bot_user_id
    AND participation.channel_id = expired.channel_id
    AND participation.thread_ts = expired.thread_ts
  """

  @cleanup_legacy_rows_sql """
  WITH expired AS (
    SELECT
      group_id,
      connect_id,
      workspace_id,
      bot_user_id,
      channel_id,
      thread_ts
    FROM slack_router_thread_participations
    WHERE status_expires_at IS NULL
      AND expires_at <= timezone('UTC', statement_timestamp())
    ORDER BY expires_at, group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts
    LIMIT $1
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM slack_router_thread_participations AS participation
  USING expired
  WHERE participation.group_id = expired.group_id
    AND participation.connect_id = expired.connect_id
    AND participation.workspace_id = expired.workspace_id
    AND participation.bot_user_id = expired.bot_user_id
    AND participation.channel_id = expired.channel_id
    AND participation.thread_ts = expired.thread_ts
  """

  @doc "Mark one exact Router-thread identity as participating."
  @spec mark_participating(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_identity | term()}
  def mark_participating(group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts) do
    write_status(
      @mark_participating_sql,
      [group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts]
    )
  end

  @doc "Compatibility name for `mark_participating/6`."
  def record(group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts),
    do: mark_participating(group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts)

  @doc "Mark one exact Router-thread identity as confirmed not participating."
  @spec mark_not_participating(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, :not_participating | :participating}
          | {:error, :invalid_identity | term()}
  def mark_not_participating(
        group_id,
        connect_id,
        workspace_id,
        bot_user_id,
        channel_id,
        thread_ts
      ) do
    identity = [group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts]

    if valid_identity?(identity) do
      safe_query(fn ->
        case Repo.query(@mark_not_participating_sql, identity, timeout: @default_query_timeout_ms) do
          {:ok, %{rows: [["not_participating"]]}} ->
            {:ok, :not_participating}

          # The conflict guard rejects a stale negative write only when an
          # unexpired participating row won first. Surface that final status
          # so the ingress callback does not return its stale history result.
          {:ok, %{num_rows: 0, rows: []}} ->
            {:ok, :participating}

          {:ok, result} ->
            {:error, {:unexpected_not_participating_write_result, result}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    else
      {:error, :invalid_identity}
    end
  end

  @doc """
  Return `:participating`, `:not_participating`, or `:unknown` for one exact key.

  A participating hit renews its 30-day idle TTL. A not-participating hit never
  renews its fixed 24-hour TTL. Database failure and invalid identity return
  `:unknown`.
  """
  @spec status(String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          :participating | :not_participating | :unknown
  def status(group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts, opts \\ []) do
    identity = [group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts]

    if valid_identity?(identity) do
      case safe_query(fn ->
             Repo.query(@status_sql, identity, timeout: query_timeout_ms(opts))
           end) do
        {:ok, %{rows: [["participating"]]}} ->
          :participating

        {:ok, %{rows: [["not_participating"]]}} ->
          :not_participating

        {:ok, _result} ->
          :unknown

        {:error, reason} ->
          Logger.debug(
            "slack router thread participation status lookup failed; treating as unknown: #{inspect(reason)}"
          )

          :unknown
      end
    else
      :unknown
    end
  end

  @doc "Return true only when `status/7` is `:participating`."
  @spec participating?(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: boolean()
  def participating?(
        group_id,
        connect_id,
        workspace_id,
        bot_user_id,
        channel_id,
        thread_ts,
        opts \\ []
      ) do
    status(group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts, opts) ==
      :participating
  end

  @doc "Delete at most `limit` expired status rows."
  @spec cleanup_expired(integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired(limit \\ @default_cleanup_limit) do
    cleanup(@cleanup_sql, limit)
  end

  @doc "Delete at most `limit` expired pre-status rows left by the rollout."
  @spec cleanup_legacy_expired(integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_legacy_expired(limit \\ @default_cleanup_limit) do
    cleanup(@cleanup_legacy_rows_sql, limit)
  end

  defp cleanup(sql, limit) do
    limit = bounded_limit(limit)

    safe_query(fn ->
      case Repo.query(sql, [limit]) do
        {:ok, %{num_rows: count}} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp write_status(sql, identity) do
    if valid_identity?(identity) do
      safe_query(fn ->
        case Repo.query(sql, identity, timeout: @default_query_timeout_ms) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :invalid_identity}
    end
  end

  defp safe_query(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp valid_identity?(parts) do
    Enum.all?(parts, fn part ->
      is_binary(part) and String.valid?(part) and String.trim(part) != ""
    end)
  end

  defp bounded_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_cleanup_limit)

  defp bounded_limit(_limit), do: @default_cleanup_limit

  defp query_timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_query_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_query_timeout_ms
    end
  end
end
