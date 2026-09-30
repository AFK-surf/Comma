defmodule SalixStore.SlackMirrorBackfillLedger do
  @moduledoc """
  Durable state of the Slack history backfill: a watermark per channel and a
  lease per Slack installation.

  ## Watermarks are monotone and unfenced

  A channel row says: every thread parent with `ts` in
  `[indexed_from_ts_us, indexed_to_ts_us]`, and every reply to one, is in
  ClickHouse. `indexed_to_ts_us` is fixed when the first page lands; the live
  webhook path owns everything after it. `indexed_from_ts_us` only ever moves
  DOWN, by `LEAST`, and a walker lowers it only after the page that reaches
  that timestamp — parents and replies — has been acknowledged by ClickHouse.

  That is why no commit here checks who is committing. A walker that lost its
  claim, or two walkers on one channel at once, can each only report a
  timestamp they have themselves written down to, from a start at or above
  the current watermark. `LEAST` of two true statements is true. The claim on
  a channel row exists to keep two bots that share a channel from spending
  two Slack budgets on the same pages, and for nothing else.

  Model: `tla/salix/SlackMirrorBackfill.tla`, whose safety configuration runs
  two walkers with no mutual exclusion.

  ## Installations are the unit of work

  Slack rate-limits per workspace AND bot token, so one installation is one
  budget: two bots in the same workspace can be walked in parallel, and two
  Pods driving one bot only split what it has. The connect row is what a Pod
  claims — the one due the longest, `SKIP LOCKED` — and `due_at` is when it is
  next worth a pass: at once while it reports history left, after the pass
  interval once everything it can reach is indexed. The claim is a courtesy
  lease with no ownership token: a stale Pod may renew or finish a lease
  another Pod has already taken. Duplicate passes are accepted. The
  channel watermark does not depend on exclusive ownership. A join kicks
  `kick_generation` and due now; a finish defers only if it claimed at that
  generation. Model: `tla/salix/SlackMirrorConnectKick.tla`.

  Rows are keyed the way ClickHouse keys mirrored messages, not by group or
  installation: however many bots reach a channel, the messages are one set
  and so is the watermark. All clocks are the database's.
  """

  alias SalixStore.Repo

  @channel_columns ~w(
    tenant_id workspace_id channel_id indexed_from_ts_us indexed_to_ts_us
    exhausted leased_until last_error updated_at
  )
  @channel_returning Enum.join(@channel_columns, ", ")

  @connect_columns ~w(connect_id tenant_id group_id leased_until due_at kick_generation last_error updated_at)
  @connect_returning Enum.join(@connect_columns, ", ")

  @type key :: %{required(String.t()) => String.t()}

  ## Channels

  @doc """
  Claims one channel for `ttl_ms`, creating its row on first sight.

  `:busy` means another walker holds it. The returned map is the row after the
  claim, so the walker reads its watermark and its claim in one round trip.
  """
  @spec claim_channel(key(), pos_integer()) :: {:ok, map()} | :busy | {:error, term()}
  def claim_channel(key, ttl_ms) when is_map(key) and is_integer(ttl_ms) and ttl_ms > 0 do
    with {:ok, values} <- channel_key(key) do
      query_one(
        """
        INSERT INTO slack_mirror_channel_watermarks
          (tenant_id, workspace_id, channel_id, leased_until, updated_at)
        VALUES (
          $1, $2, $3,
          timezone('UTC', clock_timestamp()) + ($4 * interval '1 millisecond'),
          timezone('UTC', clock_timestamp())
        )
        ON CONFLICT (tenant_id, workspace_id, channel_id) DO UPDATE SET
          leased_until = EXCLUDED.leased_until,
          updated_at = EXCLUDED.updated_at
        WHERE slack_mirror_channel_watermarks.leased_until IS NULL
           OR slack_mirror_channel_watermarks.leased_until < timezone('UTC', clock_timestamp())
        RETURNING #{@channel_returning}
        """,
        values ++ [ttl_ms],
        :busy
      )
    end
  end

  @doc """
  Lowers a channel's watermark to `oldest_ts_us`, never raising it.

  `walk_start_us` becomes `indexed_to_ts_us` only if the row has none yet.
  Call this after — never before — every row down to `oldest_ts_us` has been
  acknowledged by ClickHouse.
  """
  @spec lower_watermark(key(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def lower_watermark(key, oldest_ts_us, walk_start_us)
      when is_map(key) and is_integer(oldest_ts_us) and oldest_ts_us >= 0 and
             is_integer(walk_start_us) and walk_start_us >= 0 do
    with {:ok, values} <- channel_key(key) do
      exec(
        """
        UPDATE slack_mirror_channel_watermarks
        SET indexed_from_ts_us = LEAST(COALESCE(indexed_from_ts_us, $4), $4),
            indexed_to_ts_us = COALESCE(indexed_to_ts_us, $5),
            last_error = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id = $3
        """,
        values ++ [oldest_ts_us, walk_start_us]
      )
    end
  end

  @doc "Records that Slack answered with nothing older than the watermark."
  @spec mark_exhausted(key()) :: :ok | {:error, term()}
  def mark_exhausted(key) when is_map(key) do
    with {:ok, values} <- channel_key(key) do
      exec(
        """
        UPDATE slack_mirror_channel_watermarks
        SET exhausted = TRUE, last_error = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id = $3
        """,
        values
      )
    end
  end

  @doc "Records why the last pass over a channel stopped early."
  @spec record_channel_error(key(), term()) :: :ok | {:error, term()}
  def record_channel_error(key, reason) when is_map(key) do
    with {:ok, values} <- channel_key(key) do
      exec(
        """
        UPDATE slack_mirror_channel_watermarks
        SET last_error = $4, updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id = $3
        """,
        values ++ [error_text(reason)]
      )
    end
  end

  @doc "Extends a held claim. `{:error, :claim_lost}` when it expired or moved."
  @spec renew_channel(key(), pos_integer()) :: :ok | {:error, term()}
  def renew_channel(key, ttl_ms) when is_map(key) and is_integer(ttl_ms) and ttl_ms > 0 do
    with {:ok, values} <- channel_key(key) do
      exec_one(
        """
        UPDATE slack_mirror_channel_watermarks
        SET leased_until = timezone('UTC', clock_timestamp()) + ($4 * interval '1 millisecond')
        WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id = $3
          AND leased_until IS NOT NULL
          AND leased_until >= timezone('UTC', clock_timestamp())
        """,
        values ++ [ttl_ms],
        :claim_lost
      )
    end
  end

  @doc "Releases a channel claim so another walker may take it at once."
  @spec release_channel(key()) :: :ok | {:error, term()}
  def release_channel(key) when is_map(key) do
    with {:ok, values} <- channel_key(key) do
      exec(
        """
        UPDATE slack_mirror_channel_watermarks
        SET leased_until = NULL, updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id = $3
        """,
        values
      )
    end
  end

  @doc "The watermark row for one channel, for readers and tests."
  @spec watermark(key()) :: {:ok, map()} | {:error, term()}
  def watermark(key) when is_map(key) do
    with {:ok, values} <- channel_key(key) do
      query_one(
        """
        SELECT #{@channel_returning} FROM slack_mirror_channel_watermarks
        WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id = $3
        """,
        values,
        {:error, :not_found}
      )
    end
  end

  @doc """
  Watermark rows for one tenant+workspace, bounded by claimed channels.

  Used by workspace-wide `im_api.slack.search` to mark `incomplete`. Empty
  list means discovery has not claimed a channel yet.
  """
  @spec list_watermarks(map()) :: {:ok, [map()]} | {:error, term()}
  def list_watermarks(key) when is_map(key) do
    with {:ok, values} <- workspace_key(key) do
      safe_query(fn ->
        case Repo.query(
               """
               SELECT #{@channel_returning}
               FROM slack_mirror_channel_watermarks
               WHERE tenant_id = $1 AND workspace_id = $2
               """,
               values
             ) do
          {:ok, %{columns: columns, rows: rows}} ->
            {:ok, Enum.map(rows, &row(columns, &1))}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  ## Connects

  @doc "One indexed page of mirrored channels for an existing installation."
  def list_channel_page(key, after_channel \\ "", limit \\ 20)
      when is_map(key) and is_binary(after_channel) and is_integer(limit) and limit in 1..100 do
    with {:ok, values} <- workspace_key(key) do
      safe_query(fn ->
        case Repo.query(
               """
               SELECT tenant_id, workspace_id, channel_id
               FROM slack_mirror_channel_watermarks
               WHERE tenant_id = $1 AND workspace_id = $2 AND channel_id > $3
               ORDER BY channel_id LIMIT $4
               """,
               values ++ [after_channel, limit]
             ) do
          {:ok, %{columns: columns, rows: rows}} ->
            {:ok, Enum.map(rows, &row(columns, &1))}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @doc """
  Records the installations discovery found. New rows are due at once;
  existing rows keep their schedule and their claim.
  """
  @spec upsert_connects([map()]) :: :ok | {:error, term()}
  def upsert_connects([]), do: :ok

  def upsert_connects(connects) when is_list(connects) do
    rows =
      Enum.map(connects, fn connect ->
        Enum.map(~w(connect_id tenant_id group_id), &Map.get(connect, &1))
      end)

    if Enum.all?(rows, &valid_values?/1) do
      {placeholders, params} =
        rows
        |> Enum.with_index()
        |> Enum.map_reduce([], fn {[connect_id, tenant_id, group_id], index}, acc ->
          base = index * 3

          {"($#{base + 1}, $#{base + 2}, $#{base + 3}, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))",
           acc ++ [connect_id, tenant_id, group_id]}
        end)

      exec(
        """
        INSERT INTO slack_mirror_backfill_connects
          (connect_id, tenant_id, group_id, due_at, updated_at)
        VALUES #{Enum.join(placeholders, ", ")}
        ON CONFLICT (connect_id) DO UPDATE SET
          tenant_id = EXCLUDED.tenant_id,
          group_id = EXCLUDED.group_id,
          updated_at = EXCLUDED.updated_at
        """,
        params
      )
    else
      {:error, :invalid_slack_mirror_connect}
    end
  end

  @doc """
  Claims the installation that has been due the longest, or `:empty`.

  `SKIP LOCKED` is what makes this safe to run on every Pod at once: two Pods
  racing on the same due row do not serialize, they take different rows.
  """
  @spec claim_due_connect(pos_integer()) :: {:ok, map()} | :empty | {:error, term()}
  def claim_due_connect(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    query_one(
      """
      UPDATE slack_mirror_backfill_connects
      SET leased_until = timezone('UTC', clock_timestamp()) + ($1 * interval '1 millisecond'),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE connect_id = (
        SELECT connect_id FROM slack_mirror_backfill_connects
        WHERE (leased_until IS NULL OR leased_until < timezone('UTC', clock_timestamp()))
          AND due_at <= timezone('UTC', clock_timestamp())
        ORDER BY due_at
        LIMIT 1
        FOR UPDATE SKIP LOCKED
      )
      RETURNING #{@connect_returning}
      """,
      [ttl_ms],
      :empty
    )
  end

  @doc """
  Courtesy extension of the connect lease.

  There is no ownership token. A stale Pod that still knows `connect_id` may
  extend a lease another Pod has already taken; duplicate passes are
  accepted. `{:error, :claim_lost}` only when the lease has already expired
  or been released.
  """
  @spec renew_connect(String.t(), pos_integer()) :: :ok | {:error, term()}
  def renew_connect(connect_id, ttl_ms)
      when is_binary(connect_id) and is_integer(ttl_ms) and ttl_ms > 0 do
    exec_one(
      """
      UPDATE slack_mirror_backfill_connects
      SET leased_until = timezone('UTC', clock_timestamp()) + ($2 * interval '1 millisecond')
      WHERE connect_id = $1
        AND leased_until IS NOT NULL
        AND leased_until >= timezone('UTC', clock_timestamp())
      """,
      [connect_id, ttl_ms],
      :claim_lost
    )
  end

  @doc """
  Releases an installation and schedules its next pass `due_in_ms` from now.

  `reason` is `nil` after a pass that ended normally, else the error that
  stopped it; either way the row is released, because a stuck claim is the
  one thing this table must never produce.
  """
  @spec finish_connect(String.t(), non_neg_integer(), term(), non_neg_integer()) ::
          :ok | {:error, term()}
  def finish_connect(connect_id, due_in_ms, reason, claimed_kick_gen \\ 0)
      when is_binary(connect_id) and is_integer(due_in_ms) and due_in_ms >= 0 and
             is_integer(claimed_kick_gen) and claimed_kick_gen >= 0 do
    exec(
      """
      UPDATE slack_mirror_backfill_connects
      SET leased_until = NULL,
          due_at = CASE
            WHEN kick_generation > $4 THEN timezone('UTC', clock_timestamp())
            ELSE timezone('UTC', clock_timestamp()) + ($2 * interval '1 millisecond')
          END,
          last_error = $3,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE connect_id = $1
      """,
      [
        connect_id,
        due_in_ms,
        if(is_nil(reason), do: nil, else: error_text(reason)),
        claimed_kick_gen
      ]
    )
  end

  @doc """
  Makes an installation due now, even if a pass currently holds its lease.

  Bumps `kick_generation`. A finish whose claim is older than that generation
  cannot defer the next pass.
  """
  @spec kick_connect(map()) :: :ok | {:error, term()}
  def kick_connect(connect) when is_map(connect) do
    values = Enum.map(~w(connect_id tenant_id group_id), &Map.get(connect, &1))

    if valid_values?(values) do
      exec(
        """
        INSERT INTO slack_mirror_backfill_connects
          (connect_id, tenant_id, group_id, due_at, kick_generation, updated_at)
        VALUES ($1, $2, $3, timezone('UTC', clock_timestamp()), 1, timezone('UTC', clock_timestamp()))
        ON CONFLICT (connect_id) DO UPDATE SET
          tenant_id = EXCLUDED.tenant_id,
          group_id = EXCLUDED.group_id,
          due_at = timezone('UTC', clock_timestamp()),
          kick_generation = slack_mirror_backfill_connects.kick_generation + 1,
          updated_at = timezone('UTC', clock_timestamp())
        """,
        values
      )
    else
      {:error, :invalid_slack_mirror_connect}
    end
  end

  @doc """
  Forgets an installation that can no longer be loaded. Discovery puts it back
  if it reappears; its channel watermarks are untouched.
  """
  @spec delete_connect(String.t()) :: :ok | {:error, term()}
  def delete_connect(connect_id) when is_binary(connect_id) do
    exec("DELETE FROM slack_mirror_backfill_connects WHERE connect_id = $1", [connect_id])
  end

  @doc "The connect row, for tests and diagnostics."
  @spec connect(String.t()) :: {:ok, map()} | {:error, term()}
  def connect(connect_id) when is_binary(connect_id) do
    query_one(
      "SELECT #{@connect_returning} FROM slack_mirror_backfill_connects WHERE connect_id = $1",
      [connect_id],
      {:error, :not_found}
    )
  end

  ## Helpers

  defp channel_key(key) do
    values = Enum.map(~w(tenant_id workspace_id channel_id), &Map.get(key, &1))

    if valid_values?(values),
      do: {:ok, values},
      else: {:error, :invalid_slack_mirror_channel_key}
  end

  defp workspace_key(key) do
    values = Enum.map(~w(tenant_id workspace_id), &Map.get(key, &1))

    if valid_values?(values),
      do: {:ok, values},
      else: {:error, :invalid_slack_mirror_channel_key}
  end

  defp valid_values?(values),
    do: Enum.all?(values, &(is_binary(&1) and &1 != "" and &1 == String.trim(&1)))

  defp query_one(sql, params, on_none) do
    safe_query(fn ->
      case Repo.query(sql, params) do
        {:ok, %{num_rows: 1} = result} -> {:ok, row(result.columns, hd(result.rows))}
        {:ok, %{num_rows: 0}} -> on_none
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp exec(sql, params) do
    safe_query(fn ->
      case Repo.query(sql, params) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp exec_one(sql, params, on_none) do
    safe_query(fn ->
      case Repo.query(sql, params) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> {:error, on_none}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp row(columns, values), do: columns |> Enum.zip(values) |> Map.new()

  # Slack error bodies can echo message text, so the diagnostic is bounded and
  # summarized rather than stored whole.
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp safe_query(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
