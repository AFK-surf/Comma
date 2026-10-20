defmodule SalixIM.Provider.IMessage do
  @moduledoc """
  Private iMessage operations scoped to the immutable Comma-managed DM.
  The connect's `runtime_mode` selects the transport: the Willow relay
  (`product_relay`) or Photon shared lines (`photon`).
  """

  alias SalixIM.{IMessageRelay, PhotonIMessage, ProviderConnects, ProviderRecipientIdentity}
  alias SalixIM.Provider.Util

  @doc "Whether the connect belongs to the currently configured transport identity."
  def current_transport?(
        %{"managed_by" => "comma_product", "runtime_mode" => "photon"} = connect
      ),
      do: PhotonIMessage.configured?() and connect["relay_id"] == PhotonIMessage.relay_id()

  def current_transport?(connect) do
    IMessageRelay.configured?() and connect["managed_by"] == "comma_product" and
      connect["relay_id"] == IMessageRelay.relay_id() and
      connect["bot_user_id"] == IMessageRelay.shared_handle()
  end

  @doc "The transport name of a connect or an event: `photon` or `relay`."
  def transport(%{"runtime_mode" => "photon"}), do: "photon"
  def transport(%{"transport" => "photon"}), do: "photon"
  def transport(_connect_or_event), do: "relay"

  def call(agent_id, connect, api, params) do
    with :ok <- Util.ensure_connected(connect),
         true <- current_transport?(connect),
         true <- params["chat_id"] == connect["managed_chat_id"] do
      with {:ok, parent_id} <- reply_target(connect, api, params) do
        send_message(agent_id, connect, api, params, parent_id)
      end
    else
      false -> {:error, "This iMessage connection can only address its bound private chat"}
      other -> other
    end
  end

  # Tapbacks Photon maps to native iMessage reactions; other emoji are sent as emoji reactions.
  @tapbacks ["❤️", "👍", "👎", "😂", "‼️", "❓"]

  # A reply or reaction target must be a Photon Message in the bound Space.
  # `imessage.react` defaults to the current source message; sends reply only
  # when the Agent names a target, as Telegram does.
  defp reply_target(connect, api, params) do
    explicit =
      if api == "imessage.react", do: params["message_id"], else: params["reply_to_message_id"]

    target =
      cond do
        is_binary(explicit) and explicit != "" -> explicit
        api == "imessage.react" -> origin_message_id(connect)
        true -> nil
      end

    cond do
      api == "imessage.react" and transport(connect) != "photon" ->
        {:error, "This iMessage connection cannot send reactions"}

      is_nil(target) and api == "imessage.react" ->
        {:error, "message_id is required: name the message to react to"}

      is_nil(target) ->
        {:ok, nil}

      transport(connect) != "photon" ->
        {:error, "This iMessage connection cannot reply to or react to a specific message"}

      true ->
        chat = connect["managed_chat_id"]

        case PhotonIMessage.get_message(target) do
          {:ok, %{"space" => %{"id" => ^chat}}} ->
            {:ok, target}

          {:ok, _other_space} ->
            {:error, "The message to reply to or react to must be in this chat"}

          {:error, {:photon, 404, _}} ->
            {:error, "The message to reply to or react to was not found in this chat"}

          _ ->
            {:error, "iMessage is unavailable. Nothing was sent."}
        end
    end
  end

  defp origin_message_id(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "imessage", "provider_context" => %{} = context} ->
        if context["connect_id"] == connect["connect_id"], do: context["message_id"]

      _ ->
        nil
    end
  end

  defp send_message(_agent_id, connect, "imessage.react", params, parent_id) do
    emoji = if is_binary(params["emoji"]), do: String.trim(params["emoji"]), else: ""
    action = if params["remove"] == true, do: "remove", else: "add"

    if emoji == "" or String.length(emoji) > 8 do
      {:error, "emoji must be one emoji, for example one of #{Enum.join(@tapbacks, " ")}"}
    else
      PhotonIMessage.send_reaction(
        connect["bot_user_id"],
        connect["managed_chat_id"],
        parent_id,
        emoji,
        action
      )
    end
  end

  defp send_message(_agent_id, connect, "imessage.send_message", %{"text" => text}, parent_id)
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= 65_536 do
    case transport(connect) do
      "photon" ->
        PhotonIMessage.send_text(
          connect["bot_user_id"],
          connect["managed_chat_id"],
          text,
          parent_id
        )

      "relay" ->
        IMessageRelay.send_text(connect["managed_peer_id"], connect["managed_chat_id"], text)
    end
  end

  defp send_message(agent_id, connect, "imessage.send_image", params, parent_id) do
    with {:ok, upload} <- Util.read_agent_upload(agent_id, params["path"]) do
      case transport(connect) do
        "photon" ->
          PhotonIMessage.send_image(
            connect["bot_user_id"],
            connect["managed_chat_id"],
            upload,
            params["caption"] || "",
            parent_id
          )

        "relay" ->
          IMessageRelay.send_image(
            connect["managed_peer_id"],
            connect["managed_chat_id"],
            upload,
            params["caption"] || ""
          )
      end
    end
  end

  defp send_message(_agent_id, _connect, _api, _params, _parent_id),
    do: {:error, "Unsupported iMessage operation or invalid message"}

  def inbound(connect, %{"message" => message} = event) do
    with {:ok, current} <-
           ProviderConnects.get_active_connect_by_id(
             connect["group_id"],
             connect["connect_id"],
             "imessage"
           ),
         true <- current_transport?(current),
         true <- transport(current) == transport(event),
         true <- Map.get(message, "is_group", false) == false,
         true <- message["sender_handle"] == current["managed_peer_id"],
         true <- message["chat_guid"] == current["managed_chat_id"] do
      metadata =
        ProviderRecipientIdentity.put(
          %{
            "provider" => "imessage",
            "connect_id" => current["connect_id"],
            "chat_id" => message["chat_guid"],
            "chat_type" => "private",
            "message_id" => message["message_id"],
            "from_user_id" => message["sender_handle"],
            "from_username" => message["sender_display_name"],
            "event_id" => event["event_id"]
          }
          |> put_reply_to(message["reply_to_message_id"]),
          current
        )

      # The Session actor owns permanent input dedupe. A relay replay carries
      # exactly the same stable source id, including after receiver restart.
      ProviderConnects.enqueue_group_router_im_provider_message(
        current["group_id"],
        content(current, message),
        metadata,
        "im_provider:imessage:#{current["connect_id"]}:#{message["receipt_id"] || message["message_id"]}",
        trusted_source_text: message["text"] || "",
        attachments: attachments(current, message)
      )
    else
      false -> {:error, :imessage_link_inconsistent}
      other -> other
    end
  end

  defp put_reply_to(metadata, id) when is_binary(id) and id != "",
    do: Map.put(metadata, "reply_to_message_id", id)

  defp put_reply_to(metadata, _id), do: metadata

  @quote_chars 500

  # Resolve a supplied parent only within the bound Space. Photon can omit
  # the parent of a native reply. Do not replace it with a recent Message.
  defp content(connect, message) do
    body = message["text"] || "[iMessage image]"

    case quote_line(connect, message["reply_to_message_id"]) do
      nil ->
        if transport(connect) == "photon",
          do: "[iMessage reply target: not supplied by Photon]\n" <> body,
          else: body

      line ->
        line <> "\n" <> body
    end
  end

  defp quote_line(%{"runtime_mode" => "photon"} = connect, id) when is_binary(id) and id != "" do
    chat = connect["managed_chat_id"]

    case PhotonIMessage.get_message(id) do
      {:ok, %{"space" => %{"id" => ^chat}} = parent} ->
        author =
          if get_in(parent, ["sentBy", "id"]) == connect["bot_user_id"],
            do: "Comma",
            else: "the user"

        quoted =
          case parent["content"] do
            %{"type" => "text", "text" => text} when is_binary(text) ->
              String.slice(text, 0, @quote_chars)

            %{"type" => type} when is_binary(type) ->
              "[#{type}]"

            _ ->
              "[content unavailable]"
          end

        "[Replying to message #{id} by #{author}: #{quoted}]"

      _ ->
        "[Replying to message #{id}: the original is unavailable]"
    end
  end

  defp quote_line(_connect, _id), do: nil

  defp attachments(connect, message) do
    message
    |> Map.get("attachments", [])
    |> List.wrap()
    |> Enum.take(10)
    |> Enum.flat_map(&attachment_metadata(connect, &1))
    |> Enum.filter(fn
      %{"attachment_id" => id, "content_type" => "image/" <> _} when is_binary(id) and id != "" ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn file ->
      name = file["name"] || "image"

      safe_name =
        name
        |> Path.basename()
        |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
        |> String.slice(0, 160)

      locator = [connect["connect_id"], message["message_id"], file["attachment_id"]]
      # This digest is only a collision-resistant file locator, not authorization.
      id = :crypto.hash(:sha256, Jason.encode!(locator)) |> Base.url_encode64(padding: false)

      %{
        "path" => "/imessage/attachments/#{id}-#{safe_name}",
        "file_name" => safe_name,
        "mime" => file["content_type"],
        "size" => file["size"],
        "to_blob" => fn agent_id -> download_image(connect, agent_id, file["attachment_id"]) end
      }
    end)
  end

  # A Photon event names only the attachment ID. Its type and name come from
  # Photon. An attachment whose metadata is unavailable is left out.
  defp attachment_metadata(connect, %{"attachment_id" => id} = file)
       when not is_map_key(file, "content_type") do
    with "photon" <- transport(connect),
         {:ok, metadata} <- PhotonIMessage.get_attachment(id) do
      [metadata]
    else
      _ -> []
    end
  end

  defp attachment_metadata(_connect, file) when is_map(file), do: [file]
  defp attachment_metadata(_connect, _file), do: []

  defp download_image(connect, agent_id, attachment_id) do
    case transport(connect) do
      "photon" -> PhotonIMessage.download_image(agent_id, attachment_id)
      "relay" -> IMessageRelay.download_image(agent_id, attachment_id)
    end
  end
end
