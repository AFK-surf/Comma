defmodule SalixIM.Provider.Slack.ThreadHistory do
  @moduledoc false

  import SalixIM.Provider.Util, only: [str: 1]

  alias SalixIM.Provider.Slack.{MessageReferences, Permalink, TableBlocks, TaskCards}

  @spec result(map(), keyword()) :: map()
  def result(response, opts \\ []) when is_map(response) do
    summary_opts = Keyword.take(opts, [:channel_id, :base_url, :keep_channel])

    case Keyword.get(opts, :before_ts) |> presence() do
      nil ->
        page_result(response, Keyword.get(opts, :exclude_ts), summary_opts)

      before_ts ->
        previous_page_result(
          response,
          before_ts,
          Keyword.fetch!(opts, :limit),
          Keyword.get(opts, :exclude_ts),
          summary_opts
        )
    end
  end

  @spec summary(map(), keyword()) :: map()
  def summary(message, opts \\ []) when is_map(message) do
    message_summary(message, opts)
  end

  @spec previous_messages([map()], String.t(), pos_integer()) :: [map()]
  def previous_messages(messages, before_ts, limit)
      when is_list(messages) and is_binary(before_ts) and is_integer(limit) and limit > 0 do
    messages
    |> first_context(before_ts, limit)
    |> Map.fetch!(:messages)
  end

  @spec first_context([map()], String.t(), pos_integer()) :: %{
          messages: [map()],
          has_more: boolean()
        }
  def first_context(messages, before_ts, limit)
      when is_list(messages) and is_binary(before_ts) and is_integer(limit) and limit > 0 do
    candidates =
      messages
      |> Enum.map(&message_summary/1)
      |> Enum.filter(&ts_before?(&1["ts"], before_ts))
      |> Enum.sort_by(&ts_sort_key(&1["ts"]))

    %{messages: Enum.take(candidates, limit), has_more: length(candidates) > limit}
  end

  @spec valid_timestamp?(term()) :: boolean()
  def valid_timestamp?(value), do: match?({_seconds, _micros}, ts_sort_key(value))

  defp page_result(response, exclude_ts, summary_opts) do
    %{
      "messages" =>
        response
        |> Map.get("messages", [])
        |> List.wrap()
        |> Enum.map(&message_summary(&1, summary_opts))
        |> Enum.reject(&(&1["ts"] == exclude_ts))
    }
    |> put_boolean("has_more", response["has_more"])
    |> put_present("next_cursor", next_cursor(response))
  end

  defp previous_page_result(response, before_ts, limit, exclude_ts, summary_opts) do
    candidates =
      response
      |> Map.get("messages", [])
      |> List.wrap()
      |> Enum.map(&message_summary(&1, summary_opts))
      |> Enum.filter(&ts_before?(&1["ts"], before_ts))
      |> Enum.reject(&(&1["ts"] == exclude_ts))
      |> Enum.sort_by(&ts_sort_key(&1["ts"]))

    messages = Enum.take(candidates, limit)
    cursor = next_cursor(response)

    has_more =
      presence(cursor) != nil or
        (messages != [] and
           (response["has_more"] == true or length(candidates) > length(messages)))

    %{
      "messages" => messages,
      "has_more" => has_more
    }
    |> put_when(has_more, "next_cursor", cursor)
  end

  defp message_summary(message, opts \\ []) do
    base =
      Map.take(message, [
        "type",
        "subtype",
        "user",
        "username",
        "bot_id",
        "text",
        "ts",
        "thread_ts",
        "reply_count"
      ])

    # File history keeps metadata; selected bytes are staged by slack.fetch_file.
    # Native Task output and forwarded references keep bounded visible text and
    # visible output links. Tables keep their cells as Markdown. Raw blocks,
    # actions and private file URLs stay out.
    base
    |> maybe_put_channel(message, opts)
    |> maybe_put_permalink(message, opts)
    |> maybe_put_reactions(message["reactions"])
    |> maybe_put_files(message["files"])
    |> maybe_put_tables(TableBlocks.from_message(message))
    |> maybe_put_source_references(MessageReferences.from_message(message))
    |> maybe_put_task_cards(TaskCards.from_message(message))
  end

  defp maybe_put_channel(base, message, opts) do
    if Keyword.get(opts, :keep_channel) == true do
      put_present(base, "channel", message["channel"] || Keyword.get(opts, :channel_id))
    else
      base
    end
  end

  defp maybe_put_permalink(base, message, opts) do
    base_url = Keyword.get(opts, :base_url)
    channel_id = presence(message["channel"] || Keyword.get(opts, :channel_id))

    if is_binary(base_url) and is_binary(channel_id) do
      case Permalink.build(base_url, channel_id, message["ts"], message["thread_ts"]) do
        url when is_binary(url) -> Map.put(base, "permalink", url)
        nil -> base
      end
    else
      base
    end
  end

  defp maybe_put_reactions(base, reactions) when is_list(reactions) do
    compact =
      Enum.reduce(reactions, [], fn
        %{"name" => name} = reaction, acc when is_binary(name) and name != "" ->
          users = Enum.filter(List.wrap(reaction["users"]), &is_binary/1)

          count =
            case reaction["count"] do
              n when is_integer(n) and n > 0 -> n
              _ -> length(users)
            end

          if count > 0 do
            entry = %{"name" => name, "count" => count}
            entry = if users != [], do: Map.put(entry, "users", Enum.take(users, 10)), else: entry
            [entry | acc]
          else
            acc
          end

        _other, acc ->
          acc
      end)
      |> Enum.reverse()

    case compact do
      [] -> base
      list -> Map.put(base, "reactions", list)
    end
  end

  defp maybe_put_reactions(base, _reactions), do: base

  defp maybe_put_files(base, files) do
    case files |> List.wrap() |> Enum.filter(&is_map/1) do
      [] -> base
      files -> Map.put(base, "files", Enum.map(files, &file_metadata/1))
    end
  end

  defp maybe_put_tables(base, []), do: base
  defp maybe_put_tables(base, tables), do: Map.put(base, "tables", tables)

  defp maybe_put_task_cards(base, []), do: base
  defp maybe_put_task_cards(base, cards), do: Map.put(base, "task_cards", cards)

  defp maybe_put_source_references(base, []), do: base

  defp maybe_put_source_references(base, references),
    do: Map.put(base, "source_references", references)

  defp file_metadata(file) do
    %{
      "id" => str(file["id"]),
      "name" => str(file["name"]),
      "mimetype" => SalixIM.SlackFiles.mime(file),
      "size" => file["size"]
    }
  end

  defp ts_before?(value, before_ts) do
    case {ts_sort_key(value), ts_sort_key(before_ts)} do
      {{seconds, micros}, {before_seconds, before_micros}} ->
        {seconds, micros} < {before_seconds, before_micros}

      _ ->
        false
    end
  end

  defp ts_sort_key(value) do
    case String.split(str(value), ".", parts: 2) do
      [seconds, micros] ->
        with true <- byte_size(micros) in 1..6,
             {seconds, ""} when seconds >= 0 <- Integer.parse(seconds),
             {micros, ""} when micros >= 0 <-
               micros |> String.pad_trailing(6, "0") |> Integer.parse() do
          {seconds, micros}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp next_cursor(%{"response_metadata" => %{"next_cursor" => cursor}}), do: str(cursor)
  defp next_cursor(_response), do: ""

  defp put_boolean(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp put_boolean(map, _key, _value), do: map

  defp put_present(map, key, value) do
    case presence(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp put_when(map, true, key, value), do: put_present(map, key, value)
  defp put_when(map, false, _key, _value), do: map

  defp presence(value) do
    case str(value) do
      "" -> nil
      value -> value
    end
  end
end
