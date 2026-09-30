defmodule SalixIM.Provider.IMessage do
  @moduledoc "Private iMessage operations scoped to the immutable Comma-managed DM."

  alias SalixIM.{IMessageRelay, ProviderConnects, ProviderRecipientIdentity}
  alias SalixIM.Provider.Util

  def current_relay?(connect) do
    IMessageRelay.configured?() and connect["managed_by"] == "comma_product" and
      connect["relay_id"] == IMessageRelay.relay_id() and
      connect["bot_user_id"] == IMessageRelay.shared_handle()
  end

  def call(agent_id, connect, api, params) do
    with :ok <- Util.ensure_connected(connect),
         true <- current_relay?(connect),
         true <- params["chat_id"] == connect["managed_chat_id"] do
      send_message(agent_id, connect, api, params)
    else
      false -> {:error, "This iMessage connection can only address its bound private chat"}
      other -> other
    end
  end

  defp send_message(_agent_id, connect, "imessage.send_message", %{"text" => text})
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= 65_536 do
    IMessageRelay.send_text(connect["managed_peer_id"], connect["managed_chat_id"], text)
  end

  defp send_message(agent_id, connect, "imessage.send_image", params) do
    with {:ok, upload} <- Util.read_agent_upload(agent_id, params["path"]) do
      IMessageRelay.send_image(
        connect["managed_peer_id"],
        connect["managed_chat_id"],
        upload,
        params["caption"] || ""
      )
    end
  end

  defp send_message(_agent_id, _connect, _api, _params),
    do: {:error, "Unsupported iMessage operation or invalid message"}

  def inbound(connect, %{"message" => message} = event) do
    with {:ok, current} <-
           ProviderConnects.get_active_connect_by_id(
             connect["group_id"],
             connect["connect_id"],
             "imessage"
           ),
         true <- current_relay?(current),
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
          },
          current
        )

      # The Session actor owns permanent input dedupe. A relay replay carries
      # exactly the same stable source id, including after receiver restart.
      ProviderConnects.enqueue_group_router_im_provider_message(
        current["group_id"],
        message["text"] || "[iMessage image]",
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

  defp attachments(connect, message) do
    message
    |> Map.get("attachments", [])
    |> List.wrap()
    |> Enum.filter(fn
      %{"attachment_id" => id, "content_type" => "image/" <> _} when is_binary(id) and id != "" ->
        true

      _ ->
        false
    end)
    |> Enum.take(10)
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
        "to_blob" => fn agent_id ->
          IMessageRelay.download_image(agent_id, file["attachment_id"])
        end
      }
    end)
  end
end
