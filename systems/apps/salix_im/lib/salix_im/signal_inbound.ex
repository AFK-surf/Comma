defmodule SalixIM.SignalInbound do
  @moduledoc """
  Signal ingress (`docs/messaging-voice.md`): one received Signal message,
  already decrypted, committed and normalized by the account runtime, enters
  the bound Group's Router Conversation through
  `ProviderConnects.enqueue_group_router_im_provider_message/5`.

  A claim command (`comma connect ABCD-EFGH`) binds its chat instead of
  reaching a Router. A message from a chat that no connect binds is dropped
  without a reply, so an unbound sender cannot make the account send
  messages.

  Delivery from the account runtime is at least once. The source ID
  `im_provider:signal:<connect_id>:<sender>:<timestamp>` is stable across
  replays, and the Session owns permanent input deduplication.

  ## Event

  `deliver/1` takes a map with string keys: `account_id`, `sender` (ACI),
  `display_name`, `timestamp` (the sender's message timestamp),
  `server_timestamp`, `guid`, `chat` (`%{"kind" => "user" | "group", "peer"
  => id}`), `type` (`message`, `reaction`, `edit` or `delete`), `text`,
  `quote` (`%{"timestamp", "author", "text"}`), `attachments` (maps with
  `file_name`, `content_type`, `size`, `voice_note` and a `to_blob` function
  of the Router agent ID), `reaction` (`%{"emoji", "remove", "target_author",
  "target_timestamp"}`) and `target_timestamp` (edit and delete).
  """

  require Logger

  alias SalixIM.{ProviderConnects, ProviderRecipientIdentity, SignalConnects}
  alias SalixIM.Ports.SignalAccount

  @max_attachments 4
  @quote_chars 500

  @doc """
  Delivers one normalized Signal event. Returns `:ok` when the event is
  admitted, answered or deliberately dropped, and `{:error, reason}` when
  delivery should be retried.
  """
  @spec deliver(map()) :: :ok | {:error, term()}
  def deliver(%{"account_id" => account_id, "chat" => %{"peer" => peer} = chat} = event)
      when is_binary(account_id) and is_binary(peer) do
    case claim_command(event) do
      {:ok, code} -> redeem(event, chat, code)
      {:error, :invalid_claim} -> claim_failed(event, chat)
      :error -> route(event, account_id, peer)
    end
  end

  def deliver(_event), do: :ok

  # ---- claims ----

  defp claim_command(%{"type" => "message", "text" => text}) when is_binary(text),
    do: SignalConnects.parse_command(text)

  defp claim_command(_event), do: :error

  defp redeem(event, chat, code) do
    peer = %{
      "kind" => chat["kind"],
      "peer" => chat["peer"],
      "display_name" =>
        if(chat["kind"] == "group", do: chat["title"], else: event["display_name"])
    }

    case SignalConnects.redeem_claim(event["account_id"], code, peer) do
      {:ok, _bound} ->
        reply(event, "Signal is connected to Comma. Send a message here to get started.")

      {:error, :signal_peer_in_use} ->
        reply(
          event,
          "This Signal chat is already connected to another Comma group. Disconnect it there first."
        )

      {:error, :invalid_claim} ->
        claim_failed(event, chat)

      {:error, _reason} = error ->
        error
    end
  end

  # A replayed claim command finds its claim used. When the chat is bound,
  # stay quiet rather than contradict the first answer.
  defp claim_failed(event, chat) do
    case SignalConnects.find_signal_connect(event["account_id"], chat["peer"]) do
      {:ok, _connect} ->
        :ok

      _ ->
        reply(
          event,
          "Could not connect Signal. Create a new connection code in Comma Settings and send it here within 10 minutes."
        )
    end
  end

  # The account runtime calls `deliver/1` from the account's delivery
  # process, not its owner process, so the reply is sent here. The binding
  # outcome is committed first; a lost confirmation is logged, not retried.
  defp reply(event, text) do
    case SignalAccount.send_text(event["account_id"], event["chat"]["peer"], text, []) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("signal_claim_reply_failed", reason: inspect(reason))
    end

    :ok
  end

  # ---- routing ----

  defp route(event, account_id, peer) do
    case SignalConnects.find_signal_connect(account_id, peer) do
      {:ok, connect} -> enqueue(connect, event)
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp enqueue(connect, event) do
    chat = event["chat"]
    timestamp = integer(event["timestamp"])
    sender = to_string(event["sender"])

    metadata =
      ProviderRecipientIdentity.put(
        %{
          "provider" => "signal",
          "connect_id" => connect["connect_id"],
          "chat_id" => chat["peer"],
          "chat_type" => if(chat["kind"] == "group", do: "group", else: "private"),
          "chat_title" => if(chat["kind"] == "group", do: connect["binding"]["display_name"]),
          "message_id" => Integer.to_string(timestamp),
          "from_user_id" => sender,
          "from_username" => event["display_name"] || sender,
          "event_type" => "signal." <> to_string(event["type"] || "message"),
          "event_id" => event["guid"],
          "signal_account_id" => event["account_id"],
          "source_sent_at_ms" => timestamp,
          "source_actor_type" => "provider_user"
        }
        |> reject_nil(),
        connect
      )

    text = if is_binary(event["text"]), do: event["text"], else: ""

    ProviderConnects.enqueue_group_router_im_provider_message(
      connect["group_id"],
      content(event, text),
      metadata,
      "im_provider:signal:#{connect["connect_id"]}:#{sender}:#{timestamp}",
      trusted_source_text: if(event["type"] in ["message", "edit"], do: text, else: ""),
      attachments: attachments(event)
    )
    |> case do
      {:error, reason} = error ->
        if permanent?(reason) do
          # One misconfigured Group must not stop the account's delivery to
          # every other Group: a permanent refusal drops this message.
          Logger.warning("signal_inbound_refused", reason: inspect(reason))
          :ok
        else
          error
        end

      # Admitted, or answered as a product command.
      _admitted ->
        :ok
    end
  end

  defp permanent?(reason)
       when reason in [:not_found, :router_not_configured, :duplicate, :already_delivered],
       do: true

  defp permanent?({:bad_request, _message}), do: true

  defp permanent?(reason) when is_atom(reason),
    do: String.starts_with?(to_string(reason), "invalid")

  defp permanent?(_reason), do: false

  defp content(%{"type" => "reaction", "reaction" => %{} = reaction}, _text) do
    verb = if reaction["remove"] == true, do: "removed the reaction", else: "reacted"

    "[Signal: #{verb} #{reaction["emoji"]} on message #{reaction["target_timestamp"]} by #{reaction["target_author"]}]"
  end

  defp content(%{"type" => "edit"} = event, text),
    do: "[Signal: edited message #{event["target_timestamp"]}]\n" <> text

  defp content(%{"type" => "delete"} = event, _text),
    do: "[Signal: the sender deleted message #{event["target_timestamp"]}]"

  defp content(event, text) do
    body =
      cond do
        text != "" -> text
        Enum.any?(List.wrap(event["attachments"]), &(&1["voice_note"] == true)) -> ""
        List.wrap(event["attachments"]) != [] -> "[Signal attachment]"
        true -> "[Signal message without text]"
      end

    notes =
      for attachment <- List.wrap(event["attachments"]), attachment["voice_note"] == true do
        "[Signal voice note: transcribe the attached audio with audio.transcribe]"
      end

    [quote_line(event["quote"]), body | notes]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # Quoted text is context, not a new instruction.
  defp quote_line(%{"timestamp" => timestamp} = quoted_message) do
    quoted = quoted_message["text"] |> to_string() |> String.slice(0, @quote_chars)
    "[Quoting message #{timestamp} by #{quoted_message["author"]}: #{quoted}]"
  end

  defp quote_line(_quoted_message), do: nil

  defp attachments(event) do
    event
    |> Map.get("attachments", [])
    |> List.wrap()
    |> Enum.filter(&is_function(&1["to_blob"], 1))
    |> Enum.take(@max_attachments)
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} ->
      name =
        attachment["file_name"]
        |> to_string()
        |> Path.basename()
        |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
        |> String.slice(0, 120)
        |> case do
          "" -> if attachment["voice_note"] == true, do: "voice-note", else: "attachment"
          name -> name
        end

      locator = "#{event["account_id"]}-#{event["sender"]}-#{event["timestamp"]}-#{index}"

      %{
        "path" => "/signal/attachments/#{locator}-#{name}",
        "file_name" => name,
        "mime" => attachment["content_type"],
        "size" => attachment["size"],
        "to_blob" => attachment["to_blob"]
      }
    end)
  end

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0
end
