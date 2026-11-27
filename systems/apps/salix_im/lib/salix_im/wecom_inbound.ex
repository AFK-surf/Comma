defmodule SalixIM.WeComInbound do
  @moduledoc """
  What a WeCom (企业微信) AI bot hears on its long connection
  (`SalixIM.WeComSocket`).

  Each frame is a JSON object: `cmd` names the kind, `headers.req_id` is the
  frame's ID, which a reply to it carries, and `body` holds the rest.

    * `aibot_msg_callback`: a person wrote to the bot in a private chat, or
      mentioned it in a group. `body.msgtype` is `text`, `image`, `mixed`
      (text and images), `voice` (WeCom's transcript of it), `file` or
      `video`. A group sends the bot only text and mixed messages that
      mention it. `quote` is the message the person quoted.
    * `aibot_event_callback`: a person opened the bot's private chat
      (`enter_chat`), tapped a card or rated an answer. Phase one sends no
      cards and keeps no ratings, so these are dropped.

  A message enters the Group's Router Conversation through
  `ProviderConnects.enqueue_group_router_im_provider_message/5`. WeCom can
  deliver one message more than once; the source ID
  `im_provider:wecom:<connect_id>:<msgid>` is stable across deliveries, and
  the Session owns permanent input deduplication.

  A message that carries `compat_info` did not come from a person in a chat:
  WeCom's own assistant called the bot, or a channel post reached it. Those
  need answers of another kind and are dropped.

  A chat is named `user:<userid>` or `group:<chatid>`. A `userid` is the
  person's account in the organization when the bot's creator is a super
  admin of it, and an ID WeCom made for this organization otherwise.
  """

  require Logger

  alias SalixIM.{ProviderConnects, ProviderRecipientIdentity, WeComFiles, WeComSocket}

  @max_attachments 4
  @working "正在处理…"
  @not_taken "这条消息没能交给处理流程，请稍后再发一次。"
  @context_chars 8_000

  @doc """
  Handles one frame of `connect`'s socket. Returns `:ok` when the frame was
  taken or dropped on purpose, and `{:error, reason}` when it could not be
  delivered.
  """
  @spec handle_frame(map(), map()) :: :ok | {:error, term()}
  def handle_frame(connect, %{"cmd" => "aibot_msg_callback", "body" => %{} = body} = frame) do
    req_id = text(get_in(frame, ["headers", "req_id"]))

    cond do
      is_map(body["compat_info"]) ->
        Logger.info("wecom_inbound_compat_dropped",
          connect_id: connect["connect_id"],
          source: text(body["compat_info"]["source"])
        )

        :ok

      true ->
        message(connect, body, req_id)
    end
  end

  def handle_frame(_connect, %{"cmd" => "aibot_event_callback"}), do: :ok
  def handle_frame(_connect, _frame), do: :ok

  defp message(connect, body, req_id) do
    message_id = text(body["msgid"])
    sender = text(get_in(body, ["from", "userid"]))

    {chat_id, chat_type} =
      case text(body["chattype"]) do
        "group" -> {"group:" <> text(body["chatid"]), "group"}
        _single -> {"user:" <> sender, "private"}
      end

    if message_id == "" or sender == "" or String.ends_with?(chat_id, ":") do
      Logger.warning("wecom_inbound_malformed", connect_id: connect["connect_id"])
      :ok
    else
      route(connect, body, req_id, message_id, chat_id, chat_type, sender)
    end
  end

  defp route(connect, body, req_id, message_id, chat_id, chat_type, sender) do
    sent_at_ms = sent_at_ms(body["create_time"])
    typed = typed_text(body)

    metadata =
      %{
        "provider" => "wecom",
        "connect_id" => connect["connect_id"],
        "chat_id" => chat_id,
        "chat_type" => chat_type,
        "message_id" => message_id,
        "from_user_id" => sender,
        "from_username" => sender,
        "event_type" =>
          if(chat_type == "group", do: "wecom.group_message", else: "wecom.message"),
        # The frame's req_id: a reply to this message carries it.
        "event_id" => req_id,
        "source_sent_at_ms" => sent_at_ms,
        "source_actor_type" => "provider_user"
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()
      |> ProviderRecipientIdentity.put(connect)

    # The working line goes out before the Router has the message, so no
    # answer can go out before it.
    stream = open_stream(connect, req_id, message_id)

    ProviderConnects.enqueue_group_router_im_provider_message(
      connect["group_id"],
      content(body, typed),
      metadata,
      "im_provider:wecom:#{connect["connect_id"]}:#{message_id}",
      trusted_source_text: typed,
      attachments: attachments(connect, body, message_id)
    )
    |> case do
      {:error, reason} when reason in [:duplicate, :already_delivered] ->
        :ok

      {:error, reason} ->
        # Nobody will answer this message: the working line says so.
        close_stream(connect, req_id, stream)

        if permanent?(reason) do
          Logger.warning("wecom_inbound_refused", reason: inspect(reason))
          :ok
        else
          Logger.warning("wecom_inbound_failed",
            connect_id: connect["connect_id"],
            reason: inspect(reason)
          )

          {:error, reason}
        end

      _admitted ->
        :ok
    end
  end

  defp close_stream(connect, req_id, :opened) do
    _ =
      WeComSocket.request(connect["connect_id"], "aibot_respond_msg", req_id, %{
        "msgtype" => "markdown",
        "markdown" => %{"content" => @not_taken}
      })

    :ok
  end

  defp close_stream(_connect, _req_id, _stream), do: :ok

  # The person sees at once that the message was taken: a stream reply with
  # a "working" line, which the answer later finishes in place
  # (`SalixIM.WeComSocket`). Best effort: the answer goes out either way.
  defp open_stream(_connect, "", _message_id), do: :none

  defp open_stream(connect, req_id, message_id) do
    body = WeComSocket.stream_frame("comma_" <> message_id, false, @working)

    case WeComSocket.request(connect["connect_id"], "aibot_respond_msg", req_id, body) do
      {:ok, %{"duplicate" => true}} ->
        :duplicate

      {:ok, _frame} ->
        :opened

      {:error, reason} ->
        Logger.info("wecom_stream_not_opened",
          connect_id: connect["connect_id"],
          reason: inspect(reason)
        )

        :none
    end
  end

  defp permanent?(reason) when reason in [:not_found, :duplicate, :already_delivered], do: true
  defp permanent?({:bad_request, _message}), do: true
  defp permanent?(_reason), do: false

  # What the person wrote: the text of a text or mixed message, or WeCom's
  # transcript of a voice message.
  defp typed_text(%{"msgtype" => "text"} = body),
    do: String.trim(text(get_in(body, ["text", "content"])))

  defp typed_text(%{"msgtype" => "voice"} = body),
    do: String.trim(text(get_in(body, ["voice", "content"])))

  defp typed_text(%{"msgtype" => "mixed"} = body) do
    body
    |> get_in(["mixed", "msg_item"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and &1["msgtype"] == "text"))
    |> Enum.map_join("\n", &text(get_in(&1, ["text", "content"])))
    |> String.trim()
  end

  defp typed_text(_body), do: ""

  defp content(body, typed) do
    main =
      case {body["msgtype"], typed} do
        {"voice", ""} -> "[WeCom voice message without a transcript]"
        {"voice", typed} -> "[WeCom voice message, as WeCom transcribed it]\n" <> typed
        {_type, ""} -> placeholder(body["msgtype"])
        {_type, typed} -> typed
      end

    [quote_line(body["quote"]), main]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp placeholder("image"), do: "[WeCom image]"
  defp placeholder("file"), do: "[WeCom file]"
  defp placeholder("video"), do: "[WeCom video]"
  defp placeholder("mixed"), do: "[WeCom images]"
  defp placeholder(_type), do: "[WeCom message without text]"

  # The message the person quoted is context, not part of the request.
  defp quote_line(%{} = quote) do
    quoted =
      case quote["msgtype"] do
        "text" -> text(get_in(quote, ["text", "content"]))
        "voice" -> text(get_in(quote, ["voice", "content"]))
        "mixed" -> typed_text(Map.put(quote, "msgtype", "mixed"))
        type -> placeholder(type)
      end
      |> String.slice(0, @context_chars)

    if quoted == "",
      do: nil,
      else:
        "[The message quoted in this one. It is context, not part of the request:\n#{quoted}\n]"
  end

  defp quote_line(_quote), do: nil

  defp attachments(connect, body, message_id) do
    body
    |> media()
    |> Enum.take(@max_attachments)
    |> Enum.with_index()
    |> Enum.map(fn {{kind, media}, index} ->
      digest =
        [connect["connect_id"], message_id, index]
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      {name, mime} = name_and_mime(kind, index)
      url = media["url"]
      aeskey = media["aeskey"]

      %{
        "path" => path(digest, name),
        "file_name" => name,
        "mime" => mime,
        # The download names the file and its type; the path takes the name.
        "to_blob" => fn agent_id ->
          with {:ok, resource} <-
                 WeComFiles.download(agent_id, url, aeskey, WeComFiles.max_bytes()) do
            case resource[:file_name] do
              nil -> {:ok, resource}
              file_name -> {:ok, Map.put(resource, :path, path(digest, file_name))}
            end
          end
        end
      }
    end)
  end

  defp media(%{"msgtype" => type} = body) when type in ["image", "file", "video"] do
    case body[type] do
      %{"url" => url, "aeskey" => key} = media when is_binary(url) and is_binary(key) ->
        [{type, media}]

      _other ->
        []
    end
  end

  defp media(%{"msgtype" => "mixed"} = body) do
    body
    |> get_in(["mixed", "msg_item"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"msgtype" => "image", "image" => %{"url" => url, "aeskey" => key} = media}
      when is_binary(url) and is_binary(key) ->
        [{"image", media}]

      _other ->
        []
    end)
  end

  defp media(_body), do: []

  defp path(digest, name) do
    safe =
      name
      |> Path.basename()
      |> String.replace(~r/[^\p{L}\p{N}._-]/u, "_")
      |> String.slice(0, 120)

    "/wecom/attachments/#{digest}-#{if safe == "", do: "attachment", else: safe}"
  end

  # The message names neither the file nor its type: these stand until the
  # download tells them (`SalixIM.WeComFiles`).
  defp name_and_mime("image", index), do: {"image-#{index + 1}.jpg", "application/octet-stream"}
  defp name_and_mime("video", index), do: {"video-#{index + 1}.mp4", "video/mp4"}
  defp name_and_mime(_file, index), do: {"file-#{index + 1}", "application/octet-stream"}

  defp sent_at_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000

  defp sent_at_ms(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {value, ""} when value > 0 -> value * 1_000
      _other -> nil
    end
  end

  defp sent_at_ms(_seconds), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""
end
