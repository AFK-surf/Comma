defmodule SalixStore.FeishuMirrorOutbox do
  @moduledoc """
  Durable hop between the Feishu callback and the ClickHouse mirror.

  The same protocol as `SalixStore.SlackMirrorOutbox`, without its
  message-search admission: the callback appends the normalized row and
  returns, and a drainer on each Pod claims the oldest rows, inserts them, and
  deletes them once the insert is acknowledged.

    * **Delete only after the write is acknowledged.** A drainer that dies
      between the write and the delete leaves the row to be written again.

    * **Writing a row twice is harmless.** The row's `version` comes from the
      message's own state and the destination is a `ReplacingMergeTree` on it.

  The claim is a `SKIP LOCKED` lease with a TTL and carries no ownership. All
  clocks are the database's.
  """

  alias SalixStore.Repo

  @kinds ["message"]

  @type entry :: %{id: pos_integer(), kind: String.t(), row: map(), attempts: non_neg_integer()}

  @doc "Append one mirror row."
  @spec append(map(), String.t()) :: :ok | {:error, term()}
  def append(row, kind \\ "message")

  def append(row, kind) when is_map(row) and kind in @kinds do
    safe_query(fn ->
      case Repo.query(
             """
             INSERT INTO feishu_mirror_outbox (kind, row, inserted_at)
             VALUES ($1, $2, timezone('UTC', clock_timestamp()))
             """,
             [kind, row]
           ) do
        {:ok, %{num_rows: 1}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def append(_row, _kind), do: {:error, :invalid_feishu_mirror_outbox_kind}

  @doc "Claims up to `limit` of the oldest claimable rows for `ttl_ms`, in id order."
  @spec claim(pos_integer(), pos_integer()) :: {:ok, [entry()]} | {:error, term()}
  def claim(limit, ttl_ms)
      when is_integer(limit) and limit > 0 and is_integer(ttl_ms) and ttl_ms > 0 do
    safe_query(fn ->
      case Repo.query(
             """
             UPDATE feishu_mirror_outbox
             SET claimed_until = timezone('UTC', clock_timestamp()) + ($2 * interval '1 millisecond')
             WHERE id IN (
               SELECT id FROM feishu_mirror_outbox
               WHERE claimed_until IS NULL OR claimed_until < timezone('UTC', clock_timestamp())
               ORDER BY id
               LIMIT $1
               FOR UPDATE SKIP LOCKED
             )
             RETURNING id, kind, row, attempts
             """,
             [limit, ttl_ms]
           ) do
        {:ok, result} ->
          {:ok,
           result.rows
           |> Enum.map(fn [id, kind, row, attempts] ->
             %{id: id, kind: kind, row: row, attempts: attempts}
           end)
           |> Enum.sort_by(& &1.id)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc "Removes rows whose ClickHouse insert was acknowledged."
  @spec delete([pos_integer()]) :: :ok | {:error, term()}
  def delete([]), do: :ok

  def delete(ids) when is_list(ids) do
    safe_query(fn ->
      case Repo.query("DELETE FROM feishu_mirror_outbox WHERE id = ANY($1)", [ids]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc "Records a failed write and holds the rows back for `backoff_ms`."
  @spec defer([pos_integer()], term(), non_neg_integer()) :: :ok | {:error, term()}
  def defer([], _reason, _backoff_ms), do: :ok

  def defer(ids, reason, backoff_ms)
      when is_list(ids) and is_integer(backoff_ms) and backoff_ms >= 0 do
    safe_query(fn ->
      case Repo.query(
             """
             UPDATE feishu_mirror_outbox
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
  `(chat_id, message_id)` pairs in `pairs` that still have an undrained row.

  Bounded by the caller's list (at most 200). The outbox is the pending set,
  so this probes known keys rather than scanning history.
  """
  @spec pending_message_keys(map(), [{String.t(), String.t()}]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def pending_message_keys(_scope, []), do: {:ok, []}

  def pending_message_keys(%{"tenant_id" => tenant_id, "app_id" => app_id}, pairs)
      when is_binary(tenant_id) and is_binary(app_id) and is_list(pairs) and length(pairs) <= 200 do
    if Enum.all?(pairs, &valid_pair?/1) do
      safe_query(fn ->
        case Repo.query(
               """
               SELECT DISTINCT row->>'chat_id', row->>'message_id'
               FROM feishu_mirror_outbox
               WHERE row->>'tenant_id' = $1
                 AND row->>'app_id' = $2
                 AND (row->>'chat_id', row->>'message_id') IN (
                   SELECT * FROM unnest($3::text[], $4::text[])
                 )
               """,
               [tenant_id, app_id, Enum.map(pairs, &elem(&1, 0)), Enum.map(pairs, &elem(&1, 1))]
             ) do
          {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [chat, id] -> {chat, id} end)}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :invalid_feishu_mirror_outbox_read}
    end
  end

  def pending_message_keys(_scope, _pairs), do: {:error, :invalid_feishu_mirror_outbox_read}

  @doc "Age in milliseconds of the oldest row still waiting, or `nil` when empty."
  @spec oldest_pending_age_ms() :: {:ok, non_neg_integer() | nil} | {:error, term()}
  def oldest_pending_age_ms do
    safe_query(fn ->
      case Repo.query(
             """
             SELECT GREATEST(0, floor(extract(epoch from
               timezone('UTC', clock_timestamp()) - inserted_at) * 1000))::bigint
             FROM feishu_mirror_outbox ORDER BY id LIMIT 1
             """,
             []
           ) do
        {:ok, %{rows: [[age]]}} -> {:ok, age}
        {:ok, %{rows: []}} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp valid_pair?({chat_id, message_id}),
    do: is_binary(chat_id) and chat_id != "" and is_binary(message_id) and message_id != ""

  defp valid_pair?(_pair), do: false

  # ClickHouse error bodies can echo message text, so the diagnostic is bounded.
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp safe_query(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
