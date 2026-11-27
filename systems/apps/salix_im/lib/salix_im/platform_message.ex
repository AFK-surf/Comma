defmodule SalixIM.PlatformMessage do
  @moduledoc false

  require Logger

  @providers ~w(slack telegram feishu wechat imessage signal discord lark)
  @text_operations ~w(slack.post_message slack.reply_message slack.post_channel_message slack.send_dm
    telegram.send_message telegram.remove_reply_keyboard wechat.reply_text
    feishu.send_message feishu.send_text feishu.reply_text imessage.send_message
    signal.send_message lark.send_message)
  @media_operations ~w(slack.upload_file telegram.send_photo telegram.send_document
    wechat.reply_image wechat.reply_file wechat.reply_video feishu.send_image feishu.send_file
    feishu.reply_file imessage.send_image imessage.send_file)

  # Home readers are every Group user, outside the IFC reader model. A Group
  # that labels provider content keeps it agent-private instead, including rows
  # written before it opted in. An unreadable Group record presents nothing.
  def project_all(group_id, messages) when is_list(messages) do
    if Enum.any?(messages, &candidate?/1) do
      visible? = presentable_group?(group_id)
      Enum.map(messages, &project(&1, visible?))
    else
      messages
    end
  end

  defp candidate?(%{"platform_message" => _}), do: true
  defp candidate?(%{"actor_type" => "system", "agent_input" => input}), do: is_map(input)
  defp candidate?(_message), do: false

  defp presentable_group?(group_id) do
    case SalixIM.GroupDirectory.get_group(group_id) do
      {:ok, group} -> not SalixIM.IFC.Ingress.enabled?(group)
      _ -> false
    end
  end

  # The private prompt remains agent_input.content. Only the ingress-owned body
  # and attachment display names become chat content, including for old rows.
  defp project(message, false), do: Map.delete(message, "platform_message")

  defp project(%{"actor_type" => "system", "agent_input" => input} = message, true)
       when is_map(input) do
    case inbound(input) do
      nil -> message
      presentation -> Map.put(message, "platform_message", presentation)
    end
  end

  defp project(message, true), do: message

  def inbound(input) do
    origin = value(input, :trusted_origin) || %{}
    attachments = value(input, :trusted_attachment_refs) || []
    media = value(input, :platform_media) || %{}
    images = Map.new(List.wrap(media["images"]), &{&1["path"], &1})

    if origin["provider"] in @providers and origin["source_actor_type"] == "provider_user" and
         (is_binary(origin["source_text"]) or attachments != []) do
      content =
        text_blocks(origin["source_text"]) ++
          Enum.flat_map(attachments, &inbound_attachment_block(&1, images))

      presentation = presentation(origin["provider"], "user", content)
      agent_id = media["agent_id"]

      # The client reads a bound image through the Agent that owns its blob.
      if is_map(presentation) and is_binary(agent_id) and
           Enum.any?(content, &Map.has_key?(&1, "blob_ref")),
         do: Map.put(presentation, "agent_id", agent_id),
         else: presentation
    end
  end

  # Images a person sent, as Home shows them: a browser shows PNG, JPEG, GIF
  # and WebP as they are. Other image types (HEIC from an iPhone) get a JPEG
  # preview. An image that cannot be shown keeps its name-only card.
  @shown_image_mimes ~w(image/png image/jpeg image/gif image/webp)
  @converted_image_mimes ~w(image/heic image/heif image/bmp image/x-ms-bmp image/tiff image/avif)

  @doc """
  The images of staged provider attachments that Home can show, bound to the
  blob of the Agent they were staged for. Runs before the input is appended,
  so reading a Conversation never reads a workspace or converts an image.
  """
  def inbound_media(agent_id, staged) when is_binary(agent_id) and is_list(staged) do
    images = Enum.flat_map(staged, &shown_image(agent_id, &1))
    if images == [], do: nil, else: %{"agent_id" => agent_id, "images" => images}
  end

  def inbound_media(_agent_id, _staged), do: nil

  defp shown_image(agent_id, %{"path" => path, "blob_ref" => %{} = ref} = attachment)
       when is_binary(path) do
    ref = Map.new(ref, fn {key, value} -> {to_string(key), value} end)
    name = attachment["file_name"] || Path.basename(path)

    case SalixIM.AttachmentMedia.native_image_mime(attachment["mime"], name) do
      {:ok, mime} when mime in @shown_image_mimes ->
        [%{"path" => path, "blob_ref" => ref, "size" => ref["size"], "mime_type" => mime}]

      {:ok, mime} when mime in @converted_image_mimes ->
        with {:ok, body} <- SalixStore.Blob.get(agent_id, ref),
             {:ok, jpeg, "image/jpeg"} <- SalixMedia.ImageInput.prepare(body, mime),
             {:ok, preview} <- SalixStore.Blob.put(agent_id, jpeg) do
          preview = Map.new(preview, fn {key, value} -> {to_string(key), value} end)

          [
            %{
              "path" => path,
              "blob_ref" => preview,
              "size" => byte_size(jpeg),
              "mime_type" => "image/jpeg",
              "file_name" => Path.rootname(Path.basename(name)) <> ".jpg"
            }
          ]
        else
          _unconverted -> []
        end

      _other ->
        []
    end
  rescue
    _ -> []
  end

  defp shown_image(_agent_id, _attachment), do: []

  defp inbound_attachment_block(
         %{"type" => "image", "file_ref" => %{"path" => path}} = block,
         images
       )
       when is_map_key(images, path) do
    image = images[path]

    [
      %{
        "type" => "image",
        "file_name" => image["file_name"] || Path.basename(block["file_name"] || path),
        "mime_type" => image["mime_type"],
        "blob_ref" => image["blob_ref"],
        "size" => image["size"]
      }
    ]
  end

  defp inbound_attachment_block(block, _images), do: attachment_block(block)

  @upload_key :salix_im_platform_message_upload

  @doc """
  Remembers the bytes a provider read for this send, in the provider caller's
  process, so its history shows exactly what the platform received. The next
  `record_success/5` in the same process takes it.
  """
  def note_upload(path, data) when is_binary(path) and is_binary(data),
    do: Process.put(@upload_key, {path, data})

  # Record only a successful explicit send. A history write cannot turn an
  # acknowledged platform send into a retryable tool failure.
  def record_success(result, scope, connect, api, params) do
    upload = Process.delete(@upload_key)
    record_success(result, scope, connect, api, params, upload)
  end

  defp record_success({:ok, sent} = result, scope, connect, api, params, upload) do
    # Without a receipt identity a retry could append the same send twice.
    with true <- api in @text_operations or api in @media_operations,
         %{} = message <- outbound(connect["provider"], api, params, sent),
         key when is_binary(key) <- receipt_key(scope, connect, api, params, sent) do
      reply_source = reply_source(scope, connect, params, sent)
      copy_of = if personal_copy?(connect), do: copy_text(params)
      image = sent_image(api, params, upload)
      context = SystemsObservability.Context.capture()

      case SystemsRuntime.TaskSupervisor.start_child(SalixIM.ConversationProjectionTasks, fn ->
             SystemsObservability.Context.run(context, fn ->
               message = bind_image(message, scope.agent_id, image)
               record(scope.group_id, scope.agent_id, message, key, reply_source, copy_of)
             end)
           end) do
        {:ok, _pid} -> :ok
        _ -> Logger.warning("platform_message_history_write_failed")
      end

      result
    else
      false ->
        result

      nil ->
        result
    end
  rescue
    _ ->
      Logger.warning("platform_message_history_write_failed")
      result
  catch
    _, _ ->
      Logger.warning("platform_message_history_write_failed")
      result
  end

  defp record_success(result, _scope, _connect, _api, _params, _upload), do: result

  # The bytes the provider read for this send's own path, if it read any.
  defp sent_image(api, %{"path" => path}, {upload_path, data})
       when api in @media_operations and is_binary(path),
       do: if(String.trim(path) == upload_path, do: data)

  defp sent_image(_api, _params, _upload), do: nil

  # A send to the owner's bound personal chat may be a second copy of a Home
  # reply unless the current source is a message from that same chat. Other
  # sources of the same activation do not count. Such a send stays out of Home
  # only when Home already shows the same text from the Router: a reminder
  # sent to the personal chat alone is presented like any other send.
  defp personal_copy?(%{
         "managed_by" => "comma_product",
         "provider" => provider,
         "connect_id" => connect_id
       })
       when provider in ~w(telegram wechat) do
    origin = SalixIM.Provider.current_tool_context()["trusted_origin"]

    not (is_map(origin) and value(origin, :provider) == provider and
           value(origin, :source_actor_type) == "provider_user" and
           (value(origin, :provider_context) || %{})["connect_id"] == connect_id)
  end

  defp personal_copy?(_connect), do: false

  # Reuse the bounded display-projection pool (64 children per node). The
  # provider caller never waits for the history owner or repeats platform I/O.
  # Home presents only the Router's own sends; Task Workers report in their
  # Task. Labelled Groups keep sends out of Home as they do inputs.
  defp record(group_id, agent_id, message, key, reply_source, copy_of) do
    with {:ok, %{"router_agent_id" => ^agent_id} = group} <-
           SalixIM.GroupDirectory.get_group(group_id),
         false <- SalixIM.IFC.Ingress.enabled?(group),
         {:ok, conversation} <- SalixIM.RouterConversationInput.ensure(group_id),
         false <- home_shows?(group_id, conversation["conversation_id"], agent_id, copy_of),
         {:ok, _} <-
           SalixIM.ConversationServer.append_platform_message(
             group_id,
             conversation["conversation_id"],
             message,
             key,
             reply_source
           ) do
      :ok
    else
      {:ok, _group} -> :ok
      true -> :ok
      _ -> Logger.warning("platform_message_history_write_failed")
    end
  rescue
    _ -> Logger.warning("platform_message_history_write_failed")
  catch
    _, _ -> Logger.warning("platform_message_history_write_failed")
  end

  # The Router sends the copy after its Home reply, so the reply is among the
  # latest Home Messages. One bounded tail page is read; a failed read records.
  @copy_window 20

  defp home_shows?(_group_id, _conversation_id, _agent_id, nil), do: false

  defp home_shows?(group_id, conversation_id, agent_id, text) do
    case SalixIM.Conversations.list_group_conversation_message_page(group_id, conversation_id,
           limit: @copy_window
         ) do
      {:ok, %{"messages" => messages}} ->
        Enum.any?(messages, fn message ->
          message["actor_type"] == "agent" and message["agent_id"] == agent_id and
            copy_text(%{"text" => content_text(message["content"])}) == text
        end)

      _ ->
        false
    end
  end

  defp copy_text(params) do
    case params["text"] || params["caption"] do
      text when is_binary(text) ->
        case text |> String.split() |> Enum.join(" ") do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  defp content_text(text) when is_binary(text), do: text

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp content_text(_content), do: nil

  # Capture current ingress provenance before leaving the provider caller.
  # The Conversation owner resolves it against its committed Messages so a
  # chain of parent IDs converges onto one `thread_root_message_id`.
  defp reply_source(scope, %{"provider" => "wechat"} = connect, params, sent) do
    scope
    |> source_reply(connect)
    |> put_sent_identity(connect, params, sent)
  end

  defp reply_source(scope, %{"provider" => provider} = connect, params, sent)
       when provider in @providers do
    target =
      case params["reply_to_message_id"] do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end

    reply =
      with true <- is_binary(target),
           false <- is_map(sent) and Map.has_key?(sent, "reply_fallback") do
        case origin_reply(scope, connect, target) do
          %{} = matched ->
            matched

          nil ->
            %{
              "connect_id" => connect["connect_id"],
              "reply_to_provider_message_id" => target
            }
        end
      else
        _ ->
          if is_nil(target) or (is_map(sent) and Map.has_key?(sent, "reply_fallback")) do
            case source_reply(scope, connect) do
              %{"source_message_id" => source, "session_id" => session} = current ->
                current
                |> Map.delete("source_message_id")
                |> Map.put("thread_source_message_id", source)
                |> Map.put("session_id", session)

              _ ->
                nil
            end
          end
      end

    put_sent_identity(reply, connect, params, sent)
  end

  defp reply_source(_scope, connect, params, sent),
    do: put_sent_identity(nil, connect, params, sent)

  defp origin_reply(scope, %{"provider" => provider, "connect_id" => connect_id}, target)
       when is_binary(provider) and provider != "" and
              is_binary(connect_id) and connect_id != "" do
    context = SalixIM.Provider.current_tool_context()
    session = context["session_id"]
    allowed = List.wrap(context["source_message_ids"])

    origins =
      (List.wrap(context["trusted_origins"]) ++ List.wrap(context["trusted_origin"]))
      |> Enum.filter(&is_map/1)
      |> Enum.uniq()

    with true <- is_binary(session) and session != "",
         %{"source_message_id" => source} = origin
         when is_binary(source) and source != "" <-
           Enum.find(origins, fn origin ->
             pctx = origin["provider_context"] || %{}

             origin["provider"] == provider and
               origin["source_actor_type"] == "provider_user" and
               origin["agent_group_id"] == scope.group_id and
               origin["source_message_id"] in allowed and
               pctx["connect_id"] == connect_id and
               (to_string(pctx["message_id"] || "") == target or
                  target in Enum.map(List.wrap(pctx["source_message_ids"]), &to_string/1))
           end) do
      pctx = origin["provider_context"] || %{}

      %{
        "source_message_id" => source,
        "session_id" => session,
        "connect_id" => connect_id,
        "reply_to_provider_message_id" => target
      }
      |> maybe_put("stream_key", origin_stream_key(pctx))
    else
      _ -> nil
    end
  end

  defp origin_reply(_scope, _connect, _target), do: nil

  defp put_sent_identity(reply, connect, params, sent) do
    connect_id = if is_map(connect), do: connect["connect_id"]
    sent_id = sent_message_id(sent)
    stream = (is_map(reply) && reply["stream_key"]) || fallback_stream_key(connect, params)

    extra =
      %{}
      |> maybe_put("connect_id", connect_id)
      |> maybe_put("provider_message_id", sent_id)
      |> maybe_put("stream_key", stream)

    cond do
      is_map(reply) and map_size(extra) > 0 -> Map.merge(extra, reply)
      is_map(reply) -> reply
      map_size(extra) > 0 -> extra
      true -> nil
    end
  end

  @stream_keys ~w(thread_ts message_thread_id root_message_id channel_id chat_id wechat_id
    from_user_id sender_open_id user_id sender_id)

  defp origin_stream_key(pctx) when is_map(pctx) do
    Enum.find_value(@stream_keys, fn key ->
      val = pctx[key]
      if is_binary(val) and val != "", do: val
    end)
  end

  defp origin_stream_key(_), do: nil

  defp fallback_stream_key(connect, params) do
    pctx =
      case SalixIM.Provider.current_tool_context() do
        %{"trusted_origin" => %{"provider_context" => %{} = ctx}} -> ctx
        _ -> %{}
      end

    origin_stream_key(pctx) ||
      if(is_map(params), do: origin_stream_key(params)) ||
      if(is_map(connect), do: origin_stream_key(connect))
  end

  defp sent_message_id(sent) when is_map(sent) do
    candidate =
      sent["message_id"] || sent["ts"] || sent["timestamp"] || sent["client_id"] ||
        get_in(sent, ["message", "message_id"])

    cond do
      is_binary(candidate) and candidate != "" -> candidate
      is_integer(candidate) -> Integer.to_string(candidate)
      true -> nil
    end
  end

  defp sent_message_id(_sent), do: nil

  defp maybe_put(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map

  defp source_reply(scope, %{"provider" => provider, "connect_id" => connect_id})
       when is_binary(provider) and provider != "" and
              is_binary(connect_id) and connect_id != "" do
    context = SalixIM.Provider.current_tool_context()
    session = context["session_id"]
    allowed = List.wrap(context["source_message_ids"])
    batched = Enum.reverse(List.wrap(context["trusted_origins"]))

    origins =
      (List.wrap(context["trusted_origin"]) ++ batched)
      |> Enum.filter(&is_map/1)
      |> Enum.uniq()

    with true <- is_binary(session) and session != "",
         %{"source_message_id" => source} = origin
         when is_binary(source) and source != "" <-
           Enum.find(origins, fn origin ->
             pctx = origin["provider_context"] || %{}

             origin["provider"] == provider and
               origin["source_actor_type"] == "provider_user" and
               origin["agent_group_id"] == scope.group_id and
               origin["source_message_id"] in allowed and
               pctx["connect_id"] == connect_id
           end) do
      pctx = origin["provider_context"] || %{}

      %{
        "source_message_id" => source,
        "session_id" => session,
        "connect_id" => connect_id
      }
      |> maybe_put("stream_key", origin_stream_key(pctx))
    else
      _ -> nil
    end
  end

  defp source_reply(_scope, _connect), do: nil

  defp outbound(provider, api, params, sent) do
    text =
      if provider == "imessage",
        do: params["text"],
        else: params["text"] || params["caption"] || params["initial_comment"]

    text =
      if provider == "wechat" and is_binary(text) do
        case SalixIM.WeChatMarkdown.render(text) do
          {:ok, rendered} -> rendered
          _ -> text
        end
      else
        text
      end

    media =
      if api in @media_operations or
           (api in ["signal.send_message", "lark.send_message", "feishu.send_message"] and
              params["path"]) do
        name = if is_map(sent), do: sent["filename"]
        [media_block(name || params["path"], api)]
      else
        []
      end

    presentation(provider, "assistant", text_blocks(text) ++ media)
  end

  defp presentation(provider, role, [_ | _] = content) when provider in @providers,
    do: %{"provider" => provider, "role" => role, "content" => content}

  defp presentation(_, _, _), do: nil

  defp attachment_block(%{"type" => type} = block) when type in ["file", "image"] do
    [media_block(block["file_name"] || block["title"], type)]
  end

  defp attachment_block(_), do: []

  # A sent image is stored as an immutable blob of exactly the bytes the
  # provider uploaded, so Home shows the picture the platform received even if
  # the file changes afterwards. Storing runs in the history task: the provider
  # caller never waits on storage, and an image that cannot be stored keeps its
  # name-only card.
  defp bind_image(%{"content" => content} = message, agent_id, data) when is_binary(data) do
    with true <- Enum.any?(content, &match?(%{"type" => "image"}, &1)),
         {:ok, ref} <- SalixStore.Blob.put(agent_id, data) do
      ref = Map.new(ref, fn {key, value} -> {to_string(key), value} end)

      content =
        Enum.map(content, fn
          %{"type" => "image"} = block ->
            block |> Map.put("blob_ref", ref) |> Map.put("size", byte_size(data))

          block ->
            block
        end)

      message |> Map.put("content", content) |> Map.put("agent_id", agent_id)
    else
      _unbound -> message
    end
  end

  defp bind_image(message, _agent_id, _data), do: message

  # A display-only attachment: name and media type, no locator. The file stays
  # with the provider and the agent, so Home shows a card it cannot open unless
  # `bind_image/3` binds it.
  defp media_block(name, type) do
    kind = if String.contains?(type, ["image", "photo"]), do: "image", else: "file"
    name = if is_binary(name), do: Path.basename(name)

    if name in [nil, "", "."] do
      %{"type" => kind}
    else
      %{"type" => kind, "file_name" => name, "mime_type" => MIME.from_path(name)}
    end
  end

  defp text_blocks(text) when is_binary(text) and text != "",
    do: [%{"type" => "text", "text" => text}]

  defp text_blocks(_), do: []

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp receipt_key(scope, connect, api, params, sent) do
    sent = if is_map(sent), do: sent, else: %{}

    identity =
      scope[:tool_call_id] || sent["message_id"] || sent["ts"] || sent["timestamp"] ||
        get_in(sent, ["message", "message_id"])

    if identity do
      "platform-message:" <>
        Jason.encode!([
          scope.agent_id,
          SalixIM.Provider.current_tool_context()["session_id"],
          connect["connect_id"],
          api,
          params["chat_id"] || params["channel"] || params["receive_id"],
          identity
        ])
    end
  end
end
