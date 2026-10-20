defmodule SalixAnalytics.QQMirror.Reader do
  @moduledoc """
  Bounded, tenant- and bot-scoped read of the record of QQ group messages.

  The adapter owns ClickHouse SQL and decoding only. Parameters, the group
  default and the agent-facing message shape stay in
  `SalixIM.Provider.QQ.MessageSearch`.

  Rows are read `FINAL`, so a message QQ delivered twice is one row. Every
  read binds the caller's `tenant_id` and `app_id` (the bot's AppID) as the
  sorting-key prefix; there is no unscoped path. Values are bound as
  ClickHouse query parameters, never interpolated.
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
  Bot-scoped keyword search, newest first by default.

  `patterns` is one AND-group of ILIKE needles, or a list of AND-groups ORed
  together. Positive needles match the text or the content JSON, which holds
  the names of attached files. Exclusions match the text only. The cursor is
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
             query: "qq_mirror_search"
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

  def search(_scope, _opts), do: {:error, :invalid_qq_mirror_read}

  @doc """
  One recorded message of the scope by its group and message id, or
  `{:error, :not_found}`. The lookup is on the full sorting key.
  """
  @spec get_message(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_message(scope, chat_id, message_id) when is_map(scope) do
    with :ok <- validate_scope(scope),
         true <- canonical_nonblank?(chat_id) and canonical_nonblank?(message_id),
         {:ok, rows} <-
           ClickHouseRead.run(
             fn database ->
               """
               SELECT #{Enum.join(@row_keys, ", ")}
               FROM #{database}.qq_messages FINAL
               WHERE tenant_id = {tenant_id:String}
                 AND app_id = {app_id:String}
                 AND chat_id = {chat_id:String}
                 AND message_id = {message_id:String}
                 AND deleted = false
               LIMIT 1
               FORMAT JSONEachRow
               """
             end,
             [
               tenant_id: scope["tenant_id"],
               app_id: scope["app_id"],
               chat_id: chat_id,
               message_id: message_id
             ],
             query: "qq_mirror_search"
           ) do
      case rows do
        [%{"message_id" => ^message_id, "chat_id" => ^chat_id} = row] -> {:ok, row}
        [] -> {:error, :not_found}
        _other -> {:error, :invalid_qq_mirror_row}
      end
    else
      false -> {:error, :invalid_qq_mirror_read}
      {:error, _reason} = error -> error
    end
  end

  def get_message(_scope, _chat_id, _message_id), do: {:error, :invalid_qq_mirror_read}

  defp validate_scope(%{"tenant_id" => tenant_id, "app_id" => app_id}) do
    if canonical_nonblank?(tenant_id) and canonical_nonblank?(app_id),
      do: :ok,
      else: {:error, :invalid_qq_mirror_scope}
  end

  defp validate_scope(_scope), do: {:error, :invalid_qq_mirror_scope}

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
      _invalid -> {:error, :invalid_qq_mirror_read}
    end
  end

  defp search_sql(database, parsed) do
    compare = if(parsed.desc?, do: "<", else: ">")
    order = if(parsed.desc?, do: "DESC", else: "ASC")

    """
    SELECT #{Enum.join(@row_keys, ", ")}
    FROM #{database}.qq_messages FINAL
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
      else: {:error, :invalid_qq_mirror_row}
  end

  defp validate_rows(_rows, _scope, _parsed), do: {:error, :invalid_qq_mirror_row}

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
end
