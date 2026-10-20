defmodule SalixIM.Provider.Feishu.MessageSearch do
  @moduledoc """
  `im_api.feishu.search_messages`: keyword search over the Feishu mirror.

  The Feishu counterpart of `slack.search` (`SalixIM.Provider.Slack.MessageRead`).
  It reads the local index (`SalixIM.FeishuMessageMirror`), never a Feishu
  search API, and is scoped to the caller's connect: its tenant and its app.
  The query grammar is `SalixIM.Provider.Slack.SearchQuery`'s `:feishu`
  dialect.

  Mirror-only facts ride on the response: `stale` on a hit that has a newer
  undrained observation, and `incomplete` when part of the searched range is
  not walked by the history backfill yet. Each hit is labelled by its chat for
  information-flow control, so citing one hit is exactly as restrictive as
  that hit's chat.
  """

  import SalixIM.Provider.Util

  alias SalixIM.FeishuMessageMirror
  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Provider.Slack.SearchQuery
  alias SalixStore.{FeishuMirrorBackfillLedger, FeishuMirrorOutbox}

  @params ~w(query count cursor sort sort_dir thread_id)
  @default_count 30
  @max_count 200

  @doc """
  Runs one search page. `normalize` turns a reconstructed Feishu message object
  into the same agent-facing shape `feishu.get_chat_history` returns.
  """
  @spec search(map(), map(), (map() -> map())) :: {:ok, map()} | {:error, String.t()}
  def search(connect, params, normalize) when is_map(connect) and is_map(params) do
    params = Map.reject(params, fn {key, _value} -> String.starts_with?(to_string(key), "__") end)

    with :ok <- reject_unknown(params),
         {:ok, parsed} <- SearchQuery.parse(params["query"], :feishu),
         {:ok, count} <- count(params["count"]),
         {:ok, sort_dir} <- sort(params["sort"], params["sort_dir"]),
         {:ok, cursor} <- decode_cursor(params["cursor"], sort_dir),
         {:ok, thread_id} <- thread_id(params["thread_id"]),
         {:ok, reader} <- reader(),
         scope = scope(connect),
         {:ok, page} <-
           reader.search(scope, reader_opts(parsed, thread_id, count, sort_dir, cursor)) do
      messages = Enum.map(page.messages, &message(&1, normalize))

      result =
        %{
          "query" => params["query"],
          "messages" => mark_stale(scope, messages),
          "has_more" => page.has_more? == true,
          "response_metadata" => %{"next_cursor" => encode_cursor(page.next_cursor, sort_dir)}
        }
        |> put_incomplete(scope, parsed)

      {:ok, put_ifc(result, ReadLabels.for_messages(connect, result["messages"], "chat_id"))}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  # The reader returns mirror rows. They are put back into the Feishu message
  # object shape so attachments get the same resource refs as history pages;
  # the stored text already has mentions resolved, so it replaces the
  # re-derived one.
  defp message(row, normalize) do
    %{
      "message_id" => row["message_id"],
      "chat_id" => row["chat_id"],
      "root_id" => row["root_id"],
      "parent_id" => row["parent_id"],
      "thread_id" => row["thread_id"],
      "msg_type" => row["message_type"],
      "create_time" => Integer.to_string(div(row["create_time_us"], 1_000)),
      "body" => %{"content" => row["content"]},
      "sender" => %{
        "id" => row["actor_id"],
        "sender_type" => row["actor_kind"],
        "sender_name" => row["actor_label"]
      }
    }
    |> normalize.()
    |> Map.put("text", row["text"])
  end

  defp reader do
    reader = SystemsRuntime.get_env(:salix_im, :feishu_mirror_reader_mod)

    if FeishuMessageMirror.enabled?() and is_atom(reader) and not is_nil(reader),
      do: {:ok, reader},
      else: {:error, :search_unavailable}
  end

  defp scope(connect),
    do: %{"tenant_id" => str(connect["tenant_id"]), "app_id" => str(connect["app_id"])}

  defp reader_opts(parsed, thread_id, count, sort_dir, cursor) do
    [
      limit: count,
      patterns: patterns(parsed.clauses),
      exclude_patterns: Enum.map(parsed.exclude_terms, &like/1),
      actor_id: parsed.actor_id,
      chat_id: parsed.channel_id,
      thread_id: thread_id,
      after_us: date_us(parsed.after_date),
      before_us: date_us(parsed.before_date),
      has_file: parsed.has_file,
      sort_dir: sort_dir,
      cursor_ts_us: cursor && elem(cursor, 0),
      cursor_message_id: cursor && elem(cursor, 1)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, false, ""] end)
  end

  defp patterns([terms]), do: Enum.map(terms, &like/1)
  defp patterns(clauses), do: Enum.map(clauses, fn terms -> Enum.map(terms, &like/1) end)

  defp like(term) do
    "%" <>
      (term
       |> String.replace("\\", "\\\\")
       |> String.replace("%", "\\%")
       |> String.replace("_", "\\_")) <> "%"
  end

  defp mark_stale(_scope, []), do: []

  defp mark_stale(scope, messages) do
    pairs = Enum.map(messages, &{&1["chat_id"], &1["message_id"]})

    case FeishuMirrorOutbox.pending_message_keys(scope, pairs) do
      {:ok, []} ->
        messages

      {:ok, pending} ->
        pending = MapSet.new(pending)

        Enum.map(messages, fn message ->
          if MapSet.member?(pending, {message["chat_id"], message["message_id"]}),
            do: Map.put(message, "stale", true),
            else: message
        end)

      {:error, _reason} ->
        messages
    end
  end

  defp put_incomplete(result, scope, parsed) do
    case FeishuMirrorBackfillLedger.coverage(
           scope,
           parsed.channel_id,
           date_us(parsed.after_date) || 0
         ) do
      {:ok, :complete} ->
        result

      {:ok, {:incomplete, older_than_us}} when is_integer(older_than_us) ->
        Map.put(result, "incomplete", %{
          "reason" => "not_synced",
          "older_than" => Integer.to_string(div(older_than_us, 1_000))
        })

      {:ok, _not_synced_or_unstarted} ->
        Map.put(result, "incomplete", %{"reason" => "not_synced"})

      {:error, _reason} ->
        result
    end
  end

  defp put_ifc(result, nil), do: result
  defp put_ifc(result, ifc), do: Map.put(result, "__ifc__", ifc)

  defp reject_unknown(params) do
    if Enum.all?(Map.keys(params), &(to_string(&1) in @params)),
      do: :ok,
      else: {:error, "invalid_arguments"}
  end

  defp count(value) do
    case int_or(value, 0) do
      n when n <= 0 -> {:ok, @default_count}
      n -> {:ok, min(n, @max_count)}
    end
  end

  defp sort(sort, sort_dir) do
    case {String.downcase(str(sort)), String.downcase(str(sort_dir))} do
      {"score", _dir} -> {:error, "sort=score is not supported; sort is timestamp only"}
      {sort, _dir} when sort not in ["", "timestamp"] -> {:error, "invalid_arguments"}
      {_sort, "asc"} -> {:ok, :asc}
      {_sort, dir} when dir in ["", "desc"] -> {:ok, :desc}
      _invalid -> {:error, "invalid_arguments"}
    end
  end

  defp thread_id(nil), do: {:ok, nil}

  defp thread_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      id when byte_size(id) <= 128 -> {:ok, id}
      _long -> {:error, "invalid_arguments"}
    end
  end

  defp thread_id(_value), do: {:error, "invalid_arguments"}

  defp decode_cursor(value, _sort_dir) when value in [nil, ""], do: {:ok, nil}

  defp decode_cursor(value, sort_dir) when is_binary(value) do
    dir = if(sort_dir == :asc, do: "a", else: "d")

    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- String.valid?(decoded),
         [^dir, ts, message_id] <- String.split(decoded, ":", parts: 3),
         {ts_us, ""} when ts_us >= 0 <- Integer.parse(ts),
         true <- message_id != "" and message_id == String.trim(message_id) do
      {:ok, {ts_us, message_id}}
    else
      _invalid -> {:error, "invalid_arguments"}
    end
  end

  defp decode_cursor(_value, _sort_dir), do: {:error, "invalid_arguments"}

  defp encode_cursor({ts_us, message_id}, sort_dir) do
    dir = if(sort_dir == :asc, do: "a", else: "d")
    Base.url_encode64("#{dir}:#{ts_us}:#{message_id}", padding: false)
  end

  defp encode_cursor(_cursor, _sort_dir), do: ""

  defp date_us(nil), do: nil

  defp date_us(%Date{} = date),
    do: (Date.to_gregorian_days(date) - Date.to_gregorian_days(~D[1970-01-01])) * 86_400_000_000

  defp error(:search_unavailable),
    do: "Feishu search is unavailable (message index is not configured)"

  defp error({:read_over_budget, _detail}),
    do: "Feishu search is unavailable; narrow with in:, from:, after:, or a longer keyword"

  defp error(reason)
       when reason in [:invalid_feishu_mirror_read, :invalid_feishu_mirror_scope],
       do: "Feishu search is invalid"

  defp error(reason), do: "Feishu search is unavailable (#{inspect(reason)})"
end
