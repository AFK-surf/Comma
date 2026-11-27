defmodule SalixIM.Provider.WeCom do
  @moduledoc """
  Router operations on a WeCom (企业微信) AI bot (`wecom.*`).

  A chat is `user:<userid>` for a private chat with the bot or
  `group:<chatid>` for a group, as `SalixIM.WeComInbound` names it.
  `chat_id` defaults to the chat of the current WeCom source. The bot can
  address only chats that have written to it: WeCom sends a message to a
  person or a group only after they wrote to the bot.

  Every send goes out on the connect's long connection
  (`SalixIM.WeComSocket.request/5`), wherever in the cluster it is held.

  ## Replies and proactive messages

  An answer to the current message is a reply (`aibot_respond_msg` with the
  message's `req_id`): WeCom takes replies to a message for 24 hours. Any
  other send, and a reply WeCom refused, is a proactive message
  (`aibot_send_msg`). Both count against WeCom's limit of 30 messages a
  minute and 1000 an hour per chat.

  WeCom has no message edit. A file goes out as its own message after the
  text: the bot uploads it on the socket first (`aibot_upload_media_*`),
  in parts of 512 KiB.
  """

  import SalixIM.Provider.Util

  alias SalixIM.WeComSocket

  @ops ~w(wecom.send_message)

  @default_url "wss://openws.work.weixin.qq.com"
  @check_timeout_ms 10_000
  @max_text_bytes 20_000
  @reply_window_ms 23 * 3_600_000
  @chunk_bytes 512 * 1024
  @max_chunks 100
  @image_max_bytes 10 * 1024 * 1024
  @file_max_bytes 20 * 1024 * 1024
  @upload_timeout_ms 30_000

  @doc "The WeCom operation names."
  def operations, do: @ops

  def call(agent_id, connect, api, params) when is_map(connect) do
    params = if is_map(params), do: params, else: %{}

    with true <- api in @ops || {:error, "Unsupported WeCom operation"},
         :ok <- ensure_connected(connect) do
      operation(api, agent_id, connect, params)
    end
  end

  # ---- operations ----

  defp operation("wecom.send_message", agent_id, connect, params) do
    with {:ok, chat_id} <- chat_id(connect, params),
         {:ok, text} <- message_text(params),
         {:ok, upload} <- upload_source(agent_id, params["path"]),
         :ok <- ensure_content(text, upload) do
      text = file_caption(connect, chat_id, text, upload)

      with {:ok, sent} <- send_text(connect, chat_id, text),
           {:ok, sent} <- send_file(connect, chat_id, upload, sent) do
        {:ok,
         %{"chat_id" => chat_id, "delivery" => List.last(sent)}
         |> maybe_put("filename", upload && upload.filename)}
      end
    end
  end

  # ---- sending ----

  # A file-only answer to the current message still finishes its working
  # line (`SalixIM.WeComSocket`): a line that names the file goes first.
  defp file_caption(connect, chat_id, "", %{filename: filename}) do
    if reply_req_id(connect, chat_id), do: "文件：" <> filename, else: ""
  end

  defp file_caption(_connect, _chat_id, text, _upload), do: text

  defp send_text(_connect, _chat_id, ""), do: {:ok, []}

  defp send_text(connect, chat_id, text) do
    with {:ok, delivery} <-
           deliver(connect, chat_id, %{
             "msgtype" => "markdown",
             "markdown" => %{"content" => text}
           }) do
      {:ok, [delivery]}
    end
  end

  defp send_file(_connect, _chat_id, nil, sent), do: {:ok, sent}

  defp send_file(connect, chat_id, upload, sent) do
    type = media_type(upload)

    with {:ok, media_id} <- put_media(connect, upload, type),
         {:ok, delivery} <-
           deliver(connect, chat_id, %{"msgtype" => type, type => %{"media_id" => media_id}}) do
      {:ok, sent ++ [delivery]}
    end
  end

  # A reply while the current message still takes one, a proactive message
  # otherwise. When WeCom refuses the reply, the same body goes out once more
  # as a proactive message.
  defp deliver(connect, chat_id, body) do
    case reply_req_id(connect, chat_id) do
      nil ->
        proactive(connect, chat_id, body)

      req_id ->
        case WeComSocket.request(connect["connect_id"], "aibot_respond_msg", req_id, body) do
          {:ok, _frame} -> {:ok, "reply"}
          {:error, {:wecom, _code, _message}} -> proactive(connect, chat_id, body)
          {:error, reason} -> {:error, error_text(reason)}
        end
    end
  end

  defp proactive(connect, chat_id, body) do
    {chat_type, raw_id} = chat_parts(chat_id)

    request =
      body
      |> Map.put("chatid", raw_id)
      |> Map.put("chat_type", chat_type)

    case WeComSocket.request(connect["connect_id"], "aibot_send_msg", nil, request) do
      {:ok, _frame} -> {:ok, "proactive"}
      {:error, reason} -> {:error, error_text(reason)}
    end
  end

  # The req_id of the current message, when the send answers its chat and
  # the message is recent enough to take a reply.
  defp reply_req_id(connect, chat_id) do
    origin = origin(connect)
    context = origin["provider_context"] || %{}
    sent_at = origin["source_sent_at_ms"]

    if context["chat_id"] == chat_id and str(context["event_id"]) != "" and is_integer(sent_at) and
         SystemsClock.system_time(:millisecond) - sent_at < @reply_window_ms,
       do: str(context["event_id"])
  end

  # ---- files ----

  defp put_media(connect, upload, type) do
    connect_id = connect["connect_id"]
    chunks = div(upload.size + @chunk_bytes - 1, @chunk_bytes)

    with {:ok, frame} <-
           WeComSocket.request(
             connect_id,
             "aibot_upload_media_init",
             nil,
             %{
               "type" => type,
               "filename" => upload.filename,
               "total_size" => upload.size,
               "total_chunks" => chunks
             },
             timeout: @upload_timeout_ms
           ),
         upload_id when is_binary(upload_id) and upload_id != "" <-
           get_in(frame, ["body", "upload_id"]) || {:error, :no_upload_id},
         :ok <- put_chunks(connect_id, upload_id, upload.stream),
         {:ok, frame} <-
           WeComSocket.request(
             connect_id,
             "aibot_upload_media_finish",
             nil,
             %{"upload_id" => upload_id},
             timeout: @upload_timeout_ms
           ),
         media_id when is_binary(media_id) and media_id != "" <-
           get_in(frame, ["body", "media_id"]) || {:error, :no_media_id} do
      {:ok, media_id}
    else
      {:error, reason} -> {:error, "WeCom did not take the file: " <> error_text(reason)}
    end
  end

  defp put_chunks(connect_id, upload_id, stream) do
    stream
    |> rechunk(@chunk_bytes)
    |> Stream.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case WeComSocket.request(
             connect_id,
             "aibot_upload_media_chunk",
             nil,
             %{
               "upload_id" => upload_id,
               "chunk_index" => index,
               "base64_data" => Base.encode64(chunk)
             },
             timeout: @upload_timeout_ms
           ) do
        {:ok, _frame} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Parts of exactly `size` bytes, the last one shorter.
  defp rechunk(stream, size) do
    Stream.transform(
      stream,
      fn -> "" end,
      fn data, buffer ->
        buffer = buffer <> IO.iodata_to_binary(data)
        whole = div(byte_size(buffer), size) * size
        <<ready::binary-size(^whole), rest::binary>> = buffer
        {for(<<part::binary-size(^size) <- ready>>, do: part), rest}
      end,
      fn
        "" -> {[], ""}
        buffer -> {[buffer], ""}
      end,
      fn _buffer -> :ok end
    )
  end

  # WeCom shows png, jpg and gif inline; anything else is a file.
  defp media_type(upload) do
    ext = upload.filename |> Path.extname() |> String.downcase()

    if ext in [".png", ".jpg", ".jpeg", ".gif"] and upload.size <= @image_max_bytes,
      do: "image",
      else: "file"
  end

  defp upload_source(_agent_id, path) when path in [nil, ""], do: {:ok, nil}

  defp upload_source(agent_id, path) do
    case SalixIM.Ports.AgentWorkspace.read_stream(agent_id, str(path)) do
      {:ok, stream, size, filename} when is_integer(size) and is_binary(filename) ->
        cond do
          filename in ["", ".", "/"] ->
            {:error, "path must point to a file"}

          size == 0 ->
            {:error, "the file is empty"}

          size > @file_max_bytes or div(size + @chunk_bytes - 1, @chunk_bytes) > @max_chunks ->
            {:error,
             "The file is larger than #{@file_max_bytes} bytes, the limit for a file sent to WeCom"}

          true ->
            {:ok, %{stream: stream, size: size, filename: filename}}
        end

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _other ->
        {:error, "file not found in agent VFS: #{path}"}
    end
  end

  # ---- parameters ----

  defp chat_id(connect, params) do
    chat_id =
      case str(params["chat_id"]) do
        "" -> str((origin(connect)["provider_context"] || %{})["chat_id"])
        chat_id -> chat_id
      end

    cond do
      chat_id == "" ->
        {:error, "chat_id is required outside a WeCom source"}

      not Regex.match?(~r/\A(user|group):[^\s]{1,256}\z/u, chat_id) ->
        {:error, "chat_id must be user:<userid> or group:<chatid>"}

      true ->
        {:ok, chat_id}
    end
  end

  defp chat_parts("user:" <> userid), do: {1, userid}
  defp chat_parts("group:" <> chatid), do: {2, chatid}

  defp origin(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "wecom", "provider_context" => %{} = context} = origin ->
        if context["connect_id"] == connect["connect_id"], do: origin, else: %{}

      _other ->
        %{}
    end
  end

  defp message_text(params) do
    text = params["text"] |> to_string_safe() |> String.trim()

    if byte_size(text) > @max_text_bytes,
      do: {:error, "text is longer than #{@max_text_bytes} bytes; send it in parts"},
      else: {:ok, text}
  end

  defp ensure_content("", nil), do: {:error, "text or path is required"}
  defp ensure_content(_text, _upload), do: :ok

  # ---- errors ----

  @doc "A sentence for an error of a WeCom request."
  def error_text({:wecom, code, message}), do: "WeCom error #{code}: #{message}"

  def error_text(:not_connected),
    do:
      "the bot's connection to WeCom is not open; it opens again by itself, so try again in a minute"

  def error_text(:timeout), do: "WeCom did not answer in time"

  def error_text(:too_many_requests),
    do: "too many messages are waiting to go out; try again later"

  def error_text(reason) when is_binary(reason), do: reason
  def error_text(reason), do: inspect(reason)

  # ---- credential check ----

  @doc """
  Checks a Bot ID and Secret by subscribing once on a new socket, then closes
  it. `:ok`, `{:error, {:wecom, errcode, errmsg}}` when WeCom refused them, or
  another error when WeCom could not be reached.
  """
  @spec check_credentials(String.t(), String.t()) :: :ok | {:error, term()}
  def check_credentials(bot_id, secret) when is_binary(bot_id) and is_binary(secret) do
    # Its own process: the socket's messages are the only ones in its mailbox.
    task = SystemsRuntime.Task.async(fn -> check(bot_id, secret) end)

    case SystemsClock.yield(task, @check_timeout_ms + 2_000) ||
           SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _other -> {:error, {:unreachable, :timeout}}
    end
  end

  defp check(bot_id, secret) do
    url = SystemsRuntime.get_env(:salix_im, :wecom_socket_url, @default_url)
    %URI{scheme: scheme, host: host, port: port} = uri = URI.parse(url)
    req_id = WeComSocket.new_req_id("aibot_subscribe")
    deadline = SystemsClock.monotonic_time(:millisecond) + @check_timeout_ms

    with {:ok, conn} <-
           Mint.HTTP.connect(if(scheme == "ws", do: :http, else: :https), host, port,
             protocols: [:http1],
             # WeCom answers 404 to an upgrade whose `Sec-WebSocket-Key`
             # header name is lowercased, as Mint sends it by default.
             case_sensitive_headers: true,
             transport_opts: [timeout: @check_timeout_ms]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(
             if(scheme == "ws", do: :ws, else: :wss),
             conn,
             uri.path || "/",
             []
           ) do
      try do
        with {:ok, conn, ws} <- await_upgrade(conn, ref, %{status: nil, headers: []}, deadline),
             {:ok, conn, ws} <-
               send_text_frame(conn, ref, ws, %{
                 "cmd" => "aibot_subscribe",
                 "headers" => %{"req_id" => req_id},
                 "body" => %{"bot_id" => bot_id, "secret" => secret}
               }) do
          await_answer(conn, ref, ws, req_id, deadline)
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, _conn, reason} -> {:error, {:unreachable, reason}}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  defp await_upgrade(conn, ref, upgrade, deadline) do
    with {:ok, conn, responses} <- next(conn, deadline) do
      upgrade =
        Enum.reduce(responses, upgrade, fn
          {:status, ^ref, status}, acc -> %{acc | status: status}
          {:headers, ^ref, headers}, acc -> %{acc | headers: acc.headers ++ headers}
          {:done, ^ref}, acc -> Map.put(acc, :done, true)
          _other, acc -> acc
        end)

      if upgrade[:done] do
        case Mint.WebSocket.new(conn, ref, upgrade.status, upgrade.headers) do
          {:ok, conn, ws} -> {:ok, conn, ws}
          {:error, _conn, reason} -> {:error, {:unreachable, reason}}
        end
      else
        await_upgrade(conn, ref, upgrade, deadline)
      end
    end
  end

  @doc false
  # Public for the split-frame regression test, which feeds it the socket's
  # reads one at a time.
  def await_answer(conn, ref, ws, req_id, deadline) do
    with {:ok, conn, responses} <- next(conn, deadline) do
      # The decoder keeps a frame split across reads in its state: carry it.
      {ws, frames} =
        Enum.reduce(responses, {ws, []}, fn
          {:data, ^ref, data}, {ws, frames} ->
            case Mint.WebSocket.decode(ws, data) do
              {:ok, ws, more} -> {ws, frames ++ more}
              {:error, ws, _reason} -> {ws, frames}
            end

          _other, acc ->
            acc
        end)

      answer =
        Enum.find_value(frames, fn
          {:text, text} ->
            case Jason.decode(text) do
              {:ok, %{"headers" => %{"req_id" => ^req_id}, "errcode" => 0}} ->
                :ok

              {:ok, %{"headers" => %{"req_id" => ^req_id}} = frame} ->
                {:error, {:wecom, frame["errcode"], to_string(frame["errmsg"])}}

              _other ->
                nil
            end

          {:close, code, _reason} ->
            {:error, {:unreachable, {:closed, code}}}

          _other ->
            nil
        end)

      answer || await_answer(conn, ref, ws, req_id, deadline)
    end
  end

  # The next responses of a connection this process owns, until `deadline`.
  defp next(conn, deadline) do
    left = deadline - SystemsClock.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, {:unreachable, :timeout}}
    else
      receive do
        message ->
          case Mint.WebSocket.stream(conn, message) do
            {:ok, conn, responses} -> {:ok, conn, responses}
            {:error, _conn, reason, _responses} -> {:error, {:unreachable, reason}}
            :unknown -> next(conn, deadline)
          end
      after
        SystemsClock.timeout(left) -> {:error, {:unreachable, :timeout}}
      end
    end
  end

  defp send_text_frame(conn, ref, ws, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, {:text, Jason.encode!(frame)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn, ws}
    else
      {:error, _conn_or_ws, reason} -> {:error, {:unreachable, reason}}
    end
  end
end
