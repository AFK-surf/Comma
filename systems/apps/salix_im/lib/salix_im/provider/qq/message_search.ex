defmodule SalixIM.Provider.QQ.MessageSearch do
  @moduledoc """
  `im_api.qq.search_messages`: reads the record of QQ group messages
  (`SalixIM.QQMessageRecord`).

  QQ has no history or search API, so this reads only what the bot was sent
  and what it sent. A search is scoped to the caller's connect: its tenant and
  its bot. Each hit is labelled by its group for information-flow control, as a
  Feishu search hit is by its chat.
  """

  import SalixIM.Provider.Util

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.QQMessageRecord

  @params ~w(query chat_id from_user_id after before count cursor)
  @default_count 30
  @max_count 100
  @max_terms 6

  @spec search(map(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def search(connect, params, origin) when is_map(connect) and is_map(params) do
    params = Map.reject(params, fn {key, _value} -> String.starts_with?(to_string(key), "__") end)

    with :ok <- reject_unknown(params),
         {:ok, terms} <- terms(params["query"]),
         {:ok, chat_id} <- chat_id(params["chat_id"], terms, origin),
         {:ok, after_us} <- date_us(params["after"]),
         {:ok, before_us} <- date_us(params["before"]),
         {:ok, cursor} <- decode_cursor(params["cursor"]),
         {:ok, reader} <- reader() do
      scope = QQMessageRecord.scope(connect)

      opts =
        [
          limit: count(params["count"]),
          patterns: Enum.map(terms, &like/1),
          chat_id: chat_id,
          actor_id: presence(str(params["from_user_id"])),
          after_us: after_us,
          before_us: before_us,
          cursor_ts_us: cursor && elem(cursor, 0),
          cursor_message_id: cursor && elem(cursor, 1)
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)

      case reader.search(scope, opts) do
        {:ok, page} ->
          messages = page.messages |> Enum.map(&message/1) |> mark_stale(scope)

          result = %{
            "messages" => messages,
            "has_more" => page.has_more? == true,
            "next_cursor" => encode_cursor(page.next_cursor),
            "coverage" =>
              "Only messages QQ delivered to the bot: mentions, and every message of a group whose admin lets the bot read all messages. Nothing from before the bot joined."
          }

          {:ok, put_ifc(result, ReadLabels.for_messages(connect, messages, "chat_id"))}

        {:error, {:read_over_budget, _detail}} ->
          {:error,
           "QQ message search took too long; narrow it with chat_id, after or a longer keyword"}

        {:error, _reason} ->
          {:error, "QQ message search is unavailable"}
      end
    end
  end

  # Newest first; a page reads top to bottom as newest to oldest.
  defp message(row) do
    content =
      case Jason.decode(row["content"]) do
        {:ok, %{} = content} -> content
        _other -> %{}
      end

    files = if is_list(content["files"]), do: content["files"], else: []

    %{
      "message_id" => row["message_id"],
      "chat_id" => row["chat_id"],
      "sent_at" =>
        row["create_time_us"] |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
      "from_user_id" => row["actor_id"],
      "from_name" => row["actor_label"],
      "from_bot" => row["actor_kind"] == "app",
      "text" => row["text"]
    }
    |> maybe_put("files", if(files == [], do: nil, else: public_files(files)))
    |> maybe_put("from_role", content["role"])
    # A member joined or left, or a person asked to join: not a message.
    |> maybe_put("event", content["event"])
  end

  # A file is named by its position in the message; `qq.fetch_file` takes it.
  defp public_files(files) do
    files
    |> Enum.with_index()
    |> Enum.map(fn {file, index} ->
      file |> Map.take(~w(name type size)) |> Map.put("file_index", index)
    end)
  end

  @doc """
  `im_api.qq.fetch_file`: downloads one file of a recorded group message into
  the agent's workspace. QQ's download address is signed and expires; a file
  that can no longer be read needs to be sent again.
  """
  @spec fetch_file(String.t() | nil, map(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def fetch_file(agent_id, connect, params, origin) when is_map(connect) and is_map(params) do
    message_id = str(params["message_id"])
    index = int_or(params["file_index"], 0)

    with {:ok, chat_id} <- file_chat_id(params["chat_id"], origin),
         true <- message_id != "" || {:error, "message_id is required"},
         true <-
           to_string(agent_id || "") != "" || {:error, "agent VFS is not available for this call"},
         {:ok, reader} <- reader(),
         {:ok, row} <- recorded(reader, QQMessageRecord.scope(connect), chat_id, message_id),
         {:ok, file} <- recorded_file(row, index) do
      name = file_name(file)

      digest =
        [connect["connect_id"], chat_id, message_id, index]
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      path = "/qq/files/#{digest}-#{name}"

      with {:ok, %{ref: ref} = blob} <-
             SalixIM.QQFiles.download(agent_id, file["url"], SalixIM.QQFiles.max_bytes()),
           {:ok, _put} <- stage(agent_id, path, ref) do
        result = %{
          "vfs_path" => path,
          "name" => str(file["name"]),
          "mimetype" => str(file["type"]),
          "size" => blob[:size] || file["size"]
        }

        {:ok,
         put_ifc(result, ReadLabels.for_messages(connect, [%{"chat_id" => chat_id}], "chat_id"))}
      else
        {:error, {:size_limit, _size, max}} ->
          {:error, "the file is larger than the #{max} byte limit"}

        # Sending the file again does not help here: QQ served it.
        {:error, :workspace_unavailable} ->
          {:error, "the file was downloaded and could not be saved to the workspace; try again"}

        {:error, reason} when reason in [:qq_file_storage_unavailable] ->
          {:error, "the file could not be stored; try again"}

        {:error, _reason} ->
          {:error,
           "QQ no longer serves this file. Its download address expires; ask the sender to send the file again and mention the bot."}
      end
    end
  end

  defp stage(agent_id, path, ref) do
    case SalixIM.Ports.AgentWorkspace.put_ref(agent_id, path, ref) do
      {:ok, _put} = ok -> ok
      {:error, _reason} -> {:error, :workspace_unavailable}
    end
  end

  defp file_chat_id(value, origin) do
    case {str(value), str(origin["chat_id"])} do
      {"group:" <> _ = chat_id, _source} -> {:ok, chat_id}
      {"", "group:" <> _ = chat_id} -> {:ok, chat_id}
      _other -> {:error, "chat_id must be group:<group_openid>"}
    end
  end

  defp recorded(reader, scope, chat_id, message_id) do
    case reader.get_message(scope, chat_id, message_id) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, "no recorded message with this message_id in this group"}
      {:error, _reason} -> {:error, "QQ message record is unavailable"}
    end
  end

  defp recorded_file(row, index) do
    files =
      case Jason.decode(row["content"]) do
        {:ok, %{"files" => files}} when is_list(files) -> files
        _other -> []
      end

    case Enum.at(files, index) do
      %{"url" => url} = file when is_binary(url) and url != "" and index >= 0 -> {:ok, file}
      _missing -> {:error, "this message has no file at file_index #{index}"}
    end
  end

  defp file_name(file) do
    file["name"]
    |> str()
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9._-]+/u, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "file"
      name -> name
    end
  end

  # A hit with a newer row still waiting in the outbox.
  defp mark_stale([], _scope), do: []

  defp mark_stale(messages, scope) do
    pairs = Enum.map(messages, &{&1["chat_id"], &1["message_id"]})

    case QQMessageRecord.outbox().pending_message_keys(scope, pairs) do
      {:ok, [_ | _] = pending} ->
        pending = MapSet.new(pending)

        Enum.map(messages, fn message ->
          if MapSet.member?(pending, {message["chat_id"], message["message_id"]}),
            do: Map.put(message, "stale", true),
            else: message
        end)

      _none_or_error ->
        messages
    end
  end

  defp reader do
    case QQMessageRecord.reader() do
      nil -> {:error, "QQ message search is unavailable: the message record is not configured"}
      reader -> {:ok, reader}
    end
  end

  defp reject_unknown(params) do
    if Enum.all?(Map.keys(params), &(to_string(&1) in @params)),
      do: :ok,
      else: {:error, "invalid_arguments"}
  end

  defp terms(nil), do: {:ok, []}

  defp terms(query) when is_binary(query) do
    terms = String.split(query)

    if length(terms) <= @max_terms,
      do: {:ok, terms},
      else: {:error, "query takes at most #{@max_terms} words"}
  end

  defp terms(_query), do: {:error, "invalid_arguments"}

  # A read defaults to the group of the current QQ source. `all` searches
  # every group of this bot and needs keywords.
  defp chat_id(value, terms, origin) do
    case str(value) do
      "all" when terms != [] ->
        {:ok, nil}

      "all" ->
        {:error, "chat_id all needs a query"}

      "" ->
        case str(origin["chat_id"]) do
          "group:" <> _openid = chat_id -> {:ok, chat_id}
          _other when terms != [] -> {:ok, nil}
          _other -> {:error, "chat_id or query is required outside a QQ group source"}
        end

      "group:" <> openid = chat_id ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, openid),
          do: {:ok, chat_id},
          else: {:error, "chat_id must be group:<group_openid>"}

      _other ->
        {:error, "chat_id must be group:<group_openid>; private chats are not recorded"}
    end
  end

  defp count(value) do
    case int_or(value, 0) do
      n when n <= 0 -> @default_count
      n -> min(n, @max_count)
    end
  end

  defp date_us(value) when value in [nil, ""], do: {:ok, nil}

  defp date_us(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} ->
        {:ok, Date.diff(date, ~D[1970-01-01]) * 86_400_000_000}

      _invalid ->
        {:error, "after and before take a date as YYYY-MM-DD (UTC)"}
    end
  end

  defp date_us(_value), do: {:error, "invalid_arguments"}

  defp like(term) do
    "%" <>
      (term
       |> String.replace("\\", "\\\\")
       |> String.replace("%", "\\%")
       |> String.replace("_", "\\_")) <> "%"
  end

  defp decode_cursor(value) when value in [nil, ""], do: {:ok, nil}

  defp decode_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- String.valid?(decoded),
         [ts, message_id] <- String.split(decoded, ":", parts: 2),
         {ts_us, ""} when ts_us >= 0 <- Integer.parse(ts),
         true <- message_id != "" and message_id == String.trim(message_id) do
      {:ok, {ts_us, message_id}}
    else
      _invalid -> {:error, "invalid_arguments"}
    end
  end

  defp decode_cursor(_value), do: {:error, "invalid_arguments"}

  defp encode_cursor({ts_us, message_id}),
    do: Base.url_encode64("#{ts_us}:#{message_id}", padding: false)

  defp encode_cursor(_cursor), do: ""

  defp put_ifc(result, nil), do: result
  defp put_ifc(result, ifc), do: Map.put(result, "__ifc__", ifc)
end
