defmodule SalixIM.Provider.QQ do
  @moduledoc """
  Router operations on a QQ bot (`qq.*`).

  A chat is `group:<group_openid>` or `c2c:<user_openid>`, as the inbound
  source names it. `chat_id` defaults to the chat of the current QQ source.
  The bot can address only chats that have written to it: QQ issues the
  OpenIDs, and there is no other way to learn one.

  ## Replies and proactive messages

  QQ accepts a reply to a received message for a short time: 5 minutes and 5
  replies in a group, 60 minutes and 4 replies in a private chat. A send inside
  that allowance is a reply. Any other send is a proactive message. A private
  chat takes those unless the person turned them off. A group takes them only
  after a group admin allowed the bot to speak on its own there, so a late answer to
  a group can fail; the error says so.

  QQ has no message edit. A sent message cannot change. The bot can take a
  message back for 2 minutes after it was sent (`qq.delete_message`), and a
  private chat takes one message that grows while the bot writes it
  (`qq.stream_message`).

  ## Quotes

  QQ names a message it can quote by an index of its own, not by the message
  ID. `SalixIM.QQInbound` and each send keep the index beside the message ID,
  so `quote_message_id` takes the ID the bot already knows.

  ## Buttons

  A link button opens an address. A callback button sends its `data` back as
  an `INTERACTION_CREATE` event, which `SalixIM.QQInbound` gives to the Router
  as a message from the person who tapped it. A command button puts its `data`
  in the person's input box.

  The group operations are in `SalixIM.Provider.QQ.Groups`.
  """

  import SalixIM.Provider.Util

  alias SalixIM.Provider.QQ.{API, Groups}
  alias SalixIM.{ProviderObservations, QQMessageRecord, QQTiming}

  @ops ~w(qq.send_message qq.list_chats qq.search_messages qq.fetch_file qq.delete_message
          qq.stream_message qq.get_menu qq.set_menu qq.create_share_link) ++
         Groups.operations()
  @group_ops Groups.operations()

  # The reply allowance, kept inside QQ's own limits so that a send that starts
  # near the edge does not arrive after it.
  @group_reply_window_ms 270_000
  @group_reply_max 5
  @private_reply_window_ms 3_300_000
  @private_reply_max 4

  @max_text_bytes 12_000
  # QQ takes a file in one request up to 5 MB, and a larger one in parts.
  @one_request_file_bytes 5 * 1024 * 1024
  # Default ceiling for a file to send: the largest file QQ takes. Override
  # via :salix_im, :qq_upload_max_bytes.
  @default_max_file_bytes 200 * 1024 * 1024
  # QQ also asks for the MD5 of a file's first 10002432 bytes.
  @md5_head_bytes 10_002_432
  @max_buttons 5
  @max_button_label_chars 10
  @max_button_data_bytes 256
  @max_confirm_chars 40
  @max_menu_items 10
  @max_submenu_items 5
  @max_share_data_chars 32
  # A group bubble is narrow: a third button in one row cuts a four-character
  # label down to one.
  @buttons_per_row 2

  # QQ error codes that change what the sender should do next.
  @reply_window_closed 40_034_128
  @reply_message_expired 40_034_005
  @proactive_refused 40_034_105
  @recall_too_late 40_064_004

  @doc "The QQ operation names."
  def operations, do: @ops

  def call(agent_id, connect, api, params) when is_map(connect) do
    params = if is_map(params), do: params, else: %{}

    with true <- api in @ops || {:error, "Unsupported QQ operation"},
         :ok <- ensure_connected(connect) do
      operation(api, agent_id, connect, params)
    end
  end

  # ---- operations ----

  defp operation(api, _agent_id, connect, params) when api in @group_ops,
    do: Groups.call(api, connect, params, origin_context(connect))

  defp operation("qq.send_message", agent_id, connect, params) do
    with {:ok, chat_id} <- chat_id(connect, params),
         {:ok, text} <- message_text(params),
         {:ok, keyboard} <- keyboard(params["buttons"]),
         {:ok, upload} <-
           QQTiming.measure("upload_prepare", fn -> upload(agent_id, params["path"]) end),
         :ok <- ensure_content(text, upload),
         {:ok, extra} <-
           QQTiming.measure("quote_lookup", fn -> send_extra(connect, chat_id, params) end) do
      plain? = str(params["format"]) == "text"

      with {:ok, sent} <- send_text(connect, chat_id, text, plain?, keyboard, extra),
           {:ok, sent} <- send_file(connect, chat_id, upload, sent, extra) do
        message_ids = Enum.map(sent, & &1.message_id)

        {:ok,
         %{
           "chat_id" => chat_id,
           "message_id" => List.last(message_ids),
           "message_ids" => message_ids,
           "delivery" => sent |> List.last() |> Map.fetch!(:delivery)
         }
         |> maybe_put("filename", upload && upload.filename)}
      end
    end
  end

  defp operation("qq.list_chats", _agent_id, connect, params) do
    with {:ok, chats} <-
           ProviderObservations.list_qq_chats(
             connect["connect_id"],
             str(params["query"]),
             params["limit"]
           ) do
      {:ok,
       %{
         "chats" =>
           Enum.map(chats, fn chat ->
             %{
               "chat_id" => chat["chat_id"],
               "chat_type" => chat["chat_type"],
               "name" => chat["name"],
               "last_sender_name" => chat["last_sender_name"],
               "last_message_at" => chat["last_message_at"],
               "proactive" => chat["proactive"],
               # A group the bot left, or a person who removed the bot.
               "gone" => if(chat["present"] == false, do: true),
               "added_by" => chat["added_by"],
               "added_from" => chat["added_from"]
             }
             |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
             |> Map.new()
           end)
       }}
    end
  end

  defp operation("qq.search_messages", _agent_id, connect, params),
    do: SalixIM.Provider.QQ.MessageSearch.search(connect, params, origin_context(connect))

  defp operation("qq.fetch_file", agent_id, connect, params),
    do:
      SalixIM.Provider.QQ.MessageSearch.fetch_file(
        agent_id,
        connect,
        params,
        origin_context(connect)
      )

  defp operation("qq.delete_message", _agent_id, connect, params) do
    message_id = str(params["message_id"])

    with {:ok, chat_id} <- chat_id(connect, params),
         true <-
           Regex.match?(~r/\A[A-Za-z0-9._=+\/-]{1,256}\z/, message_id) ||
             {:error, "message_id is required"},
         # QQ lets an admin bot take back a member's message too. That is a
         # group admin's act, and the bot does not do those.
         true <-
           ProviderObservations.qq_sent_message?(connect["connect_id"], chat_id, message_id) ||
             {:error, "the bot can take back only a message it sent to this chat lately"} do
      path = chat_path(chat_id) <> "/messages/" <> URI.encode(message_id, &URI.char_unreserved?/1)

      case API.request(connect, :delete, path) do
        {:ok, _body} ->
          {:ok, %{"chat_id" => chat_id, "message_id" => message_id, "deleted" => true}}

        {:error, {:qq_api, _status, @recall_too_late, _message}} ->
          {:error, "QQ takes a message back only for 2 minutes after it was sent"}

        error ->
          error_text(error, chat_id)
      end
    end
  end

  defp operation("qq.stream_message", _agent_id, connect, params),
    do: stream_message(connect, params)

  defp operation("qq.get_menu", _agent_id, connect, _params) do
    with {:ok, body} <- connect |> API.request(:get, "/v2/menu") |> error_text("") do
      items = if is_map(body["menu"]), do: List.wrap(body["menu"]["items"]), else: []
      {:ok, %{"items" => items}}
    end
  end

  defp operation("qq.set_menu", _agent_id, connect, params) do
    with {:ok, items} <- menu_items(params["items"]),
         {:ok, _body} <-
           connect
           |> API.request(:put, "/v2/menu", json: %{"menu" => %{"items" => items}})
           |> error_text("") do
      {:ok, %{"items" => items}}
    end
  end

  defp operation("qq.create_share_link", _agent_id, connect, params) do
    data = str(params["data"])

    with true <-
           Regex.match?(~r/\A[A-Za-z0-9_.:-]{0,#{@max_share_data_chars}}\z/, data) ||
             {:error,
              "data takes at most #{@max_share_data_chars} letters, digits and the characters _ . : -"},
         {:ok, body} <-
           connect
           |> API.request(:post, "/v2/generate_url_link",
             json: maybe_put(%{}, "callback_data", data)
           )
           |> error_text("") do
      case get_in(body, ["data", "url"]) || body["url"] do
        url when is_binary(url) and url != "" -> {:ok, maybe_put(%{"url" => url}, "data", data)}
        _missing -> {:error, "QQ returned no link"}
      end
    end
  end

  # ---- sending ----

  defp send_text(_connect, _chat_id, "", _plain?, _keyboard, _extra), do: {:ok, []}

  defp send_text(connect, chat_id, text, plain?, keyboard, extra) do
    body =
      if plain?,
        do: %{"msg_type" => 0, "content" => text},
        else: %{"msg_type" => 2, "markdown" => %{"content" => text}}

    # QQ attaches buttons only to a Markdown message.
    keyboard = if plain?, do: nil, else: keyboard

    with {:ok, sent} <-
           deliver(connect, chat_id, body |> maybe_put("keyboard", keyboard) |> Map.merge(extra)) do
      observe_sent(connect, chat_id, sent.body, text, 0)
      {:ok, [sent]}
    end
  end

  defp send_file(_connect, _chat_id, nil, sent, _extra), do: {:ok, sent}

  defp send_file(connect, chat_id, upload, sent, extra) do
    # The text carries the quote and is the wakeup message; a file alone is.
    extra = if sent == [], do: extra, else: %{}

    with {:ok, %{"file_info" => file_info}} when is_binary(file_info) <-
           connect |> put_file(chat_id, upload) |> error_text(chat_id),
         {:ok, file} <-
           deliver(
             connect,
             chat_id,
             Map.merge(%{"msg_type" => 7, "media" => %{"file_info" => file_info}}, extra)
           ) do
      observe_sent(connect, chat_id, file.body, "[file: #{upload.filename}]", 1)
      {:ok, sent ++ [file]}
    else
      {:ok, _body} -> {:error, "QQ did not accept the file"}
      {:error, _reason} = error -> error
    end
  end

  # The file comes from the workspace as a stream, so only one part of a large
  # file is in memory at a time.
  defp put_file(connect, chat_id, upload) do
    if upload.size <= @one_request_file_bytes,
      do: put_whole(connect, chat_id, upload),
      else: put_in_parts(connect, chat_id, upload)
  rescue
    # The stream raises when the store cannot serve a range.
    _error -> {:error, "the file could not be read from the workspace; try again"}
  end

  defp put_whole(connect, chat_id, upload) do
    data = upload.stream |> Enum.to_list() |> IO.iodata_to_binary()
    files(connect, chat_id, upload, %{"file_data" => Base.encode64(data)})
  end

  # QQ signs one address for each part. The file is read twice: once for the
  # digests QQ asks for first, and once to put every part and report it. The
  # last request joins the parts into the file.
  defp put_in_parts(connect, chat_id, upload) do
    base = chat_path(chat_id)
    digests = digests(upload.stream)

    prepare = %{
      "file_type" => file_type(upload.filename),
      "file_size" => Integer.to_string(digests.size),
      "file_name" => upload.filename,
      "md5" => digests.md5,
      "sha1" => digests.sha1,
      "md5_10m" => digests.md5_head
    }

    with {:ok, %{"upload_id" => upload_id, "parts" => parts} = prepared}
         when is_binary(upload_id) and is_list(parts) <-
           API.request(connect, :post, base <> "/upload_prepare", json: prepare),
         {:ok, plan} <- part_plan(digests.size, parts, int_or(prepared["block_size"], 0)),
         :ok <- put_parts(connect, base, upload_id, upload.stream, plan) do
      files(connect, chat_id, upload, %{"upload_id" => upload_id})
    else
      {:ok, _body} -> {:error, "QQ did not accept the file"}
      {:error, _reason} = error -> error
    end
  end

  defp files(connect, chat_id, upload, source) do
    API.request(connect, :post, chat_path(chat_id) <> "/files",
      json:
        Map.merge(source, %{
          "file_type" => file_type(upload.filename),
          "file_name" => upload.filename,
          "srv_send_msg" => false
        }),
      receive_timeout: 60_000
    )
  end

  defp digests(stream) do
    start = %{
      md5: :crypto.hash_init(:md5),
      sha1: :crypto.hash_init(:sha),
      md5_head: :crypto.hash_init(:md5),
      size: 0
    }

    digests =
      Enum.reduce(stream, start, fn chunk, acc ->
        head = binary_part(chunk, 0, min(byte_size(chunk), max(@md5_head_bytes - acc.size, 0)))

        %{
          md5: :crypto.hash_update(acc.md5, chunk),
          sha1: :crypto.hash_update(acc.sha1, chunk),
          md5_head: :crypto.hash_update(acc.md5_head, head),
          size: acc.size + byte_size(chunk)
        }
      end)

    %{
      md5: hex_final(digests.md5),
      sha1: hex_final(digests.sha1),
      md5_head: hex_final(digests.md5_head),
      size: digests.size
    }
  end

  # The parts in order, each with the bytes it takes. Together they must cover
  # the file exactly.
  defp part_plan(size, parts, block_size) do
    parts
    |> Enum.sort_by(&int_or(&1["index"], 0))
    |> Enum.reduce_while({0, []}, fn part, {offset, acc} ->
      bytes = min(int_or(part["block_size"], block_size), size - offset)

      if bytes > 0 and is_binary(part["presigned_url"]) do
        planned = {int_or(part["index"], 0), part["presigned_url"], bytes}
        {:cont, {offset + bytes, [planned | acc]}}
      else
        {:halt, :error}
      end
    end)
    |> case do
      {^size, plan} -> {:ok, Enum.reverse(plan)}
      _other -> {:error, "QQ did not accept the file"}
    end
  end

  # Cuts the stream at the planned sizes and puts each part as it fills.
  defp put_parts(connect, base, upload_id, stream, plan) do
    stream
    |> Enum.reduce_while({"", plan}, fn chunk, {buffer, plan} ->
      case put_full_parts(connect, base, upload_id, buffer <> chunk, plan) do
        {:ok, buffer, plan} -> {:cont, {buffer, plan}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {"", []} -> :ok
      {:error, _reason} = error -> error
      # The second read gave other bytes than the first.
      _other -> {:error, "the file changed while it was being sent; send it again"}
    end
  end

  defp put_full_parts(connect, base, upload_id, buffer, [{index, url, bytes} | plan])
       when byte_size(buffer) >= bytes do
    <<part::binary-size(^bytes), rest::binary>> = buffer

    with :ok <- QQTiming.measure("part_upload", fn -> API.put_part(url, part) end),
         {:ok, _body} <-
           API.request(connect, :post, base <> "/upload_part_finish",
             json: %{
               "upload_id" => upload_id,
               "part_index" => index,
               "block_size" => Integer.to_string(bytes),
               "md5" => hex_final(:crypto.hash_update(:crypto.hash_init(:md5), part))
             }
           ) do
      put_full_parts(connect, base, upload_id, rest, plan)
    end
  end

  defp put_full_parts(_connect, _base, _upload_id, buffer, plan), do: {:ok, buffer, plan}

  defp hex_final(state), do: state |> :crypto.hash_final() |> Base.encode16(case: :lower)

  # A reply while the chat's newest message still takes one, and a proactive
  # message otherwise. QQ's own clock decides: when it closes the allowance
  # first, the same body goes out once more as a proactive message.
  defp deliver(connect, chat_id, %{"is_wakeup" => true} = body),
    do: connect |> post(chat_id, body) |> sent(chat_id, "wakeup")

  defp deliver(connect, chat_id, body) do
    {window_ms, max_replies} = reply_allowance(chat_id)

    case QQTiming.measure("reply_reservation", fn ->
           ProviderObservations.reserve_qq_reply(
             connect["connect_id"],
             chat_id,
             window_ms,
             max_replies
           )
         end) do
      {:ok, message_id, seq} ->
        reply = Map.merge(body, reply_to(message_id, seq))

        case post(connect, chat_id, reply) do
          {:error, {:qq_api, _status, code, _message}}
          when code in [@reply_window_closed, @reply_message_expired] ->
            proactive(connect, chat_id, body)

          # QQ gives no reply time for the event of a tap. When it refuses the
          # reply, the answer still goes out.
          {:error, {:qq_api, _status, _code, _message}} when is_map_key(reply, "event_id") ->
            proactive(connect, chat_id, body)

          result ->
            sent(result, chat_id, "reply")
        end

      :none ->
        proactive(connect, chat_id, body)
    end
  end

  # A button tap is answered by its event, a message by its ID.
  defp reply_to("event:" <> event_id, seq), do: %{"event_id" => event_id, "msg_seq" => seq}
  defp reply_to(message_id, seq), do: %{"msg_id" => message_id, "msg_seq" => seq}

  defp proactive(connect, chat_id, body),
    do: connect |> post(chat_id, body) |> sent(chat_id, "proactive")

  # The record of a group, and what a later `quote_message_id` or
  # `qq.delete_message` needs to know of the message.
  defp observe_sent(connect, chat_id, sent, text, file_count) do
    QQTiming.measure("sent_message_record", fn ->
      QQMessageRecord.observe_sent(connect, chat_id, sent, text, file_count)
    end)

    QQTiming.measure("sent_reference_record", fn ->
      ProviderObservations.remember_qq_sent_message(
        connect,
        chat_id,
        str(sent["id"]),
        QQMessageRecord.sent_ref(sent)
      )
    end)
  end

  # ---- quote and recall message ----

  defp send_extra(connect, chat_id, params) do
    wakeup? = params["wakeup"] == true

    with :ok <- wakeup_allowed(wakeup?, chat_id),
         {:ok, reference} <- quote_reference(connect, chat_id, str(params["quote_message_id"])) do
      {:ok,
       %{}
       |> maybe_put("message_reference", reference)
       |> maybe_put("is_wakeup", if(wakeup?, do: true))}
    end
  end

  defp wakeup_allowed(true, "group:" <> _id),
    do: {:error, "wakeup is for a private chat; a group has no such message"}

  defp wakeup_allowed(_wakeup?, _chat_id), do: :ok

  defp quote_reference(_connect, _chat_id, ""), do: {:ok, nil}

  defp quote_reference(_connect, _chat_id, "REFIDX_" <> _rest = index),
    do: {:ok, %{"message_id" => index}}

  defp quote_reference(connect, chat_id, message_id) do
    case ProviderObservations.qq_message_ref(connect["connect_id"], chat_id, message_id) ||
           QQMessageRecord.quote_index(connect, chat_id, message_id) do
      index when is_binary(index) and index != "" ->
        {:ok, %{"message_id" => index}}

      _unknown ->
        {:error,
         "QQ gave no quote index for this message, so it cannot be quoted. Send the answer without quote_message_id."}
    end
  end

  # ---- a message that grows ----

  # QQ shows one message in a private chat and extends it with each part. A
  # part holds the whole text so far, and that text must start with the text
  # of the part before it. The stream is a reply to the chat's newest message
  # and takes one of its replies. `stream_id` carries what the next part needs,
  # so no state is kept between the calls.
  defp stream_message(connect, params) do
    plain? = str(params["format"]) == "text"

    with {:ok, "c2c:" <> openid = chat_id} <- chat_id(connect, params),
         {:ok, text} <- message_text(params),
         true <- text != "" || {:error, "text is required"},
         {:ok, stream} <- stream_state(connect, chat_id, str(params["stream_id"])) do
      done? = params["done"] == true

      body =
        %{
          "input_mode" => "replace",
          "input_state" => if(done?, do: 10, else: 1),
          "index" => stream.index,
          "content_type" => if(plain?, do: "text", else: "markdown"),
          "content_raw" => text
        }
        |> Map.merge(reply_to(stream.reply_to, stream.seq))
        |> maybe_put("stream_msg_id", stream.id)

      case API.request(connect, :post, "/v2/users/#{openid}/stream_messages", json: body) do
        {:ok, sent} ->
          id = if stream.id == "", do: str(sent["id"]), else: stream.id

          {:ok,
           %{"chat_id" => chat_id, "message_id" => id, "done" => done?}
           |> maybe_put("remaining_chars", sent["remain_msg_len"])
           |> maybe_put(
             "stream_id",
             if(not done? and id != "",
               do: stream_token(%{stream | id: id, index: stream.index + 1})
             )
           )}

        error ->
          error_text(error, chat_id)
      end
    else
      {:ok, _group} ->
        {:error, "a growing message is for a private chat; chat_id must be c2c:<user_openid>"}

      {:error, _reason} = error ->
        error
    end
  end

  defp stream_state(connect, chat_id, "") do
    {window_ms, max_replies} = reply_allowance(chat_id)

    case ProviderObservations.reserve_qq_reply(
           connect["connect_id"],
           chat_id,
           window_ms,
           max_replies
         ) do
      {:ok, message_id, seq} ->
        {:ok, %{id: "", index: 0, reply_to: message_id, seq: seq}}

      :none ->
        {:error,
         "a growing message answers a message of the last 60 minutes; send this one with qq.send_message"}
    end
  end

  defp stream_state(_connect, _chat_id, token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, [id, index, reply_to, seq]}
         when is_binary(id) and id != "" and is_integer(index) and index > 0 and
                is_binary(reply_to) and is_integer(seq) <- Jason.decode(json) do
      {:ok, %{id: id, index: index, reply_to: reply_to, seq: seq}}
    else
      _invalid -> {:error, "stream_id is not one that qq.stream_message returned"}
    end
  end

  defp stream_token(stream),
    do:
      [stream.id, stream.index, stream.reply_to, stream.seq]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp post(connect, chat_id, body),
    do: API.request(connect, :post, chat_path(chat_id) <> "/messages", json: body)

  defp sent({:ok, body}, _chat_id, delivery),
    do: {:ok, %{message_id: str(body["id"]), delivery: delivery, body: body}}

  defp sent({:error, _reason} = error, chat_id, _delivery), do: error_text(error, chat_id)

  defp error_text({:error, {:qq_api, _status, @proactive_refused, _message}}, "group:" <> _id) do
    {:error,
     "QQ refused a proactive message to this group. The reply time for the last mention is over. " <>
       "A group admin can turn on \"机器人主动在群聊内发言\" in the bot's settings in that group, or a member can mention the bot again."}
  end

  defp error_text({:error, {:qq_api, _status, @proactive_refused, _message}}, _chat_id) do
    {:error,
     "QQ refused a proactive message to this person: they turned off proactive messages from the bot. " <>
       "The answer can be sent after they write again."}
  end

  defp error_text({:error, %{"error_class" => _class} = unknown}, _chat_id), do: {:error, unknown}
  defp error_text({:error, reason}, _chat_id), do: {:error, API.error_text(reason)}
  defp error_text(result, _chat_id), do: result

  defp reply_allowance("group:" <> _id), do: {@group_reply_window_ms, @group_reply_max}
  defp reply_allowance(_chat_id), do: {@private_reply_window_ms, @private_reply_max}

  defp chat_path("group:" <> openid), do: "/v2/groups/" <> openid
  defp chat_path("c2c:" <> openid), do: "/v2/users/" <> openid

  # ---- parameters ----

  defp chat_id(connect, params) do
    chat_id =
      case str(params["chat_id"]) do
        "" -> str(origin_context(connect)["chat_id"])
        chat_id -> chat_id
      end

    cond do
      chat_id == "" ->
        {:error, "chat_id is required outside a QQ source"}

      not Regex.match?(~r/\A(group|c2c):[A-Za-z0-9_-]{1,128}\z/, chat_id) ->
        {:error, "chat_id must be group:<group_openid> or c2c:<user_openid>"}

      true ->
        {:ok, chat_id}
    end
  end

  defp origin_context(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "qq", "provider_context" => %{} = context} ->
        if context["connect_id"] == connect["connect_id"], do: context, else: %{}

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

  defp upload(_agent_id, path) when path in [nil, ""], do: {:ok, nil}

  defp upload(agent_id, path) do
    path = str(path)

    case SalixIM.Ports.AgentWorkspace.read_stream(agent_id, path) do
      {:ok, stream, size, filename} when is_integer(size) and is_binary(filename) ->
        max = SystemsRuntime.get_env(:salix_im, :qq_upload_max_bytes, @default_max_file_bytes)

        cond do
          filename in ["", ".", "/"] ->
            {:error, "path must point to a file"}

          size > max ->
            {:error, "The file is larger than #{max} bytes, the limit for a file sent to QQ"}

          true ->
            {:ok, %{stream: stream, size: size, filename: filename}}
        end

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _other ->
        {:error, "file not found in agent VFS: #{path}"}
    end
  end

  # QQ shows an image or a video inline only for these formats; anything else
  # is a file card.
  defp file_type(filename) do
    case filename |> to_string() |> Path.extname() |> String.downcase() do
      ext when ext in [".png", ".jpg", ".jpeg"] -> 1
      ".mp4" -> 2
      _other -> 4
    end
  end

  # Buttons under the message.
  defp keyboard(nil), do: {:ok, nil}
  defp keyboard([]), do: {:ok, nil}

  defp keyboard(buttons) when is_list(buttons) and length(buttons) <= @max_buttons do
    buttons
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {button, index}, {:ok, acc} ->
      case button(button, index) do
        {:ok, button} -> {:cont, {:ok, [button | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, buttons} ->
        rows =
          buttons
          |> Enum.reverse()
          |> Enum.chunk_every(@buttons_per_row)
          |> Enum.map(&%{"buttons" => &1})

        {:ok, %{"content" => %{"rows" => rows}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp keyboard(_buttons),
    do: {:error, "buttons must be a list of at most #{@max_buttons} buttons"}

  # One of three kinds, by the field it carries: `url` opens a link, `callback`
  # sends its data back to the bot, `command` puts its text in the input box.
  defp button(%{} = button, index) do
    label = str(button["label"])
    confirm = str(button["confirm"])

    kinds =
      for {field, type} <- [{"url", 0}, {"callback", 1}, {"command", 2}],
          data = str(button[field]),
          data != "",
          do: {field, type, data}

    cond do
      label == "" or String.length(label) > @max_button_label_chars ->
        {:error, "each button needs a label of at most #{@max_button_label_chars} characters"}

      length(kinds) != 1 ->
        {:error, "each button needs one of url, callback or command"}

      String.length(confirm) > @max_confirm_chars ->
        {:error, "confirm takes at most #{@max_confirm_chars} characters"}

      true ->
        [{field, type, data}] = kinds

        cond do
          field == "url" and not String.starts_with?(data, "https://") ->
            {:error, "each button needs an https url"}

          field != "url" and byte_size(data) > @max_button_data_bytes ->
            {:error, "#{field} takes at most #{@max_button_data_bytes} bytes"}

          true ->
            {:ok,
             %{
               "id" => Integer.to_string(index),
               "render_data" => %{"label" => label, "visited_label" => label, "style" => 1},
               "action" =>
                 %{
                   "type" => type,
                   # Anyone in the chat, or only the admins of a group.
                   "permission" => %{"type" => if(button["admin_only"] == true, do: 1, else: 2)},
                   "data" => data,
                   "unsupport_tips" => if(field == "url", do: data, else: label)
                 }
                 |> maybe_put("modal", if(confirm != "", do: %{"content" => confirm}))
             }}
        end
    end
  end

  defp button(_button, _index),
    do: {:error, "each button needs a label and one of url, callback or command"}

  # The menu of the bot's private chats. QQ shows one menu to everyone.
  defp menu_items(items) when is_list(items) and length(items) <= @max_menu_items do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case menu_item(item, true) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp menu_items(_items),
    do: {:error, "items must be a list of at most #{@max_menu_items} menu items"}

  defp menu_item(%{} = item, top?) do
    name = str(item["name"])
    text = str(item["text"])
    url = str(item["url"])
    children = item["items"]

    cond do
      name == "" or String.length(name) > 10 ->
        {:error, "each menu item needs a name of at most 10 characters"}

      text != "" and url == "" and children in [nil, []] ->
        {:ok, %{"name" => name, "type" => "send_message", "send_message" => text}}

      url != "" and text == "" and children in [nil, []] and String.starts_with?(url, "https://") ->
        {:ok, %{"name" => name, "type" => "link", "link" => url}}

      top? and text == "" and url == "" and is_list(children) and children != [] and
          length(children) <= @max_submenu_items ->
        children
        |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
          case menu_item(child, false) do
            {:ok, child} -> {:cont, {:ok, [child | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, children} ->
            {:ok, %{"name" => name, "type" => "menu", "sub_menu_items" => Enum.reverse(children)}}

          error ->
            error
        end

      true ->
        {:error,
         "each menu item needs one of text, an https url, or (top level only) items with at most #{@max_submenu_items} entries"}
    end
  end

  defp menu_item(_item, _top?), do: {:error, "each menu item must be an object"}
end
