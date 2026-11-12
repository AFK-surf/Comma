defmodule SalixIM.LineInbound do
  @moduledoc """
  LINE Messaging API webhook events for a Comma product LINE connect.

  Comma owns one LINE Official Account. LINE posts
  `{"destination": <bot userId>, "events": [...]}` to Comma and signs the raw
  body: `X-Line-Signature` is the Base64 HMAC-SHA256 of the body under the
  channel secret (`verify_signature/3`). Comma checks it once per request,
  finds the connect of each event's sender, and hands the event here.

  A connect serves one LINE user (`managed_peer_id`). A `message` event from
  that user's private chat enters the Group's Router Conversation through
  `ProviderConnects.enqueue_group_router_im_provider_message/5`, and so does a
  message of that user in a group or multi-person chat that mentions the
  account. Every other event is dropped, as is an event in `standby` mode
  (another channel holds the chat).

  LINE can deliver one event more than once. The source ID
  `im_provider:line:<connect_id>:<message_id>` is stable across deliveries,
  and the Session owns permanent input deduplication.

  A chat is named `user:<userId>`, `group:<groupId>` or `room:<roomId>`
  (`SalixIM.Provider.Line.chat_id/1`). LINE issues these IDs per channel.
  """

  require Logger

  alias SalixIM.{LineFiles, ProviderConnects, ProviderObservations, ProviderRecipientIdentity}
  alias SalixIM.Provider.Line

  @max_attachments 4
  @file_types ~w(image video audio file)

  @doc "Whether `X-Line-Signature` in `headers` signs `raw_body` under `secret`."
  @spec verify_signature(String.t(), [{String.t(), String.t()}], binary()) ::
          :ok | {:error, :invalid_signature}
  def verify_signature(secret, headers, raw_body) when is_binary(raw_body) do
    secret = to_string(secret)
    signature = header(headers, "x-line-signature")

    expected =
      :hmac
      |> :crypto.mac(:sha256, secret, raw_body)
      |> Base.encode64()

    if secret != "" and signature != "" and Plug.Crypto.secure_compare(expected, signature),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  def verify_signature(_secret, _headers, _raw_body), do: {:error, :invalid_signature}

  @doc """
  Handles one event of a verified request for an active `connect`. Returns
  `:ok`, or a delivery error that LINE should redeliver.
  """
  @spec handle_event(map(), map()) :: :ok | {:error, term()}
  def handle_event(connect, event) when is_map(connect) and is_map(event),
    do: dispatch(connect, event)

  def handle_event(_connect, _event), do: :ok

  defp header(headers, name) do
    Enum.find_value(List.wrap(headers), "", fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: String.trim(value)

      _other ->
        nil
    end)
  end

  # ---- events ----

  defp dispatch(_connect, %{"mode" => "standby"}), do: :ok

  defp dispatch(connect, %{"type" => "message", "message" => %{} = message} = event) do
    source = if is_map(event["source"]), do: event["source"], else: %{}
    chat_id = Line.chat_id(source)
    sender = text(source["userId"])
    message_id = text(message["id"])

    cond do
      chat_id == "" or message_id == "" or sender == "" or
          sender != text(connect["managed_peer_id"]) ->
        :ok

      source["type"] == "user" ->
        route(connect, event, message, chat_id, "private", sender)

      mentions_bot?(message) ->
        route(connect, event, message, chat_id, text(source["type"]), sender)

      true ->
        :ok
    end
  end

  defp dispatch(_connect, _event), do: :ok

  defp mentions_bot?(message) do
    message
    |> get_in(["mention", "mentionees"])
    |> List.wrap()
    |> Enum.any?(&(is_map(&1) and &1["isSelf"] == true))
  end

  defp route(connect, event, message, chat_id, chat_type, sender) do
    message_id = text(message["id"])
    sent_at_ms = if is_integer(event["timestamp"]), do: event["timestamp"]
    body = message |> body() |> String.trim()

    observe(connect, %{
      "chat_id" => chat_id,
      "chat_type" => chat_type,
      "sender_id" => sender,
      "message_id" => message_id,
      "message_at" => sent_at_ms,
      "reply_token" => text(event["replyToken"])
    })

    metadata =
      %{
        "provider" => "line",
        "connect_id" => connect["connect_id"],
        "chat_id" => chat_id,
        "chat_type" => chat_type,
        "message_id" => message_id,
        "from_user_id" => sender,
        "from_username" => sender,
        "event_type" => if(chat_type == "private", do: "line.message", else: "line.group_message"),
        "event_id" => text(event["webhookEventId"]),
        "source_sent_at_ms" => sent_at_ms,
        "source_actor_type" => "provider_user"
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()
      |> ProviderRecipientIdentity.put(connect)

    ProviderConnects.enqueue_group_router_im_provider_message(
      connect["group_id"],
      if(body == "", do: "[LINE message without text]", else: body),
      metadata,
      "im_provider:line:#{connect["connect_id"]}:#{message_id}",
      trusted_source_text: body,
      attachments: attachments(connect, message)
    )
    |> case do
      {:error, reason} = error ->
        if permanent?(reason) do
          Logger.warning("line_inbound_refused", reason: inspect(reason))
          :ok
        else
          error
        end

      _admitted ->
        :ok
    end
  end

  # The token answers this message for free (`SalixIM.Provider.Line`). A
  # failed write costs that, and the answer then goes out as a push message.
  defp observe(connect, attrs) do
    case ProviderObservations.upsert_line_chat(connect, attrs) do
      :ok -> :ok
      other -> Logger.warning("line_chat_observation_failed", reason: inspect(other))
    end
  end

  defp body(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp body(%{"type" => "sticker"}), do: "[LINE sticker]"

  defp body(%{"type" => "location"} = message) do
    place =
      [message["title"], message["address"]]
      |> Enum.map(&text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    "[LINE location: #{place} (#{message["latitude"]}, #{message["longitude"]})]"
  end

  defp body(%{"type" => type}) when type in @file_types, do: "[LINE #{type}]"
  defp body(_message), do: ""

  # LINE keeps a file a person sent on its own servers; `contentProvider.type`
  # "external" means it is at the sender's URL instead, which is not fetched.
  defp attachments(connect, %{"type" => type, "id" => id} = message)
       when type in @file_types and is_binary(id) do
    if get_in(message, ["contentProvider", "type"]) in [nil, "line"] do
      name = file_name(message)

      digest =
        [connect["connect_id"], id]
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      Enum.take(
        [
          %{
            "path" => "/line/attachments/#{digest}-#{name}",
            "file_name" => name,
            "mime" => mime(type, name),
            "size" => message["fileSize"],
            "to_blob" => fn agent_id ->
              LineFiles.download(agent_id, connect, id, LineFiles.max_bytes())
            end
          }
        ],
        @max_attachments
      )
    else
      []
    end
  end

  defp attachments(_connect, _message), do: []

  defp file_name(%{"type" => "file", "fileName" => name}) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "file"
      name -> name
    end
  end

  defp file_name(%{"type" => "image", "id" => id}), do: "image-#{id}.jpg"
  defp file_name(%{"type" => "video", "id" => id}), do: "video-#{id}.mp4"
  defp file_name(%{"type" => "audio", "id" => id}), do: "audio-#{id}.m4a"
  defp file_name(_message), do: "file"

  defp mime("image", _name), do: "image/jpeg"
  defp mime("video", _name), do: "video/mp4"
  defp mime("audio", _name), do: "audio/mp4"
  defp mime(_type, name), do: MIME.from_path(name)

  defp permanent?(reason) when reason in [:not_found, :duplicate, :already_delivered], do: true
  defp permanent?({:bad_request, _message}), do: true
  defp permanent?(_reason), do: false

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""
end
