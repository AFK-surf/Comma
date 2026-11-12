defmodule SalixStore.TaskFiles do
  @moduledoc """
  Postgres access for the Task file index: one row per file or image an Agent
  attached to a Task Message, keyed by the Message's sequence and the block's
  position in its content. It is a projection of the Message's attachment, not
  another identity: rows hold no bytes and no blob ref, and a download reads
  the canonical Message again.

  `put!/3`, `retitle!/3` and `delete_conversation!/2` run on the caller's
  connection inside the Conversation's source transaction
  (`SalixIM.ConversationPGStore`), so a row commits with its Message, a title
  change and a Task's final deletion.

  Reads answer `{:error, :indexing}` until the backfill
  (`SalixIM.TaskFiles.backfill_page/0`) marks `task_files_v1` complete: before
  that, rows of Messages appended by an earlier release are missing.
  Every read joins the Task's live Conversation row, so a deleted Task's files
  are not answered while its cleanup runs.

  A search walks the Group's files newest first (`salix_task_files_group_recent`,
  or the primary key within one Task) and keeps the names that match; no name
  index spans Groups.

  Bounds: a page holds at most 200 rows, a search at most 50; every read is
  one indexed statement within 500 ms.
  """

  alias SalixStore.Repo

  @marker "task_files_v1"
  @max_page 200
  @max_search 50
  @statement_timeout_ms 500
  @database_timeout_ms 1_000
  @max_query_bytes 512

  @type row :: %{
          seq: pos_integer(),
          block_index: non_neg_integer(),
          message_id: String.t(),
          kind: String.t(),
          file_name: String.t(),
          mime_type: String.t() | nil,
          size: non_neg_integer(),
          agent_id: String.t(),
          task_title: String.t(),
          created_at: integer()
        }

  @columns "f.conversation_id, f.seq, f.block_index, f.message_id, f.kind, f.file_name, " <>
             "f.mime_type, f.size, f.agent_id, f.task_title, f.created_at"
  @live_task "JOIN salix_conversations c ON c.group_id = f.group_id " <>
               "AND c.conversation_id = f.conversation_id AND c.deleted_at IS NULL"

  @doc "The marker the backfill completes."
  def marker, do: @marker

  @doc "The largest page a read answers."
  def max_page, do: @max_page

  @doc "The most files a search answers."
  def max_search, do: @max_search

  @doc """
  Records the rows of one Message. A row already recorded for the same
  sequence and block stays as it is, so the live append and the backfill can
  both write it.
  """
  @spec put!(String.t(), String.t(), [row()]) :: :ok
  def put!(_group_id, _conversation_id, []), do: :ok

  def put!(group_id, conversation_id, rows) when is_list(rows) do
    {values, params} =
      rows
      |> Enum.with_index()
      |> Enum.map_reduce([group_id, conversation_id], fn {row, index}, params ->
        base = 2 + index * 11

        placeholders =
          Enum.map_join(1..11, ", ", fn offset -> "$#{base + offset}" end)

        {"($1, $2, #{placeholders})",
         params ++
           [
             row.seq,
             row.block_index,
             row.message_id,
             row.kind,
             row.file_name,
             fold(row.file_name),
             row.mime_type,
             row.size,
             row.agent_id,
             row.task_title,
             row.created_at
           ]}
      end)

    Repo.query!(
      """
      INSERT INTO salix_task_files
        (group_id, conversation_id, seq, block_index, message_id, kind, file_name,
         folded_name, mime_type, size, agent_id, task_title, created_at)
      VALUES #{Enum.join(values, ", ")}
      ON CONFLICT (group_id, conversation_id, seq, block_index) DO NOTHING
      """,
      params
    )

    :ok
  end

  @doc "Gives every file of one Task its new title."
  @spec retitle!(String.t(), String.t(), String.t()) :: :ok
  def retitle!(group_id, conversation_id, title) when is_binary(title) do
    Repo.query!(
      "UPDATE salix_task_files SET task_title = $3 " <>
        "WHERE group_id = $1 AND conversation_id = $2 AND task_title <> $3",
      [group_id, conversation_id, title]
    )

    :ok
  end

  @doc "Removes every file of one Task, with its final deletion."
  @spec delete_conversation!(String.t(), String.t()) :: :ok
  def delete_conversation!(group_id, conversation_id) do
    Repo.query!(
      "DELETE FROM salix_task_files WHERE group_id = $1 AND conversation_id = $2",
      [group_id, conversation_id]
    )

    :ok
  end

  @doc "True once the backfill has indexed every Message an earlier release appended."
  @spec ready?() :: boolean()
  def ready? do
    case Repo.query(
           "SELECT 1 FROM salix_cutover_markers WHERE name = $1 AND evidence->>'phase' = 'complete'",
           [@marker]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _other -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  One page of a Task's files, newest first. `cursor` is the `next_cursor` of
  the page before.
  """
  @spec list_task(String.t(), String.t(), keyword()) ::
          {:ok, %{files: [map()], next_cursor: String.t() | nil}}
          | {:error, :indexing | :invalid | :unavailable}
  def list_task(group_id, conversation_id, opts \\ []) do
    with {:ok, limit} <- limit(opts, @max_page),
         {:ok, after_key} <- decode_cursor(Keyword.get(opts, :cursor), 2) do
      {condition, params} =
        case after_key do
          nil -> {"", []}
          [seq, index] -> {"AND (f.seq, f.block_index) < ($4, $5)", [seq, index]}
        end

      read(
        """
        SELECT #{@columns} FROM salix_task_files f #{@live_task}
        WHERE f.group_id = $1 AND f.conversation_id = $2 #{condition}
        ORDER BY f.seq DESC, f.block_index DESC
        LIMIT $3
        """,
        [group_id, conversation_id, limit + 1] ++ params,
        limit,
        &[&1.seq, &1.block_index]
      )
    end
  end

  @doc "One page of a Group's files across its Tasks, newest first."
  @spec list_group(String.t(), keyword()) ::
          {:ok, %{files: [map()], next_cursor: String.t() | nil}}
          | {:error, :indexing | :invalid | :unavailable}
  def list_group(group_id, opts \\ []) do
    with {:ok, limit} <- limit(opts, @max_page),
         {:ok, after_key} <- decode_cursor(Keyword.get(opts, :cursor), 4) do
      {condition, params} =
        case after_key do
          nil ->
            {"", []}

          [created_at, conversation_id, seq, index] ->
            {"AND (f.created_at, f.conversation_id, f.seq, f.block_index) < ($3, $4, $5, $6)",
             [created_at, conversation_id, seq, index]}
        end

      read(
        """
        SELECT #{@columns} FROM salix_task_files f #{@live_task}
        WHERE f.group_id = $1 #{condition}
        ORDER BY f.created_at DESC, f.conversation_id DESC, f.seq DESC, f.block_index DESC
        LIMIT $2
        """,
        [group_id, limit + 1] ++ params,
        limit,
        &[&1.created_at, &1.conversation_id, &1.seq, &1.block_index]
      )
    end
  end

  @doc """
  A Group's files whose name contains `query` (case-folded), newest first; with
  `conversation_id`, only that Task's.
  """
  @spec search(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :indexing | :invalid | :unavailable}
  def search(group_id, query, opts \\ []) when is_binary(query) do
    folded = fold(String.trim(query))

    with true <- folded != "" and byte_size(folded) <= @max_query_bytes,
         {:ok, limit} <- limit(opts, @max_search) do
      {scope, params} = scope(Keyword.get(opts, :conversation_id), [], 4)

      case read(
             """
             SELECT #{@columns} FROM salix_task_files f #{@live_task}
             WHERE f.group_id = $1 AND f.folded_name LIKE $2 ESCAPE '\\' #{scope}
             ORDER BY f.created_at DESC, f.conversation_id DESC, f.seq DESC, f.block_index DESC
             LIMIT $3
             """,
             [group_id, "%" <> escape_like(folded) <> "%", limit] ++ params,
             limit,
             nil
           ) do
        {:ok, %{files: files}} -> {:ok, files}
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :invalid}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The name as searches compare it: compatibility-normalized and lower case.
  """
  @spec fold(String.t()) :: String.t()
  def fold(name) when is_binary(name) do
    case :unicode.characters_to_nfkc_binary(name) do
      normalized when is_binary(normalized) -> String.downcase(normalized)
      _invalid -> String.downcase(name)
    end
  end

  defp scope(nil, params, _position), do: {"", params}

  defp scope(conversation_id, params, position) when is_binary(conversation_id),
    do: {"AND f.conversation_id = $#{position}", params ++ [conversation_id]}

  defp read(sql, params, limit, key) do
    if ready?() do
      Repo.transaction(
        fn ->
          with {:ok, _timeout} <-
                 Repo.query("SELECT set_config('statement_timeout', $1, true)", [
                   Integer.to_string(@statement_timeout_ms) <> "ms"
                 ]),
               {:ok, %{rows: rows}} <- Repo.query(sql, params, timeout: @database_timeout_ms) do
            rows
          else
            _other -> Repo.rollback(:unavailable)
          end
        end,
        timeout: @database_timeout_ms
      )
      |> case do
        {:ok, rows} -> {:ok, page(Enum.map(rows, &file/1), limit, key)}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :indexing}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp page(files, limit, nil), do: %{files: Enum.take(files, limit), next_cursor: nil}

  defp page(files, limit, key) do
    {shown, rest} = Enum.split(files, limit)

    next =
      case {rest, List.last(shown)} do
        {[_ | _], last} when is_map(last) -> encode_cursor(key.(last))
        _done -> nil
      end

    %{files: shown, next_cursor: next}
  end

  defp file([
         conversation_id,
         seq,
         block_index,
         message_id,
         kind,
         file_name,
         mime_type,
         size,
         agent_id,
         task_title,
         created_at
       ]) do
    %{
      conversation_id: conversation_id,
      seq: seq,
      block_index: block_index,
      message_id: message_id,
      kind: kind,
      file_name: file_name,
      mime_type: mime_type,
      size: size,
      agent_id: agent_id,
      task_title: task_title,
      created_at: created_at
    }
  end

  defp limit(opts, max) do
    case Keyword.get(opts, :limit, max) do
      limit when is_integer(limit) and limit >= 1 and limit <= max -> {:ok, limit}
      _invalid -> {:error, :invalid}
    end
  end

  defp encode_cursor(key), do: key |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode_cursor(nil, _arity), do: {:ok, nil}

  defp decode_cursor(cursor, arity) when is_binary(cursor) and byte_size(cursor) <= 1_024 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, key} when is_list(key) <- Jason.decode(json),
         true <- length(key) == arity and valid_key?(key) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp decode_cursor(_cursor, _arity), do: {:error, :invalid}

  defp valid_key?(key),
    do: Enum.all?(key, &((is_integer(&1) and &1 >= 0) or (is_binary(&1) and &1 != "")))

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
