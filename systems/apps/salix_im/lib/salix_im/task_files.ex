defmodule SalixIM.TaskFiles do
  @moduledoc """
  The files Agents attached to a Group's Tasks: where a person, the Router or a
  client finds a Task's outputs without reading its whole history.

  A Task file is an Attachment of a Task Message: a `file` or `image` block,
  with a complete blob ref, of a visible Agent Message (not an internal
  delivery). `SalixStore.TaskFiles` keeps one row per such block, written in
  the Message's source transaction (`SalixIM.ConversationPGStore`); this module
  decides which blocks they are and answers the reads. The row is not another
  identity: it is addressed by the Message and the block's index in its
  content, and a download reads that Message again
  (`Comma.ConversationAttachments`).

  Messages appended before the release that added the index are indexed after
  the rollout: the release opens the backfill once no server of an earlier
  release is left to append a Message without indexing it
  (`open_after_rollout/1`), and every Pod drains it a page at a time
  (`SalixIM.TaskFilesBackfill`, `backfill_page/0`). Reads answer
  `{:error, :indexing}` until it completes. A Task a station hosts keeps no
  Salix log, so it has no files here.

  A Message whose archived body is gone (`:archive_incomplete`) cannot be
  read again by any retry: the backfill reads the other Messages of its range
  one at a time, leaves that one without rows and counts it in the marker's
  `skipped`. Any other failure leaves the marker as it was and the page runs
  again.

  Bounds: a backfill page reads at most 25 Tasks and 500 Messages, in reads of
  at most 100 Messages (one at a time for a range with a lost Message).
  """

  require Logger
  alias SalixIM.{ConversationAttachments, ConversationMessage, ConversationPGStore}
  alias SalixStore.{Repo, TaskFiles}

  @kinds ~w(file image)
  @max_file_name_bytes 1_024
  @backfill_tasks 25
  @backfill_messages 500
  @message_page 100

  @doc """
  The rows of one Message of the Task `record`, as `SalixStore.TaskFiles`
  records them: none for a Message that is not a visible Agent Message.
  """
  @spec rows(map(), map()) :: [SalixStore.TaskFiles.row()]
  def rows(%{"kind" => "agent_task"} = record, %{"actor_type" => "agent"} = message) do
    content = message["content"]
    agent_id = message["agent_id"]
    seq = message["seq"]

    if is_list(content) and is_binary(agent_id) and agent_id != "" and is_integer(seq) and
         seq > 0 and message["kind"] in [nil, "message"] and
         not ConversationMessage.internal_delivery?(message) do
      content
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, index} -> row(record, message, block, index) end)
    else
      []
    end
  end

  def rows(_record, _message), do: []

  defp row(record, message, %{"type" => kind} = block, index) when kind in @kinds do
    file_name = ConversationAttachments.file_name(block)

    case block["blob_ref"] do
      %{"uuid" => uuid, "hash" => hash, "size" => size}
      when is_binary(uuid) and uuid != "" and is_binary(hash) and hash != "" and
             is_integer(size) and size >= 0 and byte_size(file_name) <= @max_file_name_bytes ->
        [
          %{
            seq: message["seq"],
            block_index: index,
            message_id: message["message_id"],
            kind: kind,
            file_name: file_name,
            mime_type: mime_type(block["mime_type"]),
            size: size,
            agent_id: message["agent_id"],
            task_title: title(record),
            created_at: created_at(message)
          }
        ]

      _incomplete ->
        []
    end
  end

  defp row(_record, _message, _block, _index), do: []

  @doc "The title the Task's files carry."
  @spec title(map()) :: String.t()
  def title(record) do
    case record["title"] do
      title when is_binary(title) -> title
      _none -> ""
    end
  end

  defp mime_type(mime) when is_binary(mime) do
    case String.trim(mime) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp mime_type(_mime), do: nil

  defp created_at(%{"created_at" => at}) when is_integer(at), do: at
  defp created_at(_message), do: 0

  ## Reads

  @doc "One page of a Task's files, newest first."
  def list_task(group_id, conversation_id, opts \\ []) do
    with {:ok, page} <- TaskFiles.list_task(group_id, conversation_id, opts),
         do: {:ok, public_page(page)}
  end

  @doc "One page of a Group's Task files, newest first."
  def list_group(group_id, opts \\ []) do
    with {:ok, page} <- TaskFiles.list_group(group_id, opts), do: {:ok, public_page(page)}
  end

  @doc "A Group's Task files whose name contains `query`, newest first."
  def search(group_id, query, opts \\ []) do
    with {:ok, files} <- TaskFiles.search(group_id, query, opts),
         do: {:ok, %{"files" => Enum.map(files, &public_file/1)}}
  end

  defp public_page(%{files: files, next_cursor: next}),
    do: %{"files" => Enum.map(files, &public_file/1), "next_cursor" => next}

  @doc "A Task file as reads answer it."
  def public_file(file) do
    %{
      "conversation_id" => file.conversation_id,
      "task_title" => file.task_title,
      "message_id" => file.message_id,
      "seq" => file.seq,
      "index" => file.block_index,
      "type" => file.kind,
      "file_name" => file.file_name,
      "mime_type" => file.mime_type,
      "size" => file.size,
      "created_at" => file.created_at
    }
  end

  ## Backfill

  @doc """
  Opens the backfill after a successful core rollout, under the marker
  `task_files_v1` (`salix_cutover_markers`) and the release's `authority`: the
  release calls it only once every serving node indexes the Messages it
  appends. Answers `:opened`, `:indexing` while pages remain, or `:ready`.
  """
  @spec open_after_rollout(String.t()) ::
          {:ok, :opened | :indexing | :ready} | {:error, :invalid | :unavailable}
  def open_after_rollout(authority) when is_binary(authority) and authority != "" do
    %{num_rows: opened} =
      Repo.query!(
        "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO NOTHING",
        [
          TaskFiles.marker(),
          %{"phase" => "running", "position" => nil, "processed" => 0, "authority" => authority}
        ]
      )

    cond do
      opened == 1 -> {:ok, :opened}
      TaskFiles.ready?() -> {:ok, :ready}
      true -> {:ok, :indexing}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def open_after_rollout(_authority), do: {:error, :invalid}

  @doc """
  One page of the backfill the release opened. The marker records the
  position of the next page, so a run cut off resumes there, and Pods that run
  the same page index the same rows while only one records it. Answers
  `{:ok, :closed}` until the release opens it, `{:ok, :complete}` once it is
  done, else `{:ok, %{processed: n, done: boolean}}`. An error leaves the
  marker as it was, so the same page runs again.
  """
  @spec backfill_page() ::
          {:ok, :closed | :complete | %{processed: non_neg_integer(), done: boolean()}}
          | {:error, term()}
  def backfill_page do
    marker = TaskFiles.marker()

    case Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [marker]) do
      %{rows: []} ->
        {:ok, :closed}

      %{rows: [[%{"phase" => "complete"}]]} ->
        {:ok, :complete}

      %{rows: [[evidence]]} ->
        with {:ok, %{processed: processed, skipped: skipped, next: next}} <-
               index_page(evidence["position"]) do
          %{num_rows: recorded} =
            Repo.query!(
              "UPDATE salix_cutover_markers SET evidence = $2, completed_at = now() WHERE name = $1 AND evidence = $3",
              [
                marker,
                Map.merge(evidence, %{
                  "phase" => if(is_nil(next), do: "complete", else: "running"),
                  "position" => next,
                  "processed" => (evidence["processed"] || 0) + processed,
                  "skipped" => (evidence["skipped"] || 0) + skipped
                }),
                evidence
              ]
            )

          {:ok, %{processed: processed, done: recorded == 1 and is_nil(next)}}
        end
    end
  end

  # Indexes Tasks from `position` (nil: the first Task): at most
  # #{@backfill_tasks} Tasks and #{@backfill_messages} Messages. Answers how many
  # Messages it read, how many were lost, and the position of the next page
  # (nil: done).
  defp index_page(position) do
    {from, after_seq} =
      case position do
        %{"group_id" => group_id, "conversation_id" => conversation_id, "after_seq" => seq}
        when is_integer(seq) ->
          {{group_id, conversation_id}, seq}

        nil ->
          {nil, 0}
      end

    {page, following} = from |> tasks_from(@backfill_tasks + 1) |> Enum.split(@backfill_tasks)

    # The position's own Task resumes after its sequence; when that Task is
    # gone, the next one starts at its first Message.
    after_seq =
      case page do
        [{group_id, conversation_id, _tail} | _] when {group_id, conversation_id} == from ->
          after_seq

        _other ->
          0
      end

    backfill_tasks(page, following, after_seq, {0, 0})
  end

  defp backfill_tasks([], [], _after_seq, {processed, skipped}),
    do: {:ok, %{processed: processed, skipped: skipped, next: nil}}

  defp backfill_tasks(
         [],
         [{group_id, conversation_id, _tail} | _],
         _after_seq,
         {processed, skipped}
       ),
       do:
         {:ok,
          %{
            processed: processed,
            skipped: skipped,
            next: position(group_id, conversation_id, 0)
          }}

  defp backfill_tasks(
         [{group_id, conversation_id, tail} = task | rest],
         following,
         after_seq,
         {processed, skipped}
       ) do
    room = @backfill_messages - processed - skipped

    if room <= 0 do
      {:ok,
       %{
         processed: processed,
         skipped: skipped,
         next: position(group_id, conversation_id, after_seq)
       }}
    else
      scope = ConversationPGStore.new(group_id, conversation_id)
      last = min(tail, after_seq + min(room, @message_page))

      with {:ok, messages, lost} <- read_messages(scope, after_seq, last),
           :ok <- ConversationPGStore.index_task_files(scope, messages) do
        counts = {processed + length(messages), skipped + lost}

        if last < tail,
          do: backfill_tasks([task | rest], following, last, counts),
          else: backfill_tasks(rest, following, 0, counts)
      end
    end
  end

  defp read_messages(_scope, after_seq, last) when last <= after_seq, do: {:ok, [], 0}

  defp read_messages(scope, after_seq, last) do
    case ConversationPGStore.messages(scope, after_seq + 1, last, last - after_seq) do
      {:ok, messages} -> {:ok, messages, 0}
      {:error, :archive_incomplete} -> read_each(scope, after_seq + 1, last)
      {:error, _reason} = error -> error
    end
  end

  # A range with a lost Message: every other Message of it is still indexed.
  defp read_each(scope, first, last) do
    Enum.reduce_while(first..last//1, {:ok, [], 0}, fn seq, {:ok, messages, lost} ->
      case ConversationPGStore.messages(scope, seq, seq, 1) do
        {:ok, read} ->
          {:cont, {:ok, messages ++ read, lost}}

        {:error, :archive_incomplete} ->
          Logger.warning(
            "Task file backfill left a Message without rows: its archived body is gone " <>
              "(#{scope.group_id}/#{scope.conversation_id} seq #{seq})"
          )

          {:cont, {:ok, messages, lost + 1}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp position(group_id, conversation_id, after_seq),
    do: %{"group_id" => group_id, "conversation_id" => conversation_id, "after_seq" => after_seq}

  # Live Tasks in key order, from `from` on (itself included).
  defp tasks_from(from, limit) do
    {condition, params} =
      case from do
        nil ->
          {"", [limit]}

        {group_id, conversation_id} ->
          {"AND (group_id, conversation_id) >= ($2, $3)", [limit, group_id, conversation_id]}
      end

    %{rows: rows} =
      Repo.query!(
        """
        SELECT group_id, conversation_id, message_tail_seq FROM salix_conversations
        WHERE kind = 'agent_task' AND deleted_at IS NULL #{condition}
        ORDER BY group_id, conversation_id
        LIMIT $1
        """,
        params
      )

    Enum.map(rows, fn [group_id, conversation_id, tail] ->
      {group_id, conversation_id, tail || 0}
    end)
  end
end
