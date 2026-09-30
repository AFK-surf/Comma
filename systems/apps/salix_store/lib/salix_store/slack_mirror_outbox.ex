defmodule SalixStore.SlackMirrorOutbox do
  @moduledoc """
  Durable hop between the Slack webhook and the ClickHouse mirror.

  The webhook appends the normalized mirror row and returns. A drainer on each
  Pod claims the oldest rows, inserts them into ClickHouse, and deletes them
  once the insert is acknowledged. That is the whole protocol; what makes it
  correct is one rule and one property:

    * **Delete only after the write is acknowledged.** A row is removed for no
      other reason, so the table is exactly the set of events ClickHouse has
      not confirmed. A drainer that dies between the write and the delete
      leaves the row to be written again.

    * **Writing a row twice is harmless.** The row's `version` comes from the
      message's own state, and the destination is a `ReplacingMergeTree` on
      it, so the second insert is absorbed. At-least-once delivery is
      therefore exactly-once in effect, and the claim below needs no fence.

  The claim is a `SKIP LOCKED` lease with a TTL, which keeps two drainers off
  the same rows and lets a failed batch wait before it is tried again. It
  carries no ownership: whoever holds an unexpired claim may still be beaten
  to the delete by a drainer whose claim expired mid-write, and nothing is
  lost when that happens. All clocks are the database's.

  Models: `tla/salix/SlackMirrorOutbox.tla` (durability) and
  `tla/salix/MessageSearchSourceLanes.tla` (history isolation with old drainers).
  """

  alias SalixStore.{Repo, SlackSearchSources}

  @type kind :: String.t()
  @type entry :: %{
          id: pos_integer(),
          kind: kind(),
          row: map(),
          attempts: non_neg_integer(),
          context: map()
        }

  @doc "Append a mirror row and invalidate its search epoch in one PG transaction."
  @spec append(map(), kind(), map()) :: :ok | {:error, term()}
  def append(row, kind \\ "message", context \\ %{})

  def append(row, kind, context)
      when is_map(row) and is_map(context) and kind in ["message", "reaction", "pin", "metadata"] do
    row =
      if kind == "message", do: Map.put(row, "source_write_id", Ecto.UUID.generate()), else: row

    safe_query(fn ->
      Repo.transaction(fn ->
        if kind == "message",
          do: SlackSearchSources.admit!([Map.put(row, "_semantic_context", context)])

        case Repo.query(
               """
               INSERT INTO slack_mirror_outbox (kind, row, context, inserted_at)
               VALUES ($1, $2, $3, timezone('UTC', clock_timestamp()))
               """,
               [kind, row, Map.take(context, ~w(group_id connect_id connect_generation))]
             ) do
          {:ok, %{num_rows: 1}} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        error -> error
      end
    end)
  end

  def append(_row, _kind, _context), do: {:error, :invalid_slack_mirror_outbox_kind}

  @doc """
  Admit a bounded synchronous message batch, including history/repair writers.

  The caller writes the returned rows and deletes these exact IDs after the
  canonical ACK. A crash leaves work in the separate source-write queue.
  The drainer replays it without creating live Triage triggers; old drainers
  cannot claim this queue.
  """
  def admit_messages(rows) when is_list(rows) and length(rows) in 1..200 do
    rows = Enum.map(rows, &Map.put(&1, "source_write_id", Ecto.UUID.generate()))

    safe_query(fn ->
      Repo.transaction(fn ->
        SlackSearchSources.admit!(rows)

        input =
          Enum.map(rows, fn row ->
            %{
              "row" => Map.drop(row, ["_semantic_context", "_mirror_outbox_id"]),
              "context" =>
                Map.take(
                  row["_semantic_context"] || %{},
                  ~w(group_id connect_id connect_generation)
                )
            }
          end)

        Repo.query!(
          """
          INSERT INTO slack_mirror_source_writes (kind, row, context, inserted_at)
          SELECT 'message', r.row, r.context, timezone('UTC', clock_timestamp())
          FROM jsonb_to_recordset($1::jsonb) AS r(row jsonb, context jsonb)
          RETURNING id, row, context
          """,
          [input]
        ).rows
        |> Enum.map(fn [id, row, context] ->
          row |> Map.put("_mirror_outbox_id", id) |> Map.put("_semantic_context", context)
        end)
      end)
    end)
  end

  @doc """
  Claims up to `limit` of the oldest claimable rows for `ttl_ms`.

  Rows come back in id order. A row is claimable when it has never been
  claimed or its claim has expired, which is the same test for a row whose
  drainer died and a row whose last write failed.
  """
  @spec claim(pos_integer(), pos_integer()) :: {:ok, [entry()]} | {:error, term()}
  def claim(limit, ttl_ms)
      when is_integer(limit) and limit > 0 and is_integer(ttl_ms) and ttl_ms > 0 do
    claim_from("slack_mirror_outbox", limit, ttl_ms)
  end

  @doc "Claim source replay only after the live webhook outbox was empty."
  def claim_source_writes(limit, ttl_ms) when limit in 1..200 and ttl_ms > 0,
    do: claim_from("slack_mirror_source_writes", limit, ttl_ms)

  defp claim_from(table, limit, ttl_ms) do
    safe_query(fn ->
      case Repo.query(
             """
             UPDATE #{table}
             SET claimed_until = timezone('UTC', clock_timestamp()) + ($2 * interval '1 millisecond')
             WHERE id IN (
               SELECT id FROM #{table}
               WHERE claimed_until IS NULL OR claimed_until < timezone('UTC', clock_timestamp())
               ORDER BY id
               LIMIT $1
               FOR UPDATE SKIP LOCKED
             )
             RETURNING id, kind, row, attempts, context
             """,
             [limit, ttl_ms]
           ) do
        {:ok, result} ->
          entries =
            result.rows
            |> Enum.map(fn [id, kind, row, attempts, context] ->
              %{id: id, kind: kind, row: row, attempts: attempts, context: context}
            end)
            |> Enum.sort_by(& &1.id)

          {:ok, entries}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc "Removes rows whose ClickHouse insert was acknowledged."
  @spec delete([pos_integer()]) :: :ok | {:error, term()}
  def delete([]), do: :ok

  def delete(ids) when is_list(ids) do
    delete_from("slack_mirror_outbox", ids)
  end

  @doc "Remove only acknowledged history/repair intents."
  def delete_source_writes(ids), do: delete_from("slack_mirror_source_writes", ids)

  defp delete_from(_table, []), do: :ok

  defp delete_from(table, ids) do
    safe_query(fn ->
      case Repo.query("DELETE FROM #{table} WHERE id = ANY($1)", [ids]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Records a failed write and holds the rows back for `backoff_ms`.

  The rows stay; only their next eligibility moves. `attempts` is how an
  operator finds a row ClickHouse keeps rejecting among rows that merely
  shared a batch with it once.
  """
  @spec defer([pos_integer()], term(), non_neg_integer()) :: :ok | {:error, term()}
  def defer([], _reason, _backoff_ms), do: :ok

  def defer(ids, reason, backoff_ms)
      when is_list(ids) and is_integer(backoff_ms) and backoff_ms >= 0 do
    defer_in("slack_mirror_outbox", ids, reason, backoff_ms)
  end

  def defer_source_writes(ids, reason, backoff_ms),
    do: defer_in("slack_mirror_source_writes", ids, reason, backoff_ms)

  defp defer_in(table, ids, reason, backoff_ms) do
    safe_query(fn ->
      case Repo.query(
             """
             UPDATE #{table}
             SET attempts = attempts + 1,
                 last_error = $2,
                 claimed_until = timezone('UTC', clock_timestamp()) + ($3 * interval '1 millisecond')
             WHERE id = ANY($1)
             """,
             [ids, error_text(reason), backoff_ms]
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Message timestamps in `ts_list` that still have an undrained outbox row.

  Bounded by the caller's list (at most 200). The outbox is the pending set,
  so this is a probe of known keys, not a scan of history.
  """
  @spec pending_message_ts(map(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def pending_message_ts(_scope, []), do: {:ok, []}

  def pending_message_ts(scope, ts_list)
      when is_map(scope) and is_list(ts_list) and length(ts_list) <= 1_000 do
    keys = ts_list |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

    if keys == [] do
      {:ok, []}
    else
      safe_query(fn ->
        case Repo.query(
               """
               SELECT DISTINCT row->>'message_ts'
               FROM slack_mirror_outbox
               WHERE row->>'tenant_id' = $1
                 AND row->>'workspace_id' = $2
                 AND row->>'channel_id' = $3
                 AND row->>'message_ts' = ANY($4::text[])
               """,
               [
                 scope["tenant_id"],
                 scope["workspace_id"],
                 scope["channel_id"],
                 keys
               ]
             ) do
          {:ok, %{rows: rows}} ->
            {:ok, Enum.map(rows, &hd/1)}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  def pending_message_ts(_scope, _ts_list), do: {:error, :invalid_slack_mirror_outbox_read}

  @doc """
  Pending `(channel_id, message_ts)` pairs for a workspace-wide search page.

  One SQL against the outbox, at most 200 pairs. Used to mark `stale` without
  a per-channel loop.
  """
  @spec pending_message_keys(map(), [{String.t(), String.t()}]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def pending_message_keys(_scope, []), do: {:ok, []}

  def pending_message_keys(scope, pairs)
      when is_map(scope) and is_list(pairs) and length(pairs) <= 200 do
    channels = Enum.map(pairs, &elem(&1, 0))
    timestamps = Enum.map(pairs, &elem(&1, 1))

    valid? =
      is_binary(scope["tenant_id"]) and is_binary(scope["workspace_id"]) and
        Enum.all?(channels, &(is_binary(&1) and &1 != "")) and
        Enum.all?(timestamps, &(is_binary(&1) and &1 != ""))

    if valid? do
      safe_query(fn ->
        case Repo.query(
               """
               SELECT DISTINCT row->>'channel_id', row->>'message_ts'
               FROM slack_mirror_outbox
               WHERE row->>'tenant_id' = $1
                 AND row->>'workspace_id' = $2
                 AND (row->>'channel_id', row->>'message_ts') IN (
                   SELECT * FROM unnest($3::text[], $4::text[])
                 )
               """,
               [scope["tenant_id"], scope["workspace_id"], channels, timestamps]
             ) do
          {:ok, %{rows: rows}} ->
            {:ok, Enum.map(rows, fn [channel, ts] -> {channel, ts} end)}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    else
      {:error, :invalid_slack_mirror_outbox_read}
    end
  end

  def pending_message_keys(_scope, _pairs), do: {:error, :invalid_slack_mirror_outbox_read}

  @doc """
  Age in milliseconds of the oldest row still waiting, or `nil` when empty.

  Two primary-key probes cover live webhook and source replay, independent of
  backlog depth. The existing mirror lag signal includes both durable lanes.
  """
  @spec oldest_pending_age_ms() :: {:ok, non_neg_integer() | nil} | {:error, term()}
  def oldest_pending_age_ms do
    safe_query(fn ->
      case Repo.query(
             """
             SELECT GREATEST(0, floor(extract(epoch from
               timezone('UTC', clock_timestamp()) - inserted_at) * 1000))::bigint
             FROM (
               (SELECT inserted_at FROM slack_mirror_outbox ORDER BY id LIMIT 1)
               UNION ALL
               (SELECT inserted_at FROM slack_mirror_source_writes ORDER BY id LIMIT 1)
             ) pending
             ORDER BY inserted_at
             LIMIT 1
             """,
             []
           ) do
        {:ok, %{rows: [[age]]}} -> {:ok, age}
        {:ok, %{rows: []}} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # ClickHouse error bodies can echo message text, so the diagnostic is bounded
  # and summarized rather than stored whole.
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp safe_query(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
