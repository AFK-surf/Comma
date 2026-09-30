defmodule CommaWeb.IMessageIntegration do
  @moduledoc """
  Comma product iMessage private-chat binding and ingress.
  Consume intent, retire routes, prepare disabled, commit, then activate.
  See docs/messaging-voice.md for authorization and transport boundaries.
  """

  alias Comma.{IMessageLinks, Workspaces}
  alias SalixIM.{IMessageRelay, ProviderConnects}
  alias SalixIM.Provider.IMessage

  def state(user, session, workspace_id) do
    with {:ok, workspace, link} <- IMessageLinks.get(user, session, workspace_id) do
      {:ok,
       %{
         "configured" => IMessageRelay.configured?(),
         "shared_handle" => IMessageRelay.shared_handle(),
         "shared_identity" => IMessageRelay.shared_identity(),
         "workspace_id" => workspace["id"],
         "link" => IMessageLinks.public_link(link),
         "pending_claim" =>
           IMessageLinks.public_claim(IMessageLinks.get_active_claim(workspace_id)),
         "connection_active" => active?(workspace, link),
         "relay_online" => CommaWeb.IMessageRuntime.online?()
       }}
    end
  end

  def start_connect(user, session, workspace_id) do
    with :ok <- require_configured(),
         {:ok, _workspace, claim} <- IMessageLinks.create_claim(user, session, workspace_id) do
      {:ok, IMessageLinks.public_claim(claim)}
    end
  end

  def cancel_connect(user, session, workspace_id, attrs),
    do: IMessageLinks.cancel_attempt(user, session, workspace_id, attrs)

  def disconnect(user, session, workspace_id) do
    IMessageLinks.with_lifecycle_lock(fn ->
      with {:ok, workspace, link} <- IMessageLinks.get(user, session, workspace_id),
           :ok <- retire_link(link, workspace),
           {:ok, _workspace, removed?} <- IMessageLinks.delete(user, session, workspace_id) do
        {:ok, %{"disconnected" => removed?}}
      end
    end)
  end

  def handle_event(%{"type" => "message", "message" => message} = event) when is_map(message) do
    with :ok <- require_configured(), :ok <- private_message(message) do
      case command(message["text"]) do
        {:connect, code} ->
          connect_message(message, code)

        :status ->
          status_message(message)

        :help ->
          reply(
            message,
            "Connect iMessage in Comma Settings → Channels, then send the connection command here. Command: bridgebot status. Manage or disconnect in Comma Settings → Channels."
          )

        :message ->
          deliver(event, message)
      end
    else
      {:error, :ignored} -> :ok
      other -> other
    end
  end

  def handle_event(_event), do: :ok

  defp private_message(message) when is_map(message) do
    if Map.get(message, "is_group", false) == false and
         Enum.all?(~w(sender_handle chat_guid message_id), fn key ->
           is_binary(message[key]) and String.trim(message[key]) != ""
         end) and message["is_from_me"] != true,
       do: :ok,
       else: {:error, :ignored}
  end

  defp command(text) when is_binary(text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 4) do
      ["bridgebot", "connect", code] -> {:connect, code}
      ["bridgebot", "status"] -> :status
      ["bridgebot" | _] -> :help
      _ -> :message
    end
  end

  defp command(_text), do: :message

  defp connect_message(message, code) do
    result =
      with {:ok, %{user: user, workspace: workspace, claim: claim}} <-
             IMessageLinks.take_claim(code) do
        link_identity(user, workspace, message, claim)
      end

    case result do
      {:ok, _link} ->
        reply(message, "iMessage is connected to Comma. Send a message here to get started.")

      _ ->
        reply(
          message,
          "Could not connect iMessage. Generate a new connection command in Comma Settings → Channels and try again."
        )
    end
  end

  defp link_identity(user, workspace, message, proof) do
    IMessageLinks.with_lifecycle_lock(fn ->
      with :ok <- IMessageLinks.validate_connection_attempt(user["id"], workspace["id"], proof),
           :ok <- retire_conflicting_sender(message["sender_handle"], workspace["id"]),
           :ok <- retire_link(IMessageLinks.get_link(workspace["id"]), workspace),
           {:ok, connect} <-
             ProviderConnects.ensure_managed_imessage_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               message
             ),
           {:ok, %{link: link}} <-
             IMessageLinks.put_link(
               user["id"],
               workspace["id"],
               message,
               connect["connect_id"],
               proof
             ),
           :ok <-
             ProviderConnects.activate_managed_imessage_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               connect["connect_id"]
             ) do
        {:ok, link}
      end
    end)
  end

  defp retire_conflicting_sender(sender, target_workspace_id) do
    case IMessageLinks.get_link_by_sender(sender) do
      %{workspace_id: workspace_id} = link when workspace_id != target_workspace_id ->
        with {:ok, workspace} <- Workspaces.get(workspace_id), do: retire_link(link, workspace)

      _ ->
        :ok
    end
  end

  defp retire_link(nil, _workspace), do: :ok

  defp retire_link(link, workspace) do
    case ProviderConnects.delete_im_connect(
           workspace["salix_tenant_id"],
           workspace["default_group_id"],
           link.connect_id
         ) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp deliver(event, message) do
    case IMessageLinks.resolve_sender(message["sender_handle"]) do
      {:ok, %{workspace: workspace, link: link}} ->
        case active_connect(workspace, link) do
          {:ok, connect} ->
            case IMessage.inbound(connect, event) do
              {:ok, _} ->
                :ok

              {:error, reason} when reason in [:not_found, :imessage_link_inconsistent] ->
                reply(message, "Reconnect iMessage in Comma Settings → Channels.")

              other ->
                other
            end

          {:error, reason} when reason in [:not_found, :imessage_link_inconsistent] ->
            reply(message, "Reconnect iMessage in Comma Settings → Channels.")

          other ->
            other
        end

      {:error, :imessage_not_linked} ->
        reply(message, "Connect iMessage in Comma Settings → Channels to chat with Comma here.")
    end
  end

  defp status_message(message) do
    case IMessageLinks.resolve_sender(message["sender_handle"]) do
      {:ok, %{workspace: workspace, link: link}} ->
        if link.chat_guid == message["chat_guid"] and active?(workspace, link),
          do: reply(message, "iMessage is connected to Comma."),
          else: reply(message, "Reconnect iMessage in Comma Settings → Channels.")

      _ ->
        reply(message, "This private chat is not connected to Comma.")
    end
  end

  defp active?(_workspace, nil), do: false
  defp active?(workspace, link), do: match?({:ok, _}, active_connect(workspace, link))

  defp active_connect(workspace, link) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             workspace["default_group_id"],
             link.connect_id,
             "imessage"
           ),
         true <-
           IMessage.current_relay?(connect) and
             connect["tenant_id"] == workspace["salix_tenant_id"] and
             connect["managed_peer_id"] == link.sender_handle and
             connect["managed_chat_id"] == link.chat_guid do
      {:ok, connect}
    else
      false -> {:error, :imessage_link_inconsistent}
      other -> other
    end
  end

  # Command acknowledgments are best effort, as in Telegram; replay must not
  # execute a successfully consumed binding command a second time.
  defp reply(message, text) do
    _ = IMessageRelay.send_text(message["sender_handle"], message["chat_guid"], text)
    :ok
  end

  defp require_configured,
    do: if(IMessageRelay.configured?(), do: :ok, else: {:error, :imessage_unavailable})
end
