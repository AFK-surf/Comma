defmodule CommaWeb.ProactiveMailSource do
  @moduledoc "Bounded Gmail reads through the existing account-pinned Composio proxy."

  @max_messages 20
  @max_text_bytes 8_000
  @max_thread_bytes 12_000

  # The native endpoint supplies MIME and thread identity together. Composio's
  # summary tools do not establish that a snippet is the complete message body.
  # The existing proxy adapter owns authentication and HTTP transport.
  def read(settings, group, account, message_id) do
    if valid_id?(message_id) do
      with {:ok, session} <-
             client().create_proxy_session(settings, group, account, "gmail",
               error_mode: :structured
             ) do
        try do
          with {:ok, profile} <- get(settings, session, "profile"),
               email when is_binary(email) and email != "" <- profile["emailAddress"],
               {:ok, message} <-
                 get(settings, session, "messages/" <> message_id <> "?format=full"),
               true <- message["id"] == message_id and valid_id?(message["threadId"]),
               {:ok, thread} <-
                 get(settings, session, "threads/" <> message["threadId"] <> "?format=full"),
               {:ok, result} <- normalize(message, thread, email) do
            {:ok, result}
          else
            {:error, _} = error -> error
            _ -> {:error, :invalid_mail_response}
          end
        after
          client().delete_proxy_session(settings, session)
        end
      end
    else
      {:error, :invalid_message_id}
    end
  end

  def normalize(message, thread, email) do
    messages = thread["messages"]

    with true <- thread["id"] == message["threadId"],
         true <- is_list(messages) and length(messages) in 1..@max_messages,
         true <- Enum.all?(messages, &(is_map(&1) and &1["threadId"] == thread["id"])),
         true <- Enum.any?(messages, &(&1["id"] == message["id"])),
         {:ok, normalized} <- normalize_messages(messages),
         true <- byte_size(Jason.encode!(normalized)) <= @max_thread_bytes do
      {:ok,
       %{
         "message_id" => message["id"],
         "thread_id" => thread["id"],
         "mailbox" => email,
         "url" =>
           "https://mail.google.com/mail/?authuser=" <>
             URI.encode_www_form(email) <> "#inbox/" <> message["id"],
         "messages" => normalized,
         "thread_complete" => true,
         "attachments_read" => false
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :mail_thread_incomplete_or_too_large}
    end
  end

  @doc "Plain text of one Gmail API message: its text/plain parts, else its HTML as text."
  def text(message) when is_map(message) do
    with {:ok, parts} <- parts(message["payload"] || %{}, 0), do: body_text(parts)
  end

  defp normalize_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case normalize_message(message) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1["sent_at_ms"])}
      error -> error
    end
  end

  defp normalize_message(message) do
    payload = message["payload"] || %{}

    headers =
      Map.new(payload["headers"] || [], fn h -> {String.downcase(h["name"] || ""), h["value"]} end)

    with {:ok, parts} <- parts(payload, 0),
         {:ok, text} <- body_text(parts),
         true <- text != "" and byte_size(text) <= @max_text_bytes,
         true <- valid_id?(message["id"]) and is_list(message["labelIds"]),
         {at, ""} <- Integer.parse(to_string(message["internalDate"] || "")) do
      {:ok,
       %{
         "message_id" => message["id"],
         "subject" => headers["subject"] || "",
         "from" => headers["from"] || "",
         "to" => headers["to"] || "",
         "cc" => headers["cc"] || "",
         "body" => text,
         "labels" => message["labelIds"],
         "sent_at_ms" => at,
         "attachments" => parts |> Enum.map(& &1["filename"]) |> Enum.reject(&(&1 in [nil, ""]))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :mail_body_unavailable_or_too_large}
    end
  end

  defp parts(_part, depth) when depth > 8, do: {:error, :mail_mime_too_deep}

  defp parts(part, depth) when is_map(part) do
    children = part["parts"] || []

    if is_list(children) and length(children) <= 32 do
      Enum.reduce_while(children, {:ok, [Map.delete(part, "parts")]}, fn child, {:ok, acc} ->
        case parts(child, depth + 1) do
          {:ok, nested} when length(nested) + length(acc) <= 64 -> {:cont, {:ok, acc ++ nested}}
          _ -> {:halt, {:error, :mail_mime_too_large}}
        end
      end)
    else
      {:error, :invalid_mail_mime}
    end
  end

  defp parts(_, _), do: {:error, :invalid_mail_mime}

  defp body_text(parts) do
    inline = Enum.filter(parts, &(&1["filename"] in [nil, ""]))
    plain = Enum.filter(inline, &(&1["mimeType"] == "text/plain"))

    selected =
      if plain == [], do: Enum.filter(inline, &(&1["mimeType"] == "text/html")), else: plain

    Enum.reduce_while(selected, {:ok, []}, fn part, {:ok, texts} ->
      case Base.url_decode64(get_in(part, ["body", "data"]) || "", padding: false) do
        {:ok, data} when data != "" ->
          if String.valid?(data) do
            text =
              if part["mimeType"] == "text/html" do
                case Floki.parse_document(data) do
                  {:ok, tree} -> tree |> Floki.filter_out("script,style") |> Floki.text(sep: " ")
                  _ -> ""
                end
              else
                data
              end

            {:cont, {:ok, [text | texts]}}
          else
            {:halt, {:error, :mail_body_encoding_unavailable}}
          end

        _ ->
          {:halt, {:error, :mail_body_unavailable_or_too_large}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
      error -> error
    end
  end

  defp get(settings, session, path) do
    case client().proxy_execute(
           settings,
           session,
           %{
             "toolkit_slug" => "gmail",
             "endpoint" => "https://gmail.googleapis.com/gmail/v1/users/me/" <> path,
             "method" => "GET"
           },
           error_mode: :structured,
           max_response_bytes: 512_000
         ) do
      {:ok, %{"status" => 200, "data" => data}} when is_map(data) -> {:ok, data}
      {:error, _} = error -> error
      _ -> {:error, :mail_provider_unavailable}
    end
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, id)

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)
end
