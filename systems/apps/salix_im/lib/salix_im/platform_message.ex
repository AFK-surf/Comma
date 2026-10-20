defmodule SalixIM.PlatformMessage do
  @moduledoc false

  require Logger

  @providers ~w(slack telegram feishu wechat imessage signal discord lark)
  @text_operations ~w(slack.post_message slack.reply_message slack.post_channel_message slack.send_dm
    telegram.send_message telegram.remove_reply_keyboard wechat.reply_text
    feishu.send_text feishu.reply_text imessage.send_message signal.send_message
    lark.send_message)
  @media_operations ~w(slack.upload_file telegram.send_photo telegram.send_document
    wechat.reply_image wechat.reply_file wechat.reply_video feishu.send_image feishu.send_file
    feishu.reply_file imessage.send_image)

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

    if origin["provider"] in @providers and origin["source_actor_type"] == "provider_user" and
         (is_binary(origin["source_text"]) or attachments != []) do
      content =
        text_blocks(origin["source_text"]) ++
          Enum.flat_map(attachments, &attachment_block/1)

      presentation(origin["provider"], "user", content)
    end
  end

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
         false <- personal_copy?(connect),
         %{} = message <- outbound(connect["provider"], api, params, sent),
         key when is_binary(key) <- receipt_key(scope, connect, api, params, sent) do
      reply_source = wechat_reply_source(scope, connect)
      image = sent_image(api, params, upload)
      context = SystemsObservability.Context.capture()

      case SystemsRuntime.TaskSupervisor.start_child(SalixIM.ConversationProjectionTasks, fn ->
             SystemsObservability.Context.run(context, fn ->
               message = bind_image(message, scope.agent_id, image)
               record(scope.group_id, scope.agent_id, message, key, reply_source)
             end)
           end) do
        {:ok, _pid} -> :ok
        _ -> Logger.warning("platform_message_history_write_failed")
      end

      result
    else
      false ->
        result

      true ->
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

  # A send to the owner's bound personal chat is a second copy of a Home reply
  # unless the current source is a message from that same chat. Home already
  # shows the reply, so only the conversation held in that chat is presented
  # again. Other sources of the same activation do not count.
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
  defp record(group_id, agent_id, message, key, reply_source) do
    with {:ok, %{"router_agent_id" => ^agent_id} = group} <-
           SalixIM.GroupDirectory.get_group(group_id),
         false <- SalixIM.IFC.Ingress.enabled?(group),
         {:ok, conversation} <- SalixIM.RouterConversationInput.ensure(group_id),
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

  # Capture current ingress provenance before leaving the provider caller.
  # The Conversation owner resolves it against its committed input Message.
  defp wechat_reply_source(scope, %{"provider" => "wechat", "connect_id" => connect_id}) do
    context = SalixIM.Provider.current_tool_context()
    source = context["source_message_id"]
    session = context["session_id"]

    with true <- is_binary(source) and source != "" and is_binary(session) and session != "",
         true <- source in List.wrap(context["source_message_ids"]),
         %{
           "provider" => "wechat",
           "source_actor_type" => "provider_user",
           "source_message_id" => ^source,
           "agent_group_id" => group_id,
           "provider_context" => %{"connect_id" => ^connect_id}
         } <- context["trusted_origin"],
         true <- group_id == scope.group_id do
      %{"source_message_id" => source, "session_id" => session, "connect_id" => connect_id}
    else
      _ -> nil
    end
  end

  defp wechat_reply_source(_scope, _connect), do: nil

  defp outbound(provider, api, params, sent) do
    text = params["text"] || params["caption"] || params["initial_comment"]

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
           (api in ["signal.send_message", "lark.send_message"] and params["path"]) do
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
