defmodule SalixStore.FeishuMirrorBackfillLedger do
  @moduledoc """
  Durable state of the Feishu history backfill.

  Two tables. `feishu_mirror_backfill_connects` holds one lease and one due
  time per Feishu app installation: the unit a Pod claims, because Feishu
  rate-limits per app. `feishu_mirror_containers` holds one watermark per
  walked container — a chat's top-level history or one thread — keyed the way
  ClickHouse keys the rows.

  Commits are monotone so any number of walkers can commit without a fence:
  `indexed_from_us` only moves down, `indexed_to_us` is set once, and
  `exhausted` only becomes true. A stale walker can at worst write an older
  page token, which costs a re-walk of rows the mirror absorbs. All clocks are
  the database's.
  """

  alias SalixStore.Repo

  @container_types ~w(chat thread)

  # ---- installations ----

  @doc "Records installations to walk. Existing rows keep their schedule."
  @spec upsert_connects([map()]) :: :ok | {:error, term()}
  def upsert_connects([]), do: :ok

  def upsert_connects(connects) when is_list(connects) do
    rows =
      connects
      |> Enum.filter(fn c ->
        Enum.all?(~w(connect_id tenant_id group_id), &(is_binary(c[&1]) and c[&1] != ""))
      end)
      |> Enum.map(&Map.take(&1, ~w(connect_id tenant_id group_id)))

    safe_query(fn ->
      Repo.query!(
        """
        INSERT INTO feishu_mirror_backfill_connects
          (connect_id, tenant_id, group_id, due_at, updated_at)
        SELECT r.connect_id, r.tenant_id, r.group_id,
               timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
        FROM jsonb_to_recordset($1::jsonb) AS r(connect_id text, tenant_id text, group_id text)
        ON CONFLICT (connect_id) DO UPDATE
          SET tenant_id = EXCLUDED.tenant_id, group_id = EXCLUDED.group_id
        """,
        [rows]
      )

      :ok
    end)
  end

  @doc """
  Leases the installation that has been due the longest.

  `:empty` when nothing is due. Expiry of the lease is release.
  """
  @spec claim_due_connect(pos_integer()) :: {:ok, map()} | :empty | {:error, term()}
  def claim_due_connect(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    safe_query(fn ->
      case Repo.query!(
             """
             UPDATE feishu_mirror_backfill_connects
             SET leased_until = timezone('UTC', clock_timestamp()) + ($1 * interval '1 millisecond'),
                 updated_at = timezone('UTC', clock_timestamp())
             WHERE connect_id = (
               SELECT connect_id FROM feishu_mirror_backfill_connects
               WHERE due_at <= timezone('UTC', clock_timestamp())
                 AND (leased_until IS NULL OR leased_until < timezone('UTC', clock_timestamp()))
               ORDER BY due_at
               LIMIT 1
               FOR UPDATE SKIP LOCKED
             )
             RETURNING connect_id, tenant_id, group_id
             """,
             [ttl_ms]
           ) do
        %{rows: [[connect_id, tenant_id, group_id]]} ->
          {:ok, %{"connect_id" => connect_id, "tenant_id" => tenant_id, "group_id" => group_id}}

        %{rows: []} ->
          :empty
      end
    end)
  end

  @doc "Releases the lease and makes the installation due again after `delay_ms`."
  @spec finish_connect(String.t(), non_neg_integer(), term()) :: :ok | {:error, term()}
  def finish_connect(connect_id, delay_ms, error)
      when is_binary(connect_id) and is_integer(delay_ms) and delay_ms >= 0 do
    safe_query(fn ->
      Repo.query!(
        """
        UPDATE feishu_mirror_backfill_connects
        SET leased_until = NULL,
            due_at = timezone('UTC', clock_timestamp()) + ($2 * interval '1 millisecond'),
            last_error = $3,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE connect_id = $1
        """,
        [connect_id, delay_ms, error_text(error)]
      )

      :ok
    end)
  end

  @doc "Forgets an installation that is no longer reachable. Watermarks stay."
  @spec delete_connect(String.t()) :: :ok | {:error, term()}
  def delete_connect(connect_id) when is_binary(connect_id) do
    safe_query(fn ->
      Repo.query!("DELETE FROM feishu_mirror_backfill_connects WHERE connect_id = $1", [
        connect_id
      ])

      :ok
    end)
  end

  # ---- containers ----

  @doc "Records containers to walk. Existing watermarks are untouched."
  @spec upsert_containers(map(), [map()]) :: :ok | {:error, term()}
  def upsert_containers(_scope, []), do: :ok

  def upsert_containers(%{"tenant_id" => tenant_id, "app_id" => app_id}, containers)
      when is_binary(tenant_id) and is_binary(app_id) and is_list(containers) do
    rows =
      containers
      |> Enum.filter(&valid_container?/1)
      |> Enum.map(&Map.take(&1, ~w(container_type container_id chat_id)))
      |> Enum.uniq_by(&{&1["container_type"], &1["container_id"]})

    safe_query(fn ->
      Repo.query!(
        """
        INSERT INTO feishu_mirror_containers
          (tenant_id, app_id, container_type, container_id, chat_id, updated_at)
        SELECT $1, $2, r.container_type, r.container_id, r.chat_id, timezone('UTC', clock_timestamp())
        FROM jsonb_to_recordset($3::jsonb)
          AS r(container_type text, container_id text, chat_id text)
        ON CONFLICT (tenant_id, app_id, container_type, container_id) DO NOTHING
        """,
        [tenant_id, app_id, rows]
      )

      :ok
    end)
  end

  @doc "Up to `limit` unfinished containers, least recently touched first."
  @spec next_containers(map(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def next_containers(%{"tenant_id" => tenant_id, "app_id" => app_id}, limit)
      when is_binary(tenant_id) and is_binary(app_id) and is_integer(limit) and limit > 0 do
    safe_query(fn ->
      %{rows: rows} =
        Repo.query!(
          """
          SELECT container_type, container_id, chat_id, indexed_from_us, indexed_to_us, page_token
          FROM feishu_mirror_containers
          WHERE tenant_id = $1 AND app_id = $2 AND NOT exhausted
          ORDER BY updated_at, container_type, container_id
          LIMIT $3
          """,
          [tenant_id, app_id, limit]
        )

      {:ok,
       Enum.map(rows, fn [type, id, chat_id, from, to, token] ->
         %{
           "container_type" => type,
           "container_id" => id,
           "chat_id" => chat_id,
           "indexed_from_us" => from,
           "indexed_to_us" => to,
           "page_token" => token
         }
       end)}
    end)
  end

  @doc """
  Commits one landed page.

  `oldest_us` is the oldest create time on the page (nil for an empty page),
  `observed_us` the cut taken before the first page's request, `page_token`
  the continuation (nil when Feishu said there is nothing older).
  """
  @spec commit_page(map(), map(), map()) :: :ok | {:error, term()}
  def commit_page(scope, container, page) do
    safe_query(fn ->
      Repo.query!(
        """
        UPDATE feishu_mirror_containers
        SET indexed_from_us = CASE
              WHEN $5::bigint IS NULL THEN indexed_from_us
              ELSE LEAST(COALESCE(indexed_from_us, $5::bigint), $5::bigint) END,
            indexed_to_us = COALESCE(indexed_to_us, $6::bigint),
            page_token = $7,
            exhausted = exhausted OR $8,
            last_error = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_id = $1 AND app_id = $2 AND container_type = $3 AND container_id = $4
        """,
        [
          scope["tenant_id"],
          scope["app_id"],
          container["container_type"],
          container["container_id"],
          page["oldest_us"],
          page["observed_us"],
          page["page_token"],
          page["exhausted"] == true
        ]
      )

      :ok
    end)
  end

  @doc """
  Records a failed page. The page token is dropped, so the next attempt
  restarts from a position the walker can recompute; the watermark stays.
  """
  @spec fail_container(map(), map(), term()) :: :ok | {:error, term()}
  def fail_container(scope, container, reason) do
    safe_query(fn ->
      Repo.query!(
        """
        UPDATE feishu_mirror_containers
        SET page_token = NULL, last_error = $5, updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_id = $1 AND app_id = $2 AND container_type = $3 AND container_id = $4
        """,
        [
          scope["tenant_id"],
          scope["app_id"],
          container["container_type"],
          container["container_id"],
          error_text(reason)
        ]
      )

      :ok
    end)
  end

  @doc """
  Search coverage for one app, optionally one chat, from `after_us` onward.

  `:not_synced` when no container is known yet. Otherwise `:complete`, or
  `{:incomplete, older_than_us}` when some container is not walked back to
  `after_us`; `older_than_us` is the newest such watermark, or nil when one has
  not landed its first page. One aggregate over the app's key prefix.
  """
  @spec coverage(map(), String.t() | nil, non_neg_integer()) ::
          {:ok, :not_synced | :complete | {:incomplete, non_neg_integer() | nil}}
          | {:error, term()}
  def coverage(%{"tenant_id" => tenant_id, "app_id" => app_id}, chat_id, after_us)
      when is_binary(tenant_id) and is_binary(app_id) and is_integer(after_us) and after_us >= 0 do
    safe_query(fn ->
      %{rows: [[total, holes, unstarted, older]]} =
        Repo.query!(
          """
          SELECT count(*),
                 count(*) FILTER (WHERE hole),
                 count(*) FILTER (WHERE hole AND indexed_from_us IS NULL),
                 max(indexed_from_us) FILTER (WHERE hole)
          FROM (
            SELECT indexed_from_us,
                   NOT exhausted AND (indexed_from_us IS NULL OR indexed_from_us > $4) AS hole
            FROM feishu_mirror_containers
            WHERE tenant_id = $1 AND app_id = $2 AND ($3::text IS NULL OR chat_id = $3)
          ) c
          """,
          [tenant_id, app_id, chat_id, after_us]
        )

      cond do
        total == 0 -> {:ok, :not_synced}
        holes == 0 -> {:ok, :complete}
        unstarted > 0 -> {:ok, {:incomplete, nil}}
        true -> {:ok, {:incomplete, older}}
      end
    end)
  end

  defp valid_container?(container) when is_map(container) do
    container["container_type"] in @container_types and
      Enum.all?(~w(container_id chat_id), &(is_binary(container[&1]) and container[&1] != ""))
  end

  defp valid_container?(_container), do: false

  defp error_text(nil), do: nil
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp safe_query(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
