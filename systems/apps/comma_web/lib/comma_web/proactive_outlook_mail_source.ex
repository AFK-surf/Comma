defmodule CommaWeb.ProactiveOutlookMailSource do
  @moduledoc """
  Bounded full-message read through an owner-consented Outlook proxy. The
  conversation read must fit one page; a partial thread fails closed.

  Graph is asked for text bodies, and each message keeps only its `uniqueBody`
  (the part not quoted from earlier messages), so the size limits apply to the
  readable text rather than to Outlook's HTML or repeated reply history.
  """

  @graph "https://graph.microsoft.com/v1.0/me"
  @fields "id,conversationId,subject,from,toRecipients,ccRecipients,body,uniqueBody,receivedDateTime,sentDateTime,webLink,hasAttachments"
  @max_messages 20
  @max_text_bytes 8_000
  @max_thread_bytes 12_000
  @text_body %{
    "name" => "Prefer",
    "value" => ~s(outlook.body-content-type="text"),
    "type" => "header"
  }

  def read(settings, group, account, message_id) do
    if valid_id?(message_id) do
      with {:ok, session} <-
             client().create_proxy_session(settings, group, account, "outlook",
               error_mode: :structured
             ) do
        try do
          with {:ok, me} <- get(settings, session, @graph <> "?$select=id,mail,userPrincipalName"),
               true <- is_binary(me["id"]) and me["id"] != "",
               mailbox when is_binary(mailbox) and mailbox != "" <-
                 Enum.find([me["mail"], me["userPrincipalName"]], &(is_binary(&1) and &1 != "")),
               {:ok, message} <-
                 get(
                   settings,
                   session,
                   @graph <>
                     "/messages/" <>
                     URI.encode(message_id, &URI.char_unreserved?/1) <> "?$select=" <> @fields
                 ),
               true <- message["id"] == message_id and valid_id?(message["conversationId"]),
               {:ok, thread} <-
                 get(settings, session, conversation_url(message["conversationId"])),
               {:ok, result} <- normalize(message, thread, mailbox) do
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

  defp conversation_url(id) do
    @graph <>
      "/messages?" <>
      URI.encode_query(%{
        "$filter" => "conversationId eq '" <> String.replace(id, "'", "''") <> "'",
        "$top" => @max_messages + 1,
        "$select" => @fields
      })
  end

  def normalize(message, thread, mailbox) when is_map(message) and is_map(thread) do
    rows = thread["value"]
    id = message["conversationId"]

    with true <- valid_id?(id) and is_binary(mailbox) and mailbox != "",
         true <-
           is_list(rows) and length(rows) in 1..@max_messages and
             not Map.has_key?(thread, "@odata.nextLink"),
         true <- Enum.all?(rows, &(is_map(&1) and &1["conversationId"] == id)),
         true <- Enum.any?(rows, &(&1["id"] == message["id"])),
         {:ok, normalized} <- normalize_messages(rows),
         true <- byte_size(Jason.encode!(normalized)) <= @max_thread_bytes,
         url when is_binary(url) <- message["webLink"],
         true <- outlook_url?(url) do
      {:ok,
       %{
         "message_id" => message["id"],
         "thread_id" => id,
         "mailbox" => mailbox,
         "url" => url,
         "messages" => Enum.sort_by(normalized, & &1["sent_at_ms"]),
         "thread_complete" => true,
         "attachments_read" => false
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :mail_thread_incomplete_or_too_large}
    end
  end

  def normalize(_, _, _), do: {:error, :invalid_mail_response}

  defp normalize_messages(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case normalize_message(row) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_message(row) do
    body = unique_body(row)

    with true <- valid_id?(row["id"]),
         {:ok, text} <- body_text(body["content"], body["contentType"]),
         true <- text != "" and byte_size(text) <= @max_text_bytes,
         {:ok, at, _} <-
           DateTime.from_iso8601(row["sentDateTime"] || row["receivedDateTime"] || "") do
      {:ok,
       %{
         "message_id" => row["id"],
         "subject" => row["subject"] || "",
         "from" => get_in(row, ["from", "emailAddress", "address"]) || "",
         "to" => recipients(row["toRecipients"]),
         "cc" => recipients(row["ccRecipients"]),
         "body" => text,
         "labels" => [],
         "sent_at_ms" => DateTime.to_unix(at, :millisecond),
         "attachments" => if(row["hasAttachments"], do: ["unread attachments"], else: [])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :mail_body_unavailable_or_too_large}
    end
  end

  @doc "Graph parameter that asks for text bodies."
  def text_body, do: @text_body

  @doc "A message's own text: its `uniqueBody`, else its `body`."
  def message_text(row) when is_map(row) do
    body = unique_body(row)
    body_text(body["content"], body["contentType"])
  end

  @doc """
  A message's own body for its source quote: `{:mail, text}`, or
  `{:mail_html, html}` so HTML mail keeps its lines. `nil` without a body.
  """
  def quote_body(row) when is_map(row) do
    case unique_body(row) do
      %{"content" => content, "contentType" => type} when is_binary(content) ->
        cond do
          String.trim(content) == "" -> nil
          type == "html" -> {:mail_html, content}
          type == "text" -> {:mail, content}
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp unique_body(row) do
    case row["uniqueBody"] do
      %{"content" => content} = unique when is_binary(content) and content != "" -> unique
      _ -> row["body"] || %{}
    end
  end

  defp body_text(content, "text") when is_binary(content), do: {:ok, String.trim(content)}

  defp body_text(content, "html") when is_binary(content) do
    case Floki.parse_document(content) do
      {:ok, tree} ->
        {:ok, tree |> Floki.filter_out("script,style") |> Floki.text(sep: " ") |> String.trim()}

      _ ->
        {:error, :mail_body_unavailable_or_too_large}
    end
  end

  defp body_text(_, _), do: {:error, :mail_body_unavailable_or_too_large}

  defp recipients(rows) when is_list(rows),
    do: Enum.map_join(Enum.take(rows, 30), ", ", &(get_in(&1, ["emailAddress", "address"]) || ""))

  defp recipients(_), do: ""

  defp get(settings, session, endpoint) do
    case client().proxy_execute(
           settings,
           session,
           %{
             "toolkit_slug" => "outlook",
             "endpoint" => endpoint,
             "method" => "GET",
             "parameters" => [@text_body]
           },
           error_mode: :structured,
           max_response_bytes: 512_000
         ) do
      {:ok, %{"status" => 200, "data" => data}} when is_map(data) -> {:ok, data}
      {:error, _} = error -> error
      _ -> {:error, :mail_provider_unavailable}
    end
  end

  defp outlook_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} ->
        host in ~w(outlook.office.com outlook.office365.com outlook.live.com)

      _ ->
        false
    end
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..512 and Regex.match?(~r/^[A-Za-z0-9_+\/=-]+$/, id)

  defp client, do: SystemsRuntime.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)
end
