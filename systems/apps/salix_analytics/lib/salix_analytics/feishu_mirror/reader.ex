defmodule SalixAnalytics.FeishuMirror.Reader do
  @moduledoc """
  Bounded, tenant- and app-scoped keyword search over the Feishu mirror.

  The adapter owns ClickHouse SQL and decoding only. Authorization, query
  parsing, completeness, stale marks and the agent-facing message shape stay
  in `SalixIM.Provider.Feishu.MessageSearch`.

  Rows are read `FINAL`, so a recall that replaced a message hides it, and
  `deleted = false` is applied after the merge. Every read binds the caller's
  `tenant_id` and `app_id` as the sorting-key prefix; there is no unscoped
  path. Values are bound as ClickHouse query parameters, never interpolated.
  """

  alias SalixAnalytics.ClickHouseRead

  @option_keys [
    :limit,
    :patterns,
    :exclude_patterns,
    :actor_id,
    :chat_id,
    :thread_id,
    :after_us,
    :before_us,
    :has_file,
    :cursor_ts_us,
    :cursor_message_id,
    :sort_dir
  ]
  @default_limit 30
  @max_limit 200
  @max_terms 8
  @row_keys ~w(
    tenant_id app_id chat_id message_id create_time_us version root_id parent_id
    thread_id chat_type message_type actor_kind actor_id actor_label text content file_count
  )

  @doc """
  App-scoped keyword search, newest first by default.

  `patterns` is one AND-group of ILIKE needles, or a list of AND-groups ORed
  together. Positive needles match the normalized text or the raw content
  JSON, so a card whose text projection is thin is still found. Exclusions
  match the normalized text only: NOT-ing the raw JSON would drop every
  message whose envelope happens to contain the word. The cursor is
  `{create_time_us, message_id}`.
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
    with :ok <- validate_scope(scope),
         {:ok, parsed} <- validate_options(opts),
         {:ok, rows} <-
           ClickHouseRead.run(
             &search_sql(&1, parsed),
             binds(scope, parsed),
             query: "feishu_mirror_search"
           ),
         :ok <- validate_rows(rows, scope, parsed) do
      page = Enum.take(rows, parsed.limit)
      has_more? = length(rows) > parsed.limit

      next_cursor =
        case {has_more?, List.last(page)} do
          {true, %{"create_time_us" => ts, "message_id" => id}} -> {ts, id}
          _ -> nil
        end

      {:ok, %{messages: page, next_cursor: next_cursor, has_more?: has_more?}}
    end
  end

  def search(_scope, _opts), do: {:error, :invalid_feishu_mirror_read}

  defp validate_scope(%{"tenant_id" => tenant_id, "app_id" => app_id}) do
    if canonical_nonblank?(tenant_id) and canonical_nonblank?(app_id),
      do: :ok,
      else: {:error, :invalid_feishu_mirror_scope}
  end

  defp validate_scope(_scope), do: {:error, :invalid_feishu_mirror_scope}

  defp validate_options(opts) do
    keys = Keyword.keys(opts)
    limit = Keyword.get(opts, :limit, @default_limit)
    patterns = List.wrap(Keyword.get(opts, :patterns, []))
    exclude_patterns = List.wrap(Keyword.get(opts, :exclude_patterns, []))
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    actor_id = Keyword.get(opts, :actor_id)
    chat_id = Keyword.get(opts, :chat_id)
    thread_id = Keyword.get(opts, :thread_id)
    after_us = Keyword.get(opts, :after_us)
    before_us = Keyword.get(opts, :before_us)
    cursor_ts_us = Keyword.get(opts, :cursor_ts_us)
    cursor_message_id = Keyword.get(opts, :cursor_message_id)

    with {:ok, groups} <- pattern_groups(patterns),
         true <- Enum.all?(exclude_patterns, &(is_binary(&1) and &1 != "")),
         true <- Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @option_keys)),
         true <- is_integer(limit) and limit in 1..@max_limit,
         true <- length(List.flatten(groups)) + length(exclude_patterns) <= @max_terms,
         true <- sort_dir in [:desc, :asc],
         true <-
           Enum.all?([actor_id, chat_id, thread_id], &(is_nil(&1) or canonical_nonblank?(&1))),
         true <- Enum.all?([after_us, before_us, cursor_ts_us], &(is_nil(&1) or valid_uint?(&1))),
         true <- is_nil(cursor_ts_us) == is_nil(cursor_message_id),
         true <- is_nil(cursor_message_id) or canonical_nonblank?(cursor_message_id),
         # A search with nothing to narrow it would rank a whole app's history.
         true <-
           groups != [] or is_binary(actor_id) or is_binary(chat_id) or is_binary(thread_id) do
      {:ok,
       %{
         limit: limit,
         groups: groups,
         exclude_patterns: exclude_patterns,
         actor_id: actor_id,
         chat_id: chat_id,
         thread_id: thread_id,
         after_us: after_us,
         before_us: before_us,
         has_file?: Keyword.get(opts, :has_file, false) == true,
         cursor_ts_us: cursor_ts_us,
         cursor_message_id: cursor_message_id,
         desc?: sort_dir == :desc
       }}
    else
      _invalid -> {:error, :invalid_feishu_mirror_read}
    end
  end

  defp search_sql(database, parsed) do
    compare = if(parsed.desc?, do: "<", else: ">")
    order = if(parsed.desc?, do: "DESC", else: "ASC")

    """
    SELECT #{Enum.join(@row_keys, ", ")}
    FROM #{database}.feishu_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND app_id = {app_id:String}
      AND deleted = false
      AND ({has_chat:UInt8} = 0 OR chat_id = {chat_id:String})
      AND ({has_thread:UInt8} = 0 OR thread_id = {thread_id:String})
      AND ({has_actor:UInt8} = 0 OR actor_id = {actor_id:String})
      AND ({has_file:UInt8} = 0 OR file_count > 0)
      AND ({has_after:UInt8} = 0 OR create_time_us >= {after_us:UInt64})
      AND ({has_before:UInt8} = 0 OR create_time_us < {before_us:UInt64})
      AND #{term_predicates(parsed.groups, length(parsed.exclude_patterns))}
      AND ({has_cursor:UInt8} = 0 OR
           (create_time_us, message_id) #{compare}
             ({cursor_ts_us:UInt64}, {cursor_message_id:String}))
    ORDER BY create_time_us #{order}, message_id #{order}
    LIMIT {limit:UInt32}
    FORMAT JSONEachRow
    """
  end

  defp pattern_groups([]), do: {:ok, []}

  defp pattern_groups(patterns) do
    cond do
      Enum.all?(patterns, &(is_binary(&1) and &1 != "")) ->
        {:ok, [patterns]}

      Enum.all?(patterns, fn group ->
        is_list(group) and group != [] and Enum.all?(group, &(is_binary(&1) and &1 != ""))
      end) ->
        {:ok, patterns}

      true ->
        :error
    end
  end

  defp term_predicates([], 0), do: "1 = 1"

  defp term_predicates(groups, exclude_count) do
    {include_sql, offset} =
      case groups do
        [] ->
          {"1 = 1", 0}

        groups ->
          {parts, offset} =
            Enum.map_reduce(groups, 0, fn terms, offset ->
              group =
                offset..(offset + length(terms) - 1)
                |> Enum.map_join(" AND ", fn i ->
                  "(text ILIKE {term_#{i}:String} OR content ILIKE {term_#{i}:String})"
                end)

              {"(#{group})", offset + length(terms)}
            end)

          {"(#{Enum.join(parts, " OR ")})", offset}
      end

    excludes =
      if exclude_count == 0,
        do: [],
        else:
          Enum.map(offset..(offset + exclude_count - 1), &"NOT text ILIKE {term_#{&1}:String}")

    Enum.join([include_sql | excludes], " AND ")
  end

  defp binds(scope, parsed) do
    terms = List.flatten(parsed.groups) ++ parsed.exclude_patterns

    [
      tenant_id: scope["tenant_id"],
      app_id: scope["app_id"],
      limit: parsed.limit + 1,
      has_chat: flag(parsed.chat_id),
      chat_id: parsed.chat_id || "",
      has_thread: flag(parsed.thread_id),
      thread_id: parsed.thread_id || "",
      has_actor: flag(parsed.actor_id),
      actor_id: parsed.actor_id || "",
      has_file: if(parsed.has_file?, do: 1, else: 0),
      has_after: flag(parsed.after_us),
      after_us: parsed.after_us || 0,
      has_before: flag(parsed.before_us),
      before_us: parsed.before_us || 0,
      has_cursor: flag(parsed.cursor_ts_us),
      cursor_ts_us: parsed.cursor_ts_us || 0,
      cursor_message_id: parsed.cursor_message_id || ""
    ] ++
      Enum.with_index(terms, fn pattern, index -> {String.to_atom("term_#{index}"), pattern} end)
  end

  defp flag(nil), do: 0
  defp flag(_value), do: 1

  # A row outside the caller's scope is never returned, even if the server
  # produced one: the result fails as a whole rather than being filtered.
  defp validate_rows(rows, scope, parsed) when is_list(rows) do
    if Enum.all?(rows, &valid_row?(&1, scope, parsed)),
      do: :ok,
      else: {:error, :invalid_feishu_mirror_row}
  end

  defp validate_rows(_rows, _scope, _parsed), do: {:error, :invalid_feishu_mirror_row}

  defp valid_row?(row, scope, parsed) when is_map(row) do
    Enum.sort(Map.keys(row)) == Enum.sort(@row_keys) and
      row["tenant_id"] == scope["tenant_id"] and row["app_id"] == scope["app_id"] and
      (is_nil(parsed.chat_id) or row["chat_id"] == parsed.chat_id) and
      valid_uint?(row["create_time_us"]) and valid_uint?(row["version"]) and
      valid_uint?(row["file_count"]) and
      Enum.all?(@row_keys -- ~w(create_time_us version file_count), &is_binary(row[&1]))
  end

  defp valid_row?(_row, _scope, _parsed), do: false

  defp valid_uint?(value), do: is_integer(value) and value >= 0

  defp canonical_nonblank?(value),
    do: is_binary(value) and value != "" and value == String.trim(value)

  ## Daily brief reads

  @max_brief_ids 500
  @max_brief_chats 2_000

  @doc """
  The current state of named messages in one chat (at most 500), for the
  daily brief. Recalled and unknown messages are absent.
  """
  @spec messages(map(), String.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def messages(scope, chat_id, message_ids)
      when is_map(scope) and is_binary(chat_id) and is_list(message_ids) and
             length(message_ids) <= @max_brief_ids do
    with :ok <- validate_scope(scope),
         true <- id?(chat_id) and message_ids != [] and Enum.all?(message_ids, &id?/1),
         {:ok, rows} <-
           ClickHouseRead.run(
             &messages_sql/1,
             [
               tenant_id: scope["tenant_id"],
               app_id: scope["app_id"],
               chat_id: chat_id,
               ids: array(Enum.uniq(message_ids))
             ],
             query: "feishu_mirror_brief"
           ),
         :ok <- validate_rows(rows, scope, %{chat_id: chat_id}) do
      {:ok, rows}
    else
      false -> {:error, :invalid_feishu_mirror_read}
      {:error, _reason} = error -> error
    end
  end

  def messages(_scope, _chat_id, _message_ids), do: {:error, :invalid_feishu_mirror_read}

  defp messages_sql(database) do
    """
    SELECT #{Enum.join(@row_keys, ", ")}
    FROM #{database}.feishu_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND app_id = {app_id:String}
      AND chat_id = {chat_id:String}
      AND message_id IN {ids:Array(String)}
      AND deleted = false
      AND create_time_us > 0
    ORDER BY create_time_us ASC, message_id ASC
    FORMAT JSONEachRow
    """
  end

  @doc """
  Of `threads` (`{chat_id, root_message_id}`, at most 500), the ones
  `actor_id` wrote in: the root or a reply. No text returns.
  """
  @spec thread_participation(map(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def thread_participation(scope, actor_id, threads)
      when is_map(scope) and is_binary(actor_id) and is_list(threads) and
             length(threads) <= @max_brief_ids do
    with :ok <- validate_scope(scope),
         true <- id?(actor_id) and threads != [],
         true <-
           Enum.all?(threads, &match?({chat, root} when is_binary(chat) and is_binary(root), &1)),
         true <- Enum.all?(threads, fn {chat, root} -> id?(chat) and id?(root) end),
         wanted = MapSet.new(threads),
         {:ok, rows} <-
           ClickHouseRead.run(
             &thread_participation_sql/1,
             [
               tenant_id: scope["tenant_id"],
               app_id: scope["app_id"],
               actor_id: actor_id,
               chats: array(threads |> Enum.map(&elem(&1, 0)) |> Enum.uniq()),
               roots: array(threads |> Enum.map(&elem(&1, 1)) |> Enum.uniq())
             ],
             query: "feishu_mirror_brief"
           ),
         true <- Enum.all?(rows, &(is_binary(&1["chat_id"]) and is_binary(&1["root"]))) do
      {:ok,
       rows
       |> Enum.map(&{&1["chat_id"], &1["root"]})
       |> Enum.filter(&MapSet.member?(wanted, &1))
       |> Enum.uniq()}
    else
      false -> {:error, :invalid_feishu_mirror_read}
      {:error, _reason} = error -> error
    end
  end

  def thread_participation(_scope, _actor_id, _threads),
    do: {:error, :invalid_feishu_mirror_read}

  defp thread_participation_sql(database) do
    """
    SELECT DISTINCT chat_id, if(root_id = '', message_id, root_id) AS root
    FROM #{database}.feishu_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND app_id = {app_id:String}
      AND chat_id IN {chats:Array(String)}
      AND actor_id = {actor_id:String}
      AND deleted = false
      AND (root_id IN {roots:Array(String)} OR message_id IN {roots:Array(String)})
    FORMAT JSONEachRow
    """
  end

  @doc """
  How many messages each of `actor_ids` (at most 500) wrote in each of
  `chat_ids` (at most 2000) since `after_us`, as `{chat_id, actor_id, count}`.
  Counts only.
  """
  @spec actor_chat_counts(map(), [String.t()], [String.t()], non_neg_integer()) ::
          {:ok, [{String.t(), String.t(), non_neg_integer()}]} | {:error, term()}
  def actor_chat_counts(scope, actor_ids, chat_ids, after_us)
      when is_map(scope) and is_list(actor_ids) and is_list(chat_ids) and
             is_integer(after_us) and after_us >= 0 and length(actor_ids) <= @max_brief_ids and
             length(chat_ids) <= @max_brief_chats do
    with :ok <- validate_scope(scope),
         true <- actor_ids != [] and chat_ids != [],
         true <- Enum.all?(actor_ids, &id?/1) and Enum.all?(chat_ids, &id?/1),
         {:ok, rows} <-
           ClickHouseRead.run(
             &actor_chat_counts_sql/1,
             [
               tenant_id: scope["tenant_id"],
               app_id: scope["app_id"],
               actors: array(Enum.uniq(actor_ids)),
               chats: array(Enum.uniq(chat_ids)),
               after_us: after_us
             ],
             query: "feishu_mirror_brief"
           ) do
      {:ok,
       for(
         %{"chat_id" => c, "actor_id" => a, "n" => n} <- rows,
         is_binary(c) and is_binary(a),
         do: {c, a, to_count(n)}
       )}
    else
      false -> {:error, :invalid_feishu_mirror_read}
      {:error, _reason} = error -> error
    end
  end

  def actor_chat_counts(_scope, _actor_ids, _chat_ids, _after_us),
    do: {:error, :invalid_feishu_mirror_read}

  defp actor_chat_counts_sql(database) do
    """
    SELECT chat_id, actor_id, count() AS n
    FROM #{database}.feishu_messages FINAL
    WHERE tenant_id = {tenant_id:String}
      AND app_id = {app_id:String}
      AND chat_id IN {chats:Array(String)}
      AND actor_id IN {actors:Array(String)}
      AND create_time_us >= {after_us:UInt64}
      AND deleted = false
    GROUP BY chat_id, actor_id
    FORMAT JSONEachRow
    """
  end

  # Feishu ids (oc_, om_, ou_, omt_) are word characters and dashes; only
  # such values go into an array parameter.
  defp id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, value)

  defp array(values), do: "[" <> Enum.map_join(values, ",", &"'#{&1}'") <> "]"

  defp to_count(n) when is_integer(n), do: n
  defp to_count(n) when is_binary(n), do: String.to_integer(n)
end
