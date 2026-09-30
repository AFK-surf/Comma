defmodule SalixAnalytics.SlackMirror.Reader do
  @moduledoc """
  Bounded, tenant-scoped read adapter for the shared Slack message mirror.

  The adapter owns ClickHouse SQL and decoding only. Authority, scheduling,
  admission, receipt creation, and cursor settlement stay in `salix_im`.

  Reaction and pin overlay: `tla/salix/SlackMirrorComponents.tla`.
  """

  alias SalixAnalytics.ClickHouseRead

  @max_page 200
  @max_serve_limit 1_000
  @default_thread_limit 200
  @default_thread_max_bytes 1_048_576
  @scope_keys ~w(tenant_id workspace_id channel_id)
  @search_option_keys [
    :limit,
    :patterns,
    :exclude_patterns,
    :actor_id,
    :channel_id,
    :after_us,
    :after_date,
    :before_us,
    :before_date,
    :has_file,
    :cursor_ts_us,
    :cursor_channel_id,
    :sort_dir
  ]
  @default_search_limit 30
  @max_search_limit 200
  @max_search_terms 8
  @cursor_keys ~w(ingest_at message_ts_us version)
  @window_keys ~w(lower_bound page_after tail)
  @row_keys ~w(
    tenant_id workspace_id channel_id message_ts_us message_ts thread_ts version
    deleted actor_kind actor_id actor_label subtype text ingest_at
  )
  @thread_row_keys @row_keys ++ ["payload"]
  @zero_cursor %{
    "ingest_at" => "1970-01-01T00:00:00.000Z",
    "message_ts_us" => 0,
    "version" => 0
  }
  @reaction_keys ~w(message_ts_us message_ts reaction count)
  @index_keys ~w(message_ts_us payload_bytes text_bytes)
  @thread_option_keys [:limit, :max_bytes]
  @serve_option_keys [:limit, :cursor, :oldest, :latest, :inclusive]
  @default_serve_limit 100
  @serve_row_keys @thread_row_keys
  @pin_keys ~w(message_ts_us message_ts pinned_by pinned_ts version deleted)
  @metadata_keys ~w(message_ts_us message_ts deleted metadata)
  @payload_lookup_keys ~w(message_ts_us payload observed_ts_us)
  @reaction_row_keys ~w(message_ts_us user_id reaction version deleted)
  @reaction_pair_keys ~w(channel_id message_ts_us user_id reaction version deleted)

  @spec tail(map()) :: {:ok, map()} | {:error, term()}
  def tail(scope) when is_map(scope) do
    with :ok <- validate_scope(scope),
         {:ok, rows} <-
           ClickHouseRead.run(
             &tail_sql/1,
             [
               tenant_id: scope["tenant_id"],
               workspace_id: scope["workspace_id"],
               channel_id: scope["channel_id"]
             ],
             query: "slack_mirror_tail"
           ),
         {:ok, cursor} <- decode_tail(rows) do
      {:ok, cursor}
    end
  end

  def tail(_scope), do: {:error, :invalid_slack_mirror_scope}

  @doc """
  Incremental ingest window for Triage ETL.

  The window is `slack_message_event_triggers` — live webhook observations —
  joined to the current `slack_messages` row for content. History backfill
  never writes the trigger table, so a later reconstruction of the same
  physical message cannot drop a trigger that patrol has not consumed.
  `tail/1` is the latest trigger, not the latest reconstructed row. The
  returned `version` is the trigger's, so a later rewrite of
  `slack_messages.version` cannot push the patrol cursor past the tail.
  """
  @spec list_changes(map(), map(), pos_integer()) ::
          {:ok, %{rows: [map()], next_cursor: map() | nil, has_more?: boolean()}}
          | {:error, term()}
  def list_changes(scope, window, limit)
      when is_map(scope) and is_map(window) and is_integer(limit) and limit in 1..@max_page do
    with :ok <- validate_scope(scope),
         :ok <- validate_window(window),
         {:ok, rows} <-
           ClickHouseRead.run(
             &changes_sql/1,
             change_binds(scope, window, limit),
             query: "slack_mirror_changes"
           ),
         {:ok, normalized} <- normalize_rows(rows, scope) do
      page = Enum.take(normalized, limit)

      {:ok,
       %{
         rows: page,
         next_cursor: next_cursor(page, window["page_after"]),
         has_more?: length(normalized) > limit
       }}
    end
  end

  def list_changes(_scope, _cursor, _limit), do: {:error, :invalid_slack_mirror_read}

  @spec latest_states(map(), [non_neg_integer()]) ::
          {:ok, %{optional(integer()) => map()}} | {:error, term()}
  def latest_states(scope, []) when is_map(scope) do
    with :ok <- validate_scope(scope), do: {:ok, %{}}
  end

  def latest_states(scope, message_ts_us_values)
      when is_map(scope) and is_list(message_ts_us_values) and
             length(message_ts_us_values) <= @max_page do
    keys = Enum.uniq(message_ts_us_values)

    with :ok <- validate_scope(scope),
         true <- keys != [] and Enum.all?(keys, &valid_uint?/1),
         {:ok, rows} <-
           ClickHouseRead.run(
             &latest_states_sql(&1, length(keys)),
             latest_state_binds(scope, keys),
             query: "slack_mirror_latest_states"
           ),
         {:ok, normalized} <- normalize_rows(rows, scope),
         true <- Enum.all?(normalized, &(&1["message_ts_us"] in keys)),
         true <-
           normalized |> Enum.map(& &1["message_ts_us"]) |> Enum.uniq() |> length() ==
             length(normalized) do
      {:ok, Map.new(normalized, &{&1["message_ts_us"], &1})}
    else
      false -> {:error, :invalid_slack_mirror_read}
      {:error, _reason} = error -> error
    end
  end

  def latest_states(_scope, _message_ts_us_values), do: {:error, :invalid_slack_mirror_read}

  @doc "Reads one exact thread's current message and reaction state within fixed budgets."
  @spec read_thread(map(), String.t(), keyword()) ::
          {:ok,
           %{
             messages: [map()],
             reactions: [map()],
             complete?: boolean(),
             truncated_reason: :count | :bytes | nil
           }}
          | {:error, term()}
  def read_thread(scope, root_ts, opts \\ [])

  def read_thread(scope, root_ts, opts)
      when is_map(scope) and is_binary(root_ts) and is_list(opts) do
    with :ok <- validate_scope(scope),
         {:ok, root_ts_us} <- slack_ts_micros(root_ts),
         {:ok, limit, max_bytes} <- validate_thread_options(opts),
         {:ok, index} <- read_thread_index(scope, root_ts, root_ts_us, limit),
         {:ok, selected, truncated} <- select_thread_index(index, limit, max_bytes),
         {:ok, rows} <- read_thread_messages(scope, selected),
         :ok <- validate_thread_rows(rows, root_ts, root_ts_us) do
      case truncated do
        nil -> complete_thread(scope, rows, max_bytes)
        reason -> {:ok, incomplete_thread(live_messages(rows), reason)}
      end
    end
  end

  def read_thread(_scope, _root_ts, _opts), do: {:error, :invalid_slack_mirror_read}

  @doc "Reads current channel activity since the batch began and its participating threads."
  # Keep post-seal messages visible, just as read_thread/3 does. The event cutoff
  # still anchors the decision; later context can show that people answered it.
  def read_channel(scope, window, opts \\ [])

  def read_channel(scope, window, opts) when is_map(scope) and is_map(window) and is_list(opts) do
    with :ok <- validate_scope(scope),
         {:ok, limit, max_bytes} <- validate_thread_options(opts),
         {:ok, oldest, latest, roots} <- validate_channel_window(window),
         {:ok, index} <- read_channel_index(scope, oldest, latest, roots, limit),
         {:ok, selected, truncated} <- select_thread_index(index, limit, max_bytes),
         {:ok, rows} <- read_thread_messages(scope, selected),
         true <- Enum.all?(rows, &channel_window_member?(&1, oldest, latest, roots)) do
      case truncated do
        nil -> complete_thread(scope, rows, max_bytes)
        reason -> {:ok, incomplete_thread(live_messages(rows), reason)}
      end
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  def read_channel(_scope, _window, _opts), do: {:error, :invalid_slack_mirror_read}

  defp validate_channel_window(
         %{
           "oldest_ts_us" => oldest,
           "latest_ts_us" => latest,
           "thread_roots" => roots
         } = window
       ) do
    with true <- Enum.sort(Map.keys(window)) == ~w(latest_ts_us oldest_ts_us thread_roots),
         true <- is_integer(oldest) and oldest >= 0 and is_integer(latest) and latest >= oldest,
         true <- is_list(roots) and length(roots) in 1..200,
         true <- roots == Enum.sort(Enum.uniq(roots)),
         true <- Enum.all?(roots, &match?({:ok, _}, slack_ts_micros(&1))) do
      {:ok, oldest, latest, roots}
    else
      _invalid -> {:error, :invalid_slack_mirror_read}
    end
  end

  defp validate_channel_window(_window), do: {:error, :invalid_slack_mirror_read}

  defp channel_window_member?(row, oldest, _latest, roots) do
    row["message_ts_us"] >= oldest or row["thread_ts"] in roots or row["message_ts"] in roots
  end

  defp read_channel_index(scope, oldest, _latest, roots, limit) do
    binds = [
      tenant_id: scope["tenant_id"],
      workspace_id: scope["workspace_id"],
      channel_id: scope["channel_id"],
      oldest_ts_us: oldest,
      roots: "[" <> Enum.map_join(roots, ",", &"'#{&1}'") <> "]",
      limit: limit + 1
    ]

    with {:ok, rows} <-
           ClickHouseRead.run(&channel_index_sql/1, binds, query: "slack_mirror_channel"),
         true <- valid_thread_index?(rows) do
      {:ok, rows}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp channel_index_sql(database) do
    """
    SELECT message_ts_us, length(payload) AS payload_bytes, length(text) AS text_bytes
    FROM #{database}.slack_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (message_ts_us >= {oldest_ts_us:UInt64}
        OR thread_ts IN {roots:Array(String)} OR message_ts IN {roots:Array(String)})
    ORDER BY message_ts_us ASC
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  @doc "Channel-visible current messages, newest first. Substitutes conversations.history."
  @spec history(map(), keyword()) ::
          {:ok, %{messages: [map()], next_cursor: String.t() | nil, has_more?: boolean()}}
          | {:error, term()}
  def history(scope, opts \\ [])

  def history(scope, opts) when is_map(scope) and is_list(opts) do
    with {:ok, page} <- serve(scope, :history, nil, opts),
         {:ok, messages} <- with_reply_counts(scope, page.messages) do
      {:ok, %{page | messages: messages}}
    end
  end

  def history(_scope, _opts), do: {:error, :invalid_slack_mirror_read}

  # Payload reply_count is an observation at the time the parent was saved,
  # not the current archive count. One tenant/channel-scoped query for this
  # bounded page (at most @max_serve_limit roots), never one query per parent.
  defp with_reply_counts(_scope, []), do: {:ok, []}

  defp with_reply_counts(scope, messages) do
    roots = Enum.map(messages, & &1["ts"])

    with {:ok, rows} <-
           ClickHouseRead.run(
             &reply_counts_sql(&1, length(roots)),
             latest_state_binds(scope, roots),
             query: "slack_mirror_thread"
           ),
         true <-
           Enum.all?(rows, fn row ->
             row["thread_ts"] in roots and is_integer(row["reply_count"]) and
               row["reply_count"] >= 0
           end),
         true <- length(rows) <= length(roots) do
      counts = Map.new(rows, &{&1["thread_ts"], &1["reply_count"]})
      {:ok, Enum.map(messages, &Map.put(&1, "reply_count", Map.get(counts, &1["ts"], 0)))}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp reply_counts_sql(database, count) do
    roots = Enum.map_join(0..(count - 1), ", ", &"{message_ts_us_#{&1}:String}")

    """
    SELECT thread_ts, count() AS reply_count
    FROM #{database}.slack_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND thread_ts IN (#{roots})
      AND message_ts != thread_ts
      AND deleted = false
    GROUP BY thread_ts
    LIMIT #{count}
    FORMAT JSONEachRow
    """
  end

  @doc "One thread's current messages, oldest first. Substitutes conversations.replies."
  @spec replies(map(), String.t(), keyword()) ::
          {:ok, %{messages: [map()], next_cursor: String.t() | nil, has_more?: boolean()}}
          | {:error, term()}
  def replies(scope, root_ts, opts \\ [])

  def replies(scope, root_ts, opts)
      when is_map(scope) and is_binary(root_ts) and is_list(opts) do
    serve(scope, :replies, root_ts, opts)
  end

  def replies(_scope, _root_ts, _opts), do: {:error, :invalid_slack_mirror_read}

  @doc """
  Workspace- or channel-scoped keyword search, newest first by default.

  Structured opts only. `patterns` is one AND-group of ILIKE needles, or a
  list of AND-groups ORed together. `exclude_patterns` apply to the whole
  query and match message content, not serialized Block Kit keys.
  Completeness and stale marks are applied by `MessageRead`. Cursor
  is `{message_ts_us, channel_id}`.
  """
  @spec search(map(), keyword()) ::
          {:ok,
           %{
             messages: [map()],
             next_cursor: {non_neg_integer(), String.t()} | nil,
             has_more?: boolean()
           }}
          | {:error, term()}
  def search(scope, opts \\ [])

  def search(scope, opts) when is_map(scope) and is_list(opts) do
    with :ok <- validate_workspace_scope(scope),
         {:ok, parsed} <- validate_search_options(opts),
         {:ok, rows} <-
           ClickHouseRead.run(
             &search_sql(&1, parsed),
             search_binds(scope, parsed),
             query: "slack_mirror_search"
           ),
         {:ok, normalized} <- normalize_search_rows(rows, scope, parsed.channel_id) do
      page = Enum.take(normalized, parsed.limit)
      has_more? = length(normalized) > parsed.limit
      overlay_search_page(scope, page, has_more?)
    end
  end

  def search(_scope, _opts), do: {:error, :invalid_slack_mirror_read}

  defp ingest_at_iso8601_sql(column) do
    # DateTime64(3) toString preserves zero-padded milliseconds; the
    # Joda SSS formatter can emit malformed bytes for values below 100 ms.
    "concat(replaceOne(toString(#{column}, 'UTC'), ' ', 'T'), 'Z')"
  end

  defp changes_sql(database) do
    """
    SELECT
      messages.tenant_id AS tenant_id,
      messages.workspace_id AS workspace_id,
      messages.channel_id AS channel_id,
      messages.message_ts_us AS message_ts_us,
      messages.message_ts AS message_ts,
      messages.thread_ts AS thread_ts,
      triggers.version AS version,
      messages.deleted AS deleted,
      messages.actor_kind AS actor_kind,
      messages.actor_id AS actor_id,
      messages.actor_label AS actor_label,
      messages.subtype AS subtype,
      messages.text AS text,
      #{ingest_at_iso8601_sql("triggers.ingest_at")} AS ingest_at
    FROM #{database}.slack_message_event_triggers AS triggers FINAL
    INNER JOIN #{database}.slack_messages AS messages FINAL ON
      messages.tenant_id = triggers.tenant_id
      AND messages.workspace_id = triggers.workspace_id
      AND messages.channel_id = triggers.channel_id
      AND messages.message_ts_us = triggers.message_ts_us
    WHERE triggers.tenant_id = {tenant_id:String}
      AND triggers.workspace_id = {workspace_id:String}
      AND triggers.channel_id = {channel_id:String}
      AND (triggers.ingest_at, triggers.message_ts_us, triggers.version) >=
        (parseDateTime64BestEffort({lower_ingest_at:String}),
         {lower_message_ts_us:UInt64}, {lower_version:UInt64})
      AND (triggers.ingest_at, triggers.message_ts_us, triggers.version) <=
        (parseDateTime64BestEffort({tail_ingest_at:String}),
         {tail_message_ts_us:UInt64}, {tail_version:UInt64})
      AND (
        {has_page_after:UInt8} = 0 OR
        (triggers.ingest_at, triggers.message_ts_us, triggers.version) >
          (parseDateTime64BestEffort({after_ingest_at:String}),
           {after_message_ts_us:UInt64}, {after_version:UInt64})
      )
    ORDER BY triggers.ingest_at ASC, triggers.message_ts_us ASC, triggers.version ASC
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  defp change_binds(scope, window, limit) do
    lower = window["lower_bound"]
    after_cursor = window["page_after"] || lower
    tail = window["tail"]

    [
      tenant_id: scope["tenant_id"],
      workspace_id: scope["workspace_id"],
      channel_id: scope["channel_id"],
      lower_ingest_at: lower["ingest_at"],
      lower_message_ts_us: lower["message_ts_us"],
      lower_version: lower["version"],
      tail_ingest_at: tail["ingest_at"],
      tail_message_ts_us: tail["message_ts_us"],
      tail_version: tail["version"],
      has_page_after: if(is_nil(window["page_after"]), do: 0, else: 1),
      after_ingest_at: after_cursor["ingest_at"],
      after_message_ts_us: after_cursor["message_ts_us"],
      after_version: after_cursor["version"],
      limit: limit + 1
    ]
  end

  defp tail_sql(database) do
    """
    SELECT
      #{ingest_at_iso8601_sql("triggers.ingest_at")} AS ingest_at,
      triggers.message_ts_us AS message_ts_us,
      triggers.version AS version
    FROM #{database}.slack_message_event_triggers AS triggers FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
    ORDER BY triggers.ingest_at DESC, triggers.message_ts_us DESC, triggers.version DESC
    LIMIT 1
    FORMAT JSONEachRow
    """
  end

  defp latest_states_sql(database, key_count) do
    predicates =
      0..(key_count - 1)
      |> Enum.map_join(" OR ", fn index ->
        "message_ts_us = {message_ts_us_#{index}:UInt64}"
      end)

    """
    SELECT
      tenant_id, workspace_id, channel_id, message_ts_us, message_ts, thread_ts,
      version, deleted, actor_kind, actor_id, actor_label, subtype, text,
      #{ingest_at_iso8601_sql("messages.ingest_at")} AS ingest_at
    FROM #{database}.slack_messages AS messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (#{predicates})
    ORDER BY message_ts_us ASC
    FORMAT JSONEachRow
    """
  end

  defp thread_index_sql(database) do
    """
    SELECT
      message_ts_us,
      length(payload) AS payload_bytes,
      length(text) AS text_bytes
    FROM #{database}.slack_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (message_ts_us = {root_ts_us:UInt64} OR thread_ts = {root_ts:String})
    ORDER BY message_ts_us ASC
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  defp thread_sql(database, key_count) do
    predicates =
      0..(key_count - 1)
      |> Enum.map_join(" OR ", fn index ->
        "message_ts_us = {message_ts_us_#{index}:UInt64}"
      end)

    """
    SELECT
      tenant_id, workspace_id, channel_id, message_ts_us, message_ts, thread_ts,
      version, deleted, actor_kind, actor_id, actor_label, subtype, text,
      #{ingest_at_iso8601_sql("ingest_at")} AS ingest_at,
      payload
    FROM #{database}.slack_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (#{predicates})
    ORDER BY message_ts_us ASC
    FORMAT JSONEachRow
    """
  end

  defp reaction_sql(database, key_count) do
    predicates =
      0..(key_count - 1)
      |> Enum.map_join(" OR ", fn index ->
        "message_ts_us = {message_ts_us_#{index}:UInt64}"
      end)

    """
    SELECT
      message_ts_us,
      any(message_ts) AS message_ts,
      reaction,
      count() AS count
    FROM (
      SELECT
        message_ts_us,
        any(message_ts) AS message_ts,
        reaction,
        argMax(deleted, version) AS deleted
      FROM #{database}.slack_message_reaction_deltas FINAL
      WHERE tenant_id = {tenant_id:String}
        AND workspace_id = {workspace_id:String}
        AND channel_id = {channel_id:String}
        AND (#{predicates})
      GROUP BY message_ts_us, user_id, reaction
    )
    WHERE deleted = false
    GROUP BY message_ts_us, reaction
    ORDER BY message_ts_us ASC, reaction ASC
    FORMAT JSONEachRow
    """
  end

  defp latest_state_binds(scope, keys) do
    [
      tenant_id: scope["tenant_id"],
      workspace_id: scope["workspace_id"],
      channel_id: scope["channel_id"]
    ] ++
      Enum.with_index(keys, fn key, index -> {String.to_atom("message_ts_us_#{index}"), key} end)
  end

  defp read_thread_index(scope, root_ts, root_ts_us, limit) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &thread_index_sql/1,
             [
               tenant_id: scope["tenant_id"],
               workspace_id: scope["workspace_id"],
               channel_id: scope["channel_id"],
               root_ts: root_ts,
               root_ts_us: root_ts_us,
               limit: limit + 1
             ],
             query: "slack_mirror_thread"
           ),
         true <- valid_thread_index?(rows) do
      {:ok, rows}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp select_thread_index(index, limit, max_bytes) do
    page = Enum.take(index, limit)
    over_count? = length(index) > limit

    case take_fitting(page, max_bytes) do
      {:overflow, selected} -> {:ok, selected, :bytes}
      {:ok, selected} when over_count? -> {:ok, selected, :count}
      {:ok, selected} -> {:ok, selected, nil}
    end
  end

  defp take_fitting(rows, max_bytes) do
    rows
    |> Enum.reduce_while({:ok, [], 0}, fn row, {:ok, acc, used} ->
      size = row["payload_bytes"] + row["text_bytes"]

      cond do
        acc == [] and size > max_bytes -> {:halt, {:overflow, []}}
        used + size > max_bytes -> {:halt, {:overflow, Enum.reverse(acc)}}
        true -> {:cont, {:ok, [row | acc], used + size}}
      end
    end)
    |> case do
      {:ok, acc, _used} -> {:ok, Enum.reverse(acc)}
      {:overflow, selected} -> {:overflow, selected}
    end
  end

  defp read_thread_messages(_scope, []), do: {:ok, []}

  defp read_thread_messages(scope, selected) do
    keys = Enum.map(selected, & &1["message_ts_us"])

    with {:ok, rows} <-
           ClickHouseRead.run(
             &thread_sql(&1, length(keys)),
             latest_state_binds(scope, keys),
             query: "slack_mirror_thread"
           ),
         {:ok, normalized} <- normalize_rows(rows, scope, @thread_row_keys),
         true <- Enum.all?(normalized, &(&1["message_ts_us"] in keys)),
         true <-
           normalized |> Enum.map(& &1["message_ts_us"]) |> Enum.uniq() |> length() ==
             length(keys) do
      {:ok, Enum.sort_by(normalized, & &1["message_ts_us"])}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp complete_thread(scope, rows, max_bytes) do
    live = live_messages(rows)
    used = Enum.reduce(rows, 0, &(message_bytes(&1) + &2))

    with {:ok, reactions} <- read_reactions(scope, rows),
         true <- used + reaction_bytes(reactions) <= max_bytes do
      {:ok,
       %{
         messages: live,
         reactions: reactions,
         complete?: true,
         truncated_reason: nil
       }}
    else
      false -> {:ok, incomplete_thread(live, :bytes)}
      {:error, _reason} = error -> error
    end
  end

  defp live_messages(rows), do: Enum.reject(rows, & &1["deleted"])

  defp valid_thread_index?(rows) when is_list(rows) do
    rows == Enum.sort_by(rows, & &1["message_ts_us"]) and
      Enum.all?(rows, fn row ->
        exact_keys?(row, @index_keys) and valid_uint?(row["message_ts_us"]) and
          valid_uint?(row["payload_bytes"]) and valid_uint?(row["text_bytes"])
      end)
  end

  defp valid_thread_index?(_rows), do: false

  defp read_reactions(_scope, []), do: {:ok, []}

  defp read_reactions(scope, messages) do
    keys = Enum.map(messages, & &1["message_ts_us"])

    binds =
      [
        tenant_id: scope["tenant_id"],
        workspace_id: scope["workspace_id"],
        channel_id: scope["channel_id"]
      ] ++
        Enum.with_index(keys, fn key, index ->
          {String.to_atom("message_ts_us_#{index}"), key}
        end)

    with {:ok, rows} <-
           ClickHouseRead.run(&reaction_sql(&1, length(keys)), binds,
             query: "slack_mirror_thread_reactions"
           ),
         true <- valid_reactions?(rows, messages) do
      {:ok, rows}
    else
      false -> {:error, :invalid_slack_mirror_reaction_row}
      {:error, _reason} = error -> error
    end
  end

  defp valid_reactions?(rows, messages) when is_list(rows) do
    message_keys = MapSet.new(messages, & &1["message_ts_us"])

    Enum.all?(rows, fn row ->
      exact_keys?(row, @reaction_keys) and
        MapSet.member?(message_keys, row["message_ts_us"]) and
        is_binary(row["message_ts"]) and row["message_ts"] != "" and
        is_binary(row["reaction"]) and row["reaction"] != "" and
        is_integer(row["count"]) and row["count"] > 0
    end)
  end

  defp valid_reactions?(_rows, _messages), do: false

  defp validate_thread_rows(rows, root_ts, root_ts_us) do
    valid? =
      rows == Enum.sort_by(rows, & &1["message_ts_us"]) and
        Enum.all?(rows, fn row ->
          row["message_ts_us"] == root_ts_us or row["thread_ts"] == root_ts
        end)

    if valid?, do: :ok, else: {:error, :invalid_slack_mirror_row}
  end

  defp validate_thread_options(opts) do
    keys = Keyword.keys(opts)
    limit = Keyword.get(opts, :limit, @default_thread_limit)
    max_bytes = Keyword.get(opts, :max_bytes, @default_thread_max_bytes)

    valid? =
      Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
        Enum.all?(keys, &(&1 in @thread_option_keys)) and is_integer(limit) and
        limit in 1..@max_page and is_integer(max_bytes) and max_bytes > 0 and
        max_bytes <= @default_thread_max_bytes

    if valid?,
      do: {:ok, limit, max_bytes},
      else: {:error, :invalid_slack_mirror_read}
  end

  defp slack_ts_micros(value) do
    with [seconds, micros] <- String.split(value, ".", parts: 2),
         true <- byte_size(micros) in 1..6,
         {seconds, ""} when seconds >= 0 <- Integer.parse(seconds),
         {micros, ""} when micros >= 0 <-
           micros |> String.pad_trailing(6, "0") |> Integer.parse() do
      {:ok, seconds * 1_000_000 + micros}
    else
      _invalid -> {:error, :invalid_slack_mirror_read}
    end
  end

  defp incomplete_thread(messages, reason) do
    %{messages: messages, reactions: [], complete?: false, truncated_reason: reason}
  end

  defp message_bytes(row),
    do: byte_size(row["text"] || "") + byte_size(row["payload"] || "")

  defp reaction_bytes(rows),
    do: Enum.reduce(rows, 0, &(byte_size(&1["reaction"]) + byte_size(&1["message_ts"]) + &2))

  defp normalize_rows(rows, scope, keys \\ @row_keys)

  defp normalize_rows(rows, scope, keys) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      if valid_row?(row, scope, keys),
        do: {:cont, {:ok, [row | acc]}},
        else: {:halt, {:error, :invalid_slack_mirror_row}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp normalize_rows(_rows, _scope, _keys), do: {:error, :invalid_slack_mirror_row}

  defp decode_tail([]), do: {:ok, @zero_cursor}

  defp decode_tail([cursor]) do
    case validate_cursor(cursor) do
      :ok -> {:ok, cursor}
      {:error, _reason} -> {:error, :invalid_slack_mirror_row}
    end
  end

  defp decode_tail(_rows), do: {:error, :invalid_slack_mirror_row}

  defp valid_row?(row, scope, keys) when is_map(row) do
    exact_keys?(row, keys) and
      Enum.all?(@scope_keys, &(row[&1] == scope[&1])) and
      valid_uint?(row["message_ts_us"]) and valid_uint?(row["version"]) and
      is_boolean(row["deleted"]) and
      Enum.all?(
        ~w(message_ts thread_ts actor_kind actor_id actor_label subtype text ingest_at),
        &is_binary(row[&1])
      ) and
      (not Enum.member?(keys, "payload") or is_binary(row["payload"])) and
      valid_iso8601?(row["ingest_at"])
  end

  defp valid_row?(_row, _scope, _keys), do: false

  defp validate_scope(scope) do
    if exact_keys?(scope, @scope_keys) and Enum.all?(@scope_keys, &canonical_nonblank?(scope[&1])),
      do: :ok,
      else: {:error, :invalid_slack_mirror_scope}
  end

  defp validate_workspace_scope(scope) do
    tenant_ok? = canonical_nonblank?(scope["tenant_id"])
    workspace_ok? = canonical_nonblank?(scope["workspace_id"])

    if tenant_ok? and workspace_ok?,
      do: :ok,
      else: {:error, :invalid_slack_mirror_scope}
  end

  defp validate_cursor(cursor) do
    if exact_keys?(cursor, @cursor_keys) and valid_iso8601?(cursor["ingest_at"]) and
         valid_uint?(cursor["message_ts_us"]) and valid_uint?(cursor["version"]),
       do: :ok,
       else: {:error, :invalid_slack_mirror_cursor}
  end

  defp validate_window(window) do
    with true <- exact_keys?(window, @window_keys),
         :ok <- validate_cursor(window["lower_bound"]),
         :ok <- validate_optional_cursor(window["page_after"]),
         :ok <- validate_cursor(window["tail"]),
         true <- compare_cursor(window["lower_bound"], window["tail"]) in [:lt, :eq],
         true <- valid_page_after?(window["page_after"], window) do
      :ok
    else
      _invalid -> {:error, :invalid_slack_mirror_cursor}
    end
  end

  defp validate_optional_cursor(nil), do: :ok
  defp validate_optional_cursor(cursor), do: validate_cursor(cursor)

  defp valid_page_after?(nil, _window), do: true

  defp valid_page_after?(cursor, window) do
    compare_cursor(cursor, window["lower_bound"]) in [:eq, :gt] and
      compare_cursor(cursor, window["tail"]) in [:lt, :eq]
  end

  defp compare_cursor(left, right) do
    left_key = cursor_key(left)
    right_key = cursor_key(right)

    cond do
      left_key < right_key -> :lt
      left_key > right_key -> :gt
      true -> :eq
    end
  end

  defp cursor_key(cursor) do
    {:ok, instant, _offset} = DateTime.from_iso8601(cursor["ingest_at"])
    {DateTime.to_unix(instant, :microsecond), cursor["message_ts_us"], cursor["version"]}
  end

  defp next_cursor([], _cursor), do: nil

  defp next_cursor(rows, _cursor) do
    row = List.last(rows)
    Map.take(row, @cursor_keys)
  end

  defp valid_iso8601?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_iso8601?(_value), do: false
  defp valid_uint?(value), do: is_integer(value) and value >= 0

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)

  defp serve(scope, kind, root_ts, opts) do
    with :ok <- validate_scope(scope),
         {:ok, limit, cursor_us, oldest_us, latest_us, inclusive?} <-
           validate_serve_options(opts),
         {:ok, root_ts_us} <- serve_root_ts(kind, root_ts),
         {:ok, rows} <-
           ClickHouseRead.run(
             &serve_sql(&1, kind),
             serve_binds(
               scope,
               kind,
               root_ts,
               root_ts_us,
               limit,
               cursor_us,
               oldest_us,
               latest_us,
               inclusive?
             ),
             query: "slack_mirror_thread"
           ),
         {:ok, normalized} <- normalize_rows(rows, scope, @serve_row_keys) do
      page = Enum.take(normalized, limit)
      has_more? = length(normalized) > limit
      overlay_page(scope, page, has_more?)
    end
  end

  defp serve_root_ts(:history, _root_ts), do: {:ok, 0}

  defp serve_root_ts(:replies, root_ts) do
    case slack_ts_micros(root_ts) do
      {:ok, us} -> {:ok, us}
      {:error, _reason} -> {:error, :invalid_slack_mirror_read}
    end
  end

  defp overlay_search_page(_scope, [], has_more?) do
    {:ok, %{messages: [], next_cursor: nil, has_more?: has_more?}}
  end

  defp overlay_search_page(scope, page, has_more?) do
    pairs = Enum.map(page, &{&1["channel_id"], &1["message_ts_us"]})

    with {:ok, payloads} <- fetch_payload_pairs(scope, pairs),
         {:ok, reactions} <- fetch_reaction_pairs(scope, pairs),
         {:ok, pins} <- fetch_pin_pairs(scope, pairs),
         {:ok, metadata} <- fetch_metadata_pairs(scope, pairs) do
      messages =
        Enum.map(page, fn row ->
          key = {row["channel_id"], row["message_ts_us"]}

          slack_object(
            row,
            Map.get(payloads, key),
            Map.get(reactions, key),
            Map.get(pins, key),
            Map.get(metadata, key)
          )
          |> Map.put_new("channel", row["channel_id"])
        end)

      last = List.last(page)

      {:ok,
       %{
         messages: messages,
         next_cursor: if(has_more?, do: {last["message_ts_us"], last["channel_id"]}, else: nil),
         has_more?: has_more?
       }}
    end
  end

  defp overlay_page(_scope, [], has_more?) do
    {:ok, %{messages: [], next_cursor: nil, has_more?: has_more?}}
  end

  defp overlay_page(scope, page, has_more?) do
    keys = Enum.map(page, & &1["message_ts_us"])

    with {:ok, payloads} <- fetch_payloads(scope, keys),
         {:ok, reactions} <- fetch_component_reactions(scope, keys),
         {:ok, pins} <- fetch_pins(scope, keys),
         {:ok, metadata} <- fetch_metadata(scope, keys) do
      messages =
        Enum.map(page, fn row ->
          slack_object(
            row,
            Map.get(payloads, row["message_ts_us"]),
            Map.get(reactions, row["message_ts_us"]),
            Map.get(pins, row["message_ts_us"]),
            Map.get(metadata, row["message_ts_us"])
          )
        end)

      {:ok,
       %{
         messages: messages,
         next_cursor: if(has_more?, do: List.last(page)["message_ts"], else: nil),
         has_more?: has_more?
       }}
    end
  end

  defp slack_object(row, stored, reactions, pin, metadata) do
    payload = decode_json(payload_bytes(stored)) || decode_json(row["payload"]) || %{}

    message =
      payload
      |> Map.put("type", payload["type"] || "message")
      |> Map.put("ts", row["message_ts"])
      |> put_if_present("thread_ts", row["thread_ts"])
      |> put_if_present("subtype", row["subtype"])
      |> put_if_present("text", row["text"])

    message
    |> overlay_reactions(reactions, observed_ts_us(stored))
    |> overlay_pin(pin, row["channel_id"])
    |> overlay_metadata(metadata)
  end

  defp payload_bytes(%{"payload" => payload}), do: payload
  defp payload_bytes(payload) when is_binary(payload), do: payload
  defp payload_bytes(_stored), do: nil

  defp observed_ts_us(%{"observed_ts_us" => ts}) when is_integer(ts) and ts > 0, do: ts
  defp observed_ts_us(_stored), do: 0

  defp overlay_reactions(message, nil, _observed_ts_us), do: message

  defp overlay_reactions(message, rows, observed_ts_us) when is_list(rows) do
    case merge_reaction_snapshot(List.wrap(message["reactions"]), rows, observed_ts_us) do
      [] -> Map.delete(message, "reactions")
      merged -> Map.put(message, "reactions", merged)
    end
  end

  # History `count` is authoritative and `users` may be a subset. Deltas are
  # the event stream after the snapshot observation cut, in version order.
  # Events at or before the cut are already in the snapshot (live writer
  # starts before delayed backfill). A tombstone of a hidden snapshot user
  # decrements without going below the listed users; add-then-remove after
  # the cut is two events and nets zero.
  defp merge_reaction_snapshot(baseline, rows, observed_ts_us) do
    baseline
    |> Enum.reduce(%{}, fn entry, acc ->
      name = to_string(entry["name"] || "")
      users = List.wrap(entry["users"]) |> Enum.map(&to_string/1)
      count = reaction_count(entry["count"], users)
      if name == "", do: acc, else: Map.put(acc, name, {count, users})
    end)
    |> then(fn by_name ->
      rows
      |> Enum.sort_by(&reaction_version/1)
      |> Enum.reject(&snapshot_already_includes?(&1, observed_ts_us))
      |> Enum.reduce(by_name, &apply_reaction_delta/2)
    end)
    |> Enum.flat_map(fn {name, {count, users}} ->
      if count <= 0,
        do: [],
        else: [%{"name" => name, "count" => count, "users" => users}]
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp reaction_version(%{"version" => version}) when is_integer(version) and version >= 0,
    do: version

  defp reaction_version(_row), do: 0

  defp reaction_event_ts(row), do: div(reaction_version(row), 2)

  defp snapshot_already_includes?(_row, observed_ts_us)
       when not is_integer(observed_ts_us) or observed_ts_us <= 0,
       do: false

  defp snapshot_already_includes?(row, observed_ts_us),
    do: reaction_event_ts(row) <= observed_ts_us

  defp apply_reaction_delta(row, by_name) do
    name = to_string(row["reaction"] || "")
    user = to_string(row["user_id"] || "")
    {count, users} = Map.get(by_name, name, {0, []})

    cond do
      name == "" or user == "" ->
        by_name

      row["deleted"] == true ->
        new_users = List.delete(users, user)
        Map.put(by_name, name, {max(count - 1, length(new_users)), new_users})

      user in users ->
        by_name

      true ->
        Map.put(by_name, name, {count + 1, users ++ [user]})
    end
  end

  defp reaction_count(count, users) when is_integer(count) and count >= 0,
    do: max(count, length(users))

  defp reaction_count(_count, users), do: length(users)

  defp overlay_pin(message, nil, _channel_id), do: message

  defp overlay_pin(message, %{"deleted" => true}, _channel_id),
    do: Map.drop(message, ["pinned_to", "pinned_info"])

  defp overlay_pin(message, pin, channel_id) do
    message
    |> Map.put("pinned_to", [channel_id])
    |> Map.put("pinned_info", %{
      "channel" => channel_id,
      "pinned_by" => pin["pinned_by"],
      "pinned_ts" => served_pinned_ts(pin)
    })
  end

  defp served_pinned_ts(%{"pinned_ts" => ts}) when is_binary(ts) and ts != "",
    do: decode_pinned_ts(ts)

  defp served_pinned_ts(%{"version" => version})
       when is_integer(version) and version > 0,
       do: div(div(version, 2), 1_000_000)

  defp served_pinned_ts(_pin), do: nil

  defp decode_pinned_ts(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> value
    end
  end

  defp overlay_metadata(message, nil), do: message
  defp overlay_metadata(message, %{"deleted" => true}), do: Map.delete(message, "metadata")

  defp overlay_metadata(message, row) do
    case decode_json(row["metadata"]) do
      metadata when is_map(metadata) and metadata != %{} -> Map.put(message, "metadata", metadata)
      _invalid -> message
    end
  end

  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value) when is_binary(value), do: Map.put_new(map, key, value)
  defp put_if_present(map, _key, _value), do: map

  defp decode_json(value) when is_binary(value) and value != "" do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _invalid -> nil
    end
  end

  defp decode_json(_value), do: nil

  defp fetch_payloads(scope, keys) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &payload_lookup_sql(&1, length(keys)),
             latest_state_binds(scope, keys),
             query: "slack_mirror_thread"
           ),
         true <- valid_payload_lookup?(rows, keys) do
      {:ok, Map.new(rows, &{&1["message_ts_us"], &1})}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_component_reactions(scope, keys) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &serve_reaction_sql(&1, length(keys)),
             latest_state_binds(scope, keys),
             query: "slack_mirror_thread_reactions"
           ),
         true <-
           valid_component_rows?(
             rows,
             keys,
             @reaction_row_keys,
             &valid_reaction_row?/1
           ) do
      {:ok, Enum.group_by(rows, & &1["message_ts_us"])}
    else
      false -> {:error, :invalid_slack_mirror_reaction_row}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_pins(scope, keys) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &pin_sql(&1, length(keys)),
             latest_state_binds(scope, keys),
             query: "slack_mirror_thread"
           ),
         true <- valid_component_rows?(rows, keys, @pin_keys, &valid_pin?/1) do
      {:ok, Map.new(rows, &{&1["message_ts_us"], &1})}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_metadata(scope, keys) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &metadata_sql(&1, length(keys)),
             latest_state_binds(scope, keys),
             query: "slack_mirror_thread"
           ),
         true <- valid_component_rows?(rows, keys, @metadata_keys, &valid_metadata?/1) do
      {:ok, Map.new(rows, &{&1["message_ts_us"], &1})}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp valid_payload_lookup?(rows, keys) when is_list(rows) do
    Enum.all?(rows, fn row ->
      exact_keys?(row, @payload_lookup_keys) and row["message_ts_us"] in keys and
        is_binary(row["payload"]) and valid_uint?(row["observed_ts_us"])
    end)
  end

  defp valid_payload_lookup?(_rows, _keys), do: false

  defp valid_component_rows?(rows, keys, expected, valid?) when is_list(rows) do
    Enum.all?(rows, fn row ->
      exact_keys?(row, expected) and row["message_ts_us"] in keys and valid?.(row)
    end)
  end

  defp valid_component_rows?(_rows, _keys, _expected, _valid?), do: false

  defp valid_reaction_row?(row),
    do:
      is_binary(row["user_id"]) and row["user_id"] != "" and is_binary(row["reaction"]) and
        is_boolean(row["deleted"]) and valid_uint?(row["version"])

  defp valid_pin?(row),
    do:
      is_boolean(row["deleted"]) and is_binary(row["pinned_by"]) and is_binary(row["message_ts"]) and
        is_binary(row["pinned_ts"]) and valid_uint?(row["version"])

  defp valid_metadata?(row),
    do: is_boolean(row["deleted"]) and is_binary(row["metadata"]) and is_binary(row["message_ts"])

  defp validate_serve_options(opts) do
    keys = Keyword.keys(opts)
    limit = Keyword.get(opts, :limit, @default_serve_limit)
    inclusive? = Keyword.get(opts, :inclusive, false) == true

    with true <-
           Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
             Enum.all?(keys, &(&1 in @serve_option_keys)),
         true <- is_integer(limit) and limit in 1..@max_serve_limit,
         {:ok, cursor_us} <- optional_ts_us(opts[:cursor]),
         {:ok, oldest_us} <- optional_range_ts_us(opts[:oldest]),
         {:ok, latest_us} <- optional_range_ts_us(opts[:latest]) do
      {:ok, limit, cursor_us, oldest_us, latest_us, inclusive?}
    else
      _invalid -> {:error, :invalid_slack_mirror_read}
    end
  end

  defp optional_ts_us(nil), do: {:ok, nil}
  defp optional_ts_us(""), do: {:ok, nil}

  defp optional_ts_us(value) when is_binary(value) do
    case slack_ts_micros(value) do
      {:ok, us} -> {:ok, us}
      {:error, _reason} -> :error
    end
  end

  defp optional_ts_us(_value), do: :error

  # Range bounds may identify whole seconds, unlike Slack message identities
  # and pagination cursors, which retain their fractional timestamp contract.
  defp optional_range_ts_us(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]{1,12}\z/, value),
      do: optional_ts_us(value <> ".0"),
      else: optional_ts_us(value)
  end

  defp optional_range_ts_us(value), do: optional_ts_us(value)

  defp serve_sql(database, :history) do
    """
    SELECT
      tenant_id, workspace_id, channel_id, message_ts_us, message_ts, thread_ts,
      version, deleted, actor_kind, actor_id, actor_label, subtype, text,
      #{ingest_at_iso8601_sql("ingest_at")} AS ingest_at,
      payload
    FROM #{database}.slack_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND deleted = false
      AND (thread_ts = '' OR thread_ts = message_ts OR subtype = 'thread_broadcast')
      AND ({has_cursor:UInt8} = 0 OR message_ts_us < {cursor_us:UInt64})
      AND ({has_oldest:UInt8} = 0 OR
           ({inclusive:UInt8} = 1 AND message_ts_us >= {oldest_us:UInt64}) OR
           ({inclusive:UInt8} = 0 AND message_ts_us > {oldest_us:UInt64}))
      AND ({has_latest:UInt8} = 0 OR
           ({inclusive:UInt8} = 1 AND message_ts_us <= {latest_us:UInt64}) OR
           ({inclusive:UInt8} = 0 AND message_ts_us < {latest_us:UInt64}))
    ORDER BY message_ts_us DESC
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  defp serve_sql(database, :replies) do
    """
    SELECT
      tenant_id, workspace_id, channel_id, message_ts_us, message_ts, thread_ts,
      version, deleted, actor_kind, actor_id, actor_label, subtype, text,
      #{ingest_at_iso8601_sql("ingest_at")} AS ingest_at,
      payload
    FROM #{database}.slack_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND deleted = false
      AND (message_ts_us = {root_ts_us:UInt64} OR thread_ts = {root_ts:String})
      AND ({has_cursor:UInt8} = 0 OR message_ts_us > {cursor_us:UInt64})
      AND ({has_oldest:UInt8} = 0 OR
           ({inclusive:UInt8} = 1 AND message_ts_us >= {oldest_us:UInt64}) OR
           ({inclusive:UInt8} = 0 AND message_ts_us > {oldest_us:UInt64}))
      AND ({has_latest:UInt8} = 0 OR
           ({inclusive:UInt8} = 1 AND message_ts_us <= {latest_us:UInt64}) OR
           ({inclusive:UInt8} = 0 AND message_ts_us < {latest_us:UInt64}))
    ORDER BY message_ts_us ASC
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  defp serve_binds(
         scope,
         kind,
         root_ts,
         root_ts_us,
         limit,
         cursor_us,
         oldest_us,
         latest_us,
         inclusive?
       ) do
    [
      tenant_id: scope["tenant_id"],
      workspace_id: scope["workspace_id"],
      channel_id: scope["channel_id"],
      root_ts: root_ts || "",
      root_ts_us: root_ts_us,
      limit: limit + 1,
      has_cursor: if(is_nil(cursor_us), do: 0, else: 1),
      cursor_us: cursor_us || 0,
      has_oldest: if(is_nil(oldest_us), do: 0, else: 1),
      oldest_us: oldest_us || 0,
      has_latest: if(is_nil(latest_us), do: 0, else: 1),
      latest_us: latest_us || 0,
      inclusive: if(inclusive?, do: 1, else: 0)
    ]
    |> then(&if(kind == :history, do: Keyword.delete(&1, :root_ts), else: &1))
  end

  defp payload_lookup_sql(database, key_count) do
    """
    SELECT message_ts_us, payload, observed_ts_us
    FROM #{database}.slack_message_payloads FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (#{key_predicates(key_count)})
    FORMAT JSONEachRow
    """
  end

  defp serve_reaction_sql(database, key_count) do
    """
    SELECT message_ts_us, user_id, reaction, version, deleted
    FROM #{database}.slack_message_reaction_deltas FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (#{key_predicates(key_count)})
    FORMAT JSONEachRow
    """
  end

  defp pin_sql(database, key_count) do
    """
    SELECT message_ts_us, message_ts, pinned_by, pinned_ts, version, deleted
    FROM #{database}.slack_message_pins FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (#{key_predicates(key_count)})
    FORMAT JSONEachRow
    """
  end

  defp metadata_sql(database, key_count) do
    """
    SELECT message_ts_us, message_ts, deleted, metadata
    FROM #{database}.slack_message_metadata FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND channel_id = {channel_id:String}
      AND (#{key_predicates(key_count)})
    FORMAT JSONEachRow
    """
  end

  defp key_predicates(key_count) do
    0..(key_count - 1)
    |> Enum.map_join(" OR ", fn index ->
      "message_ts_us = {message_ts_us_#{index}:UInt64}"
    end)
  end

  defp validate_search_options(opts) do
    keys = Keyword.keys(opts)
    limit = Keyword.get(opts, :limit, @default_search_limit)
    patterns = List.wrap(Keyword.get(opts, :patterns, []))
    exclude_patterns = List.wrap(Keyword.get(opts, :exclude_patterns, []))
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    actor_id = Keyword.get(opts, :actor_id)
    channel_id = Keyword.get(opts, :channel_id)
    after_us = Keyword.get(opts, :after_us)
    after_date = Keyword.get(opts, :after_date)
    before_us = Keyword.get(opts, :before_us)
    before_date = Keyword.get(opts, :before_date)
    has_file? = Keyword.get(opts, :has_file, false) == true
    cursor_ts_us = Keyword.get(opts, :cursor_ts_us)
    cursor_channel_id = Keyword.get(opts, :cursor_channel_id)

    with {:ok, groups} <- pattern_groups(patterns),
         true <- Enum.all?(exclude_patterns, &(is_binary(&1) and &1 != "")),
         term_count = group_term_count(groups) + length(exclude_patterns),
         selective? =
           groups != [] or exclude_patterns != [] or is_binary(actor_id) or
             is_binary(channel_id) or is_integer(after_us) or is_integer(before_us),
         true <-
           Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
             Enum.all?(keys, &(&1 in @search_option_keys)),
         true <- is_integer(limit) and limit in 1..@max_search_limit,
         true <- term_count <= @max_search_terms,
         true <- sort_dir in [:desc, :asc],
         true <- is_nil(actor_id) or canonical_nonblank?(actor_id),
         true <- is_nil(channel_id) or canonical_nonblank?(channel_id),
         true <- is_nil(after_us) or valid_uint?(after_us),
         true <- is_nil(before_us) or valid_uint?(before_us),
         true <- is_nil(after_date) or is_binary(after_date),
         true <- is_nil(before_date) or is_binary(before_date),
         true <- is_nil(cursor_ts_us) or valid_uint?(cursor_ts_us),
         true <- is_nil(cursor_channel_id) or canonical_nonblank?(cursor_channel_id),
         true <- selective? do
      {:ok,
       %{
         limit: limit,
         groups: groups,
         exclude_patterns: exclude_patterns,
         actor_id: actor_id,
         channel_id: channel_id,
         after_us: after_us,
         after_date: after_date,
         before_us: before_us,
         before_date: before_date,
         has_file?: has_file?,
         cursor_ts_us: cursor_ts_us,
         cursor_channel_id: cursor_channel_id,
         desc?: sort_dir == :desc
       }}
    else
      _invalid -> {:error, :invalid_slack_mirror_read}
    end
  end

  defp search_sql(database, parsed) do
    compare = if(parsed.desc?, do: "<", else: ">")
    order = if(parsed.desc?, do: "DESC", else: "ASC")

    """
    SELECT
      m.tenant_id, m.workspace_id, m.channel_id, m.message_ts_us, m.message_ts, m.thread_ts,
      m.version, m.deleted, m.actor_kind, m.actor_id, m.actor_label, m.subtype, m.text,
      #{ingest_at_iso8601_sql("m.ingest_at")} AS ingest_at,
      m.payload
    FROM #{database}.slack_messages AS m FINAL
    LEFT JOIN #{database}.slack_message_payloads AS p FINAL ON
      p.tenant_id = m.tenant_id
      AND p.workspace_id = m.workspace_id
      AND p.channel_id = m.channel_id
      AND p.message_ts_us = m.message_ts_us
    WHERE m.tenant_id = {tenant_id:String}
      AND m.workspace_id = {workspace_id:String}
      AND m.deleted = false
      AND ({has_channel:UInt8} = 0 OR m.channel_id = {channel_id:String})
      AND ({has_actor:UInt8} = 0 OR m.actor_id = {actor_id:String})
      AND ({has_file:UInt8} = 0 OR m.file_count > 0)
      AND ({has_after:UInt8} = 0 OR (
            m.event_date >= {after_date:Date} AND m.message_ts_us >= {after_us:UInt64}))
      AND ({has_before:UInt8} = 0 OR (
            m.event_date < {before_date:Date} AND m.message_ts_us < {before_us:UInt64}))
      AND #{term_predicates(parsed.groups, length(parsed.exclude_patterns))}
      AND ({has_cursor:UInt8} = 0 OR
           (m.message_ts_us, m.channel_id) #{compare}
             ({cursor_ts_us:UInt64}, {cursor_channel_id:String}))
    ORDER BY m.message_ts_us #{order}, m.channel_id #{order}
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  defp pattern_groups(patterns) when is_list(patterns) do
    cond do
      patterns == [] ->
        {:ok, []}

      Enum.all?(patterns, &(is_binary(&1) and &1 != "")) ->
        {:ok, [patterns]}

      Enum.all?(
        patterns,
        &(is_list(&1) and &1 != [] and Enum.all?(&1, fn p -> is_binary(p) and p != "" end))
      ) ->
        {:ok, patterns}

      true ->
        :error
    end
  end

  defp group_term_count(groups), do: groups |> List.flatten() |> length()

  defp term_predicates([], 0), do: "1 = 1"

  defp term_predicates(groups, exclude_count) do
    {include_sql, offset} = include_predicates(groups)

    exclude_sql =
      if exclude_count == 0 do
        ""
      else
        excludes =
          0..(exclude_count - 1)
          |> Enum.map_join(" AND ", fn i -> "NOT #{content_match(offset + i)}" end)

        " AND #{excludes}"
      end

    include_sql <> exclude_sql
  end

  defp include_predicates([]), do: {"1 = 1", 0}

  defp include_predicates(groups) do
    {parts, offset} =
      Enum.reduce(groups, {[], 0}, fn terms, {acc, offset} ->
        group =
          terms
          |> Enum.with_index(offset)
          |> Enum.map_join(" AND ", fn {_term, index} -> candidate_match(index) end)

        {acc ++ ["(#{group})"], offset + length(terms)}
      end)

    {"(#{Enum.join(parts, " OR ")})", offset}
  end

  # Positive recall may match serialized blocks JSON so a row whose
  # projection columns are still empty remains a candidate. Exclusion must
  # not reuse that predicate: `type` / `section` / `mrkdwn` live in the
  # envelope, not in the message, and NOT-ing them drops every Block Kit
  # post.
  defp candidate_match(index) do
    "(#{projected_text_match(index)} OR JSONExtractRaw(p.payload, 'blocks') ILIKE {term_#{index}:String})"
  end

  defp content_match(index) do
    "(#{projected_text_match(index)} OR #{extracted_block_text_sql()} ILIKE {term_#{index}:String})"
  end

  defp projected_text_match(index) do
    "m.text ILIKE {term_#{index}:String} OR m.body_text ILIKE {term_#{index}:String} OR p.text ILIKE {term_#{index}:String} OR p.body_text ILIKE {term_#{index}:String} OR JSONExtractString(p.payload, 'text') ILIKE {term_#{index}:String}"
  end

  defp extracted_block_text_sql do
    # JSON-decoded string values of Block Kit content keys at any depth.
    # `([^"]*)` stops at the first escaped quote and misses `Deploy "secret"`.
    haystack =
      "concat(ifNull(JSONExtractRaw(p.payload, 'blocks'), ''), ifNull(JSONExtractRaw(p.payload, 'attachments'), ''))"

    pattern =
      ~S{"(?:text|alt_text|title|subtitle|body|subtext|description|label|hint|placeholder|fallback|pretext|status)":"((?:[^"\\\\]|\\\\.)*)"}

    "arrayStringConcat(arrayMap(x -> JSONExtractString(concat('{\"v\":\"', x, '\"}'), 'v'), extractAll(#{haystack}, '#{pattern}')), ' ')"
  end

  defp search_binds(scope, parsed) do
    terms = List.flatten(parsed.groups) ++ parsed.exclude_patterns

    [
      tenant_id: scope["tenant_id"],
      workspace_id: scope["workspace_id"],
      limit: parsed.limit + 1,
      has_channel: flag(parsed.channel_id),
      channel_id: parsed.channel_id || "",
      has_actor: flag(parsed.actor_id),
      actor_id: parsed.actor_id || "",
      has_file: if(parsed.has_file?, do: 1, else: 0),
      has_after: flag(parsed.after_us),
      after_date: parsed.after_date || "1970-01-01",
      after_us: parsed.after_us || 0,
      has_before: flag(parsed.before_us),
      before_date: parsed.before_date || "1970-01-01",
      before_us: parsed.before_us || 0,
      has_cursor: flag(parsed.cursor_ts_us),
      cursor_ts_us: parsed.cursor_ts_us || 0,
      cursor_channel_id: parsed.cursor_channel_id || ""
    ] ++
      Enum.with_index(terms, fn pattern, index ->
        {String.to_atom("term_#{index}"), pattern}
      end)
  end

  defp flag(nil), do: 0
  defp flag(""), do: 0
  defp flag(_value), do: 1

  defp normalize_search_rows(rows, scope, channel_id) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      if valid_search_row?(row, scope, channel_id),
        do: {:cont, {:ok, [row | acc]}},
        else: {:halt, {:error, :invalid_slack_mirror_row}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp normalize_search_rows(_rows, _scope, _channel_id), do: {:error, :invalid_slack_mirror_row}

  defp valid_search_row?(row, scope, channel_id) when is_map(row) do
    exact_keys?(row, @serve_row_keys) and
      row["tenant_id"] == scope["tenant_id"] and
      row["workspace_id"] == scope["workspace_id"] and
      (is_nil(channel_id) or row["channel_id"] == channel_id) and
      valid_uint?(row["message_ts_us"]) and valid_uint?(row["version"]) and
      is_boolean(row["deleted"]) and
      Enum.all?(
        ~w(channel_id message_ts thread_ts actor_kind actor_id actor_label subtype text ingest_at payload),
        &is_binary(row[&1])
      ) and
      valid_iso8601?(row["ingest_at"])
  end

  defp valid_search_row?(_row, _scope, _channel_id), do: false

  defp fetch_payload_pairs(_scope, []), do: {:ok, %{}}

  defp fetch_payload_pairs(scope, pairs) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &payload_pair_sql(&1, length(pairs)),
             pair_binds(scope, pairs),
             query: "slack_mirror_search"
           ),
         true <- valid_pair_payloads?(rows, pairs) do
      {:ok, Map.new(rows, &{{&1["channel_id"], &1["message_ts_us"]}, &1})}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_reaction_pairs(_scope, []), do: {:ok, %{}}

  defp fetch_reaction_pairs(scope, pairs) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &reaction_pair_sql(&1, length(pairs)),
             pair_binds(scope, pairs),
             query: "slack_mirror_search"
           ),
         true <- valid_pair_reactions?(rows, pairs) do
      {:ok, Enum.group_by(rows, &{&1["channel_id"], &1["message_ts_us"]})}
    else
      false -> {:error, :invalid_slack_mirror_reaction_row}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_pin_pairs(_scope, []), do: {:ok, %{}}

  defp fetch_pin_pairs(scope, pairs) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &pin_pair_sql(&1, length(pairs)),
             pair_binds(scope, pairs),
             query: "slack_mirror_search"
           ),
         true <- valid_pair_pins?(rows, pairs) do
      {:ok, Map.new(rows, &{{&1["channel_id"], &1["message_ts_us"]}, &1})}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_metadata_pairs(_scope, []), do: {:ok, %{}}

  defp fetch_metadata_pairs(scope, pairs) do
    with {:ok, rows} <-
           ClickHouseRead.run(
             &metadata_pair_sql(&1, length(pairs)),
             pair_binds(scope, pairs),
             query: "slack_mirror_search"
           ),
         true <- valid_pair_metadata?(rows, pairs) do
      {:ok, Map.new(rows, &{{&1["channel_id"], &1["message_ts_us"]}, &1})}
    else
      false -> {:error, :invalid_slack_mirror_row}
      {:error, _reason} = error -> error
    end
  end

  defp pair_binds(scope, pairs) do
    [
      tenant_id: scope["tenant_id"],
      workspace_id: scope["workspace_id"]
    ] ++
      Enum.flat_map(Enum.with_index(pairs), fn {{channel_id, ts_us}, index} ->
        [
          {String.to_atom("ch_#{index}"), channel_id},
          {String.to_atom("ts_#{index}"), ts_us}
        ]
      end)
  end

  defp pair_predicates(pair_count) do
    0..(pair_count - 1)
    |> Enum.map_join(" OR ", fn index ->
      "(channel_id = {ch_#{index}:String} AND message_ts_us = {ts_#{index}:UInt64})"
    end)
  end

  defp payload_pair_sql(database, pair_count) do
    """
    SELECT channel_id, message_ts_us, payload, observed_ts_us
    FROM #{database}.slack_message_payloads FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND (#{pair_predicates(pair_count)})
    FORMAT JSONEachRow
    """
  end

  defp reaction_pair_sql(database, pair_count) do
    """
    SELECT channel_id, message_ts_us, user_id, reaction, version, deleted
    FROM #{database}.slack_message_reaction_deltas FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND (#{pair_predicates(pair_count)})
    FORMAT JSONEachRow
    """
  end

  defp pin_pair_sql(database, pair_count) do
    """
    SELECT channel_id, message_ts_us, message_ts, pinned_by, pinned_ts, version, deleted
    FROM #{database}.slack_message_pins FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND (#{pair_predicates(pair_count)})
    FORMAT JSONEachRow
    """
  end

  defp metadata_pair_sql(database, pair_count) do
    """
    SELECT channel_id, message_ts_us, message_ts, deleted, metadata
    FROM #{database}.slack_message_metadata FINAL
    WHERE tenant_id = {tenant_id:String}
      AND workspace_id = {workspace_id:String}
      AND (#{pair_predicates(pair_count)})
    FORMAT JSONEachRow
    """
  end

  defp valid_pair_payloads?(rows, pairs) when is_list(rows) do
    allowed = MapSet.new(pairs)

    Enum.all?(rows, fn row ->
      exact_keys?(row, ~w(channel_id message_ts_us payload observed_ts_us)) and
        {row["channel_id"], row["message_ts_us"]} in allowed and
        is_binary(row["payload"]) and valid_uint?(row["observed_ts_us"])
    end)
  end

  defp valid_pair_payloads?(_rows, _pairs), do: false

  defp valid_pair_reactions?(rows, pairs) when is_list(rows) do
    allowed = MapSet.new(pairs)

    Enum.all?(rows, fn row ->
      exact_keys?(row, @reaction_pair_keys) and
        {row["channel_id"], row["message_ts_us"]} in allowed and
        valid_reaction_row?(row)
    end)
  end

  defp valid_pair_reactions?(_rows, _pairs), do: false

  defp valid_pair_pins?(rows, pairs) when is_list(rows) do
    allowed = MapSet.new(pairs)

    Enum.all?(rows, fn row ->
      exact_keys?(
        row,
        ~w(channel_id message_ts_us message_ts pinned_by pinned_ts version deleted)
      ) and
        {row["channel_id"], row["message_ts_us"]} in allowed and valid_pin?(row)
    end)
  end

  defp valid_pair_pins?(_rows, _pairs), do: false

  defp valid_pair_metadata?(rows, pairs) when is_list(rows) do
    allowed = MapSet.new(pairs)

    Enum.all?(rows, fn row ->
      exact_keys?(row, ~w(channel_id message_ts_us message_ts deleted metadata)) and
        {row["channel_id"], row["message_ts_us"]} in allowed and valid_metadata?(row)
    end)
  end

  defp valid_pair_metadata?(_rows, _pairs), do: false
end
