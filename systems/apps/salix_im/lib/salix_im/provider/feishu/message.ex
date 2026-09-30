defmodule SalixIM.Provider.Feishu.Message do
  @moduledoc false

  @downloadable_types ~w(file audio media image post)
  @spec normalize(map()) :: map()
  def normalize(message) when is_map(message) do
    content = decoded_content(message)
    mentions = normalize_mentions(message["mentions"])

    %{
      "message_id" => str(message["message_id"]),
      "root_id" => str(message["root_id"]),
      "parent_id" => str(message["parent_id"]),
      "thread_id" => str(message["thread_id"]),
      "chat_id" => str(message["chat_id"]),
      "message_type" => str(message["msg_type"] || message["message_type"]),
      "create_time" => str(message["create_time"]),
      "update_time" => if(message["updated"] == true, do: str(message["update_time"]), else: ""),
      "message_position" => message["message_position"],
      "thread_message_position" => message["thread_message_position"],
      "message_app_link" => str(message["message_app_link"]),
      "deleted" => message["deleted"] == true,
      "updated" => message["updated"] == true,
      "sender" => normalize_sender(message["sender"] || %{}),
      "mentions" => mentions,
      "text" => content |> content_text() |> resolve_mentions(mentions),
      "links" => content_links(content),
      "attachments" => content_attachments(message, content)
    }
  end

  def normalize(_message), do: %{}

  @spec text(map()) :: String.t()
  def text(message) when is_map(message), do: message |> decoded_content() |> content_text()
  def text(_message), do: ""

  @spec attachments(map()) :: [map()]
  def attachments(message) when is_map(message),
    do: content_attachments(message, decoded_content(message))

  def attachments(_message), do: []

  defp decoded_content(message) do
    body = if is_map(message["body"]), do: message["body"], else: %{}
    raw = body["content"] || message["content"]

    case raw do
      value when is_map(value) or is_list(value) ->
        value

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} -> decoded
          _ -> %{"text" => value}
        end

      _ ->
        %{}
    end
  end

  defp normalize_sender(sender) when is_map(sender) do
    id = sender["id"] || sender["sender_id"] || %{}

    %{
      "id" =>
        if(is_map(id), do: first([id["open_id"], id["user_id"], id["union_id"]]), else: str(id)),
      "id_type" => str(sender["id_type"]),
      "sender_type" => str(sender["sender_type"]),
      "name" => first([sender["sender_name"], sender["name"]]),
      "sender_i18n_names" =>
        if(is_map(sender["sender_i18n_names"]), do: sender["sender_i18n_names"], else: %{}),
      "open_bot_id" => str(sender["open_bot_id"])
    }
  end

  defp normalize_sender(_sender), do: %{}

  defp normalize_mentions(mentions) do
    mentions
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn mention ->
      id = mention["id"] || %{}

      %{
        "key" => str(mention["key"]),
        "id" =>
          if(is_map(id), do: first([id["open_id"], id["user_id"], id["union_id"]]), else: str(id)),
        "name" => str(mention["name"]),
        "tenant_key" => str(mention["tenant_key"])
      }
    end)
  end

  defp resolve_mentions(text, mentions) do
    Enum.reduce(mentions, text, fn mention, acc ->
      case {mention["key"], mention["name"]} do
        {key, name} when key != "" and name != "" -> String.replace(acc, key, "@" <> name)
        _ -> acc
      end
    end)
  end

  defp content_text(%{"text" => text}) when is_binary(text), do: String.trim(text)

  defp content_text(content) do
    content
    |> collect_values(fn
      %{"tag" => "text", "text" => text} when is_binary(text) -> text
      %{"tag" => "a", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp content_links(content) do
    content
    |> collect_values(fn
      %{"href" => href} = node when is_binary(href) ->
        %{"url" => href, "text" => str(node["text"])}

      _ ->
        nil
    end)
    |> Enum.uniq_by(& &1["url"])
  end

  defp content_attachments(message, content) do
    message_type = str(message["msg_type"] || message["message_type"])

    if message_type in @downloadable_types or contains_resource_key?(content) do
      content
      |> collect_values(&attachment_from_node(&1, message_type))
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1["resource_type"], &1["file_key"]})
    else
      []
    end
  end

  defp attachment_from_node(node, message_type) when is_map(node) do
    file =
      case str(node["file_key"]) do
        "" ->
          []

        key ->
          [
            %{
              "file_key" => key,
              "resource_type" => "file",
              "file_name" =>
                first([node["file_name"], node["name"], default_file_name(message_type)]),
              "mime_type" => guessed_mime(message_type, node["file_name"])
            }
          ]
      end

    image =
      case str(node["image_key"]) do
        "" ->
          []

        key ->
          [
            %{
              "file_key" => key,
              "resource_type" => "image",
              "file_name" => first([node["file_name"], node["name"], "image.png"]),
              "mime_type" => "image/png"
            }
          ]
      end

    file ++ image
  end

  defp attachment_from_node(_node, _message_type), do: nil

  defp contains_resource_key?(value) when is_map(value) do
    str(value["file_key"]) != "" or str(value["image_key"]) != "" or
      Enum.any?(Map.values(value), &contains_resource_key?/1)
  end

  defp contains_resource_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_resource_key?/1)

  defp contains_resource_key?(_value), do: false

  defp collect_values(value, mapper), do: collect_values(value, mapper, []) |> Enum.reverse()

  defp collect_values(value, mapper, acc) when is_map(value) do
    acc =
      case mapper.(value) do
        nil -> acc
        [] -> acc
        mapped -> [mapped | acc]
      end

    Enum.reduce(Map.values(value), acc, &collect_values(&1, mapper, &2))
  end

  defp collect_values(value, mapper, acc) when is_list(value),
    do: Enum.reduce(value, acc, &collect_values(&1, mapper, &2))

  defp collect_values(_value, _mapper, acc), do: acc

  defp default_file_name("audio"), do: "audio.mp3"
  defp default_file_name(type) when type in ["media", "video"], do: "video.mp4"
  defp default_file_name(_type), do: "attachment.bin"

  defp guessed_mime(type, filename) do
    case Path.extname(str(filename)) |> String.downcase() do
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      extension when extension in [".jpg", ".jpeg"] -> "image/jpeg"
      ".gif" -> "image/gif"
      ".mp3" -> "audio/mpeg"
      ".wav" -> "audio/wav"
      ".mp4" -> "video/mp4"
      _ when type == "audio" -> "audio/mpeg"
      _ when type in ["media", "video"] -> "video/mp4"
      _ -> "application/octet-stream"
    end
  end

  defp first(values) do
    values
    |> Enum.map(&str/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp str(nil), do: ""
  defp str(value) when is_binary(value), do: String.trim(value)

  defp str(value) when is_atom(value) or is_number(value),
    do: value |> to_string() |> String.trim()

  defp str(_value), do: ""
end
