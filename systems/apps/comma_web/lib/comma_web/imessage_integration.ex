defmodule CommaWeb.IMessageIntegration do
  @moduledoc """
  Comma product iMessage private-chat binding and ingress.
  Consume intent, retire routes, prepare disabled, commit, then activate.
  Two transports carry the same binding: the Willow relay and Photon shared
  lines. Events carry `"transport" => "photon"` for Photon.
  See docs/messaging-voice.md for authorization and transport boundaries.
  """

  require Logger

  alias Comma.{IMessageLinks, Workspaces}
  alias SalixIM.{IMessageRelay, PhotonIMessage, ProviderConnects}
  alias SalixIM.Provider.IMessage

  def state(user, session, workspace_id) do
    with {:ok, workspace, link} <- IMessageLinks.get(user, session, workspace_id) do
      {:ok,
       %{
         "configured" => IMessageRelay.configured?() or PhotonIMessage.configured?(),
         "relay_configured" => IMessageRelay.configured?(),
         "photon_configured" => PhotonIMessage.configured?(),
         "shared_handle" => IMessageRelay.shared_handle(),
         "shared_identity" => IMessageRelay.shared_identity(),
         "workspace_id" => workspace["id"],
         "link" => IMessageLinks.public_link(link),
         "pending_claim" =>
           IMessageLinks.public_claim(IMessageLinks.get_active_claim(workspace_id)),
         "connection_active" => active?(workspace, link),
         "relay_online" => CommaWeb.IMessageRuntime.online?(),
         "photon_online" => CommaWeb.IMessagePhotonRuntime.online?()
       }}
    end
  end

  @doc """
  Starts a connection attempt. With a `handle` (phone number or Apple Account
  email), the attempt uses Photon: Comma registers the handle and assigns it a
  shared line. The person then sends the code to that line from that handle.
  Without a handle, the attempt is a relay claim command.
  """
  def start_connect(user, session, workspace_id, attrs \\ %{})

  def start_connect(user, session, workspace_id, %{"handle" => raw_handle}) do
    with :ok <- require_configured("photon"),
         {:ok, _workspace, _link} <- IMessageLinks.get(user, session, workspace_id),
         handle when is_binary(handle) <- PhotonIMessage.normalize_handle(raw_handle),
         {:ok, _user_id} <- PhotonIMessage.register_user(handle),
         {:ok, line} <- PhotonIMessage.assign_line(handle),
         {:ok, _workspace, claim} <-
           IMessageLinks.create_claim(user, session, workspace_id, %{
             transport: "photon",
             sender_handle: handle,
             line_handle: line["line_handle"],
             assignment_id: line["assignment_id"]
           }) do
      {:ok, IMessageLinks.public_claim(claim)}
    else
      nil -> {:error, :invalid_imessage_handle}
      {:error, {:photon, _status, _code}} -> {:error, :imessage_unavailable}
      other -> other
    end
  end

  def start_connect(user, session, workspace_id, _attrs) do
    with :ok <- require_configured("relay"),
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
        release_photon_assignment(link)
        {:ok, %{"disconnected" => removed?}}
      end
    end)
  end

  # Frees the shared-line seat when no binding or open attempt uses the handle.
  # A failed release leaves the seat to the receiver's assignment reconcile.
  defp release_photon_assignment(%{transport: "photon", assignment_id: id, sender_handle: handle})
       when is_binary(id) do
    unless MapSet.member?(IMessageLinks.photon_handles_in_use(), handle) do
      case PhotonIMessage.release_assignment(id) do
        :ok -> :ok
        _ -> Logger.warning("Photon line assignment release failed; reconcile will retry")
      end
    end

    :ok
  end

  defp release_photon_assignment(_link), do: :ok

  @doc """
  Authenticates a Photon webhook delivery and wakes the Photon receiver.
  The delivery is a wake-up signal only: the receiver reads received Messages
  from the Photon API, so the payload grants nothing.
  """
  def photon_webhook(raw_body, id, timestamp, signature) do
    with :ok <- require_configured("photon"),
         :ok <- PhotonIMessage.verify_webhook(raw_body, id, timestamp, signature) do
      CommaWeb.IMessagePhotonRuntime.poke()
    end
  end

  def handle_event(%{"type" => "message", "message" => message} = event) when is_map(message) do
    transport = IMessage.transport(event)
    message = Map.put(message, "transport", transport)

    with :ok <- require_configured(transport), :ok <- private_message(message) do
      case command(message) do
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

  defp command(%{"text" => text} = message) when is_binary(text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 4) do
      ["bridgebot", "connect", code] -> {:connect, code}
      ["bridgebot", "status"] -> :status
      ["bridgebot" | _] -> :help
      _ -> photon_code(message)
    end
  end

  defp command(_message), do: :message

  # A Photon attempt also accepts the bare code, but only from its handle.
  defp photon_code(%{"transport" => "photon", "text" => text, "sender_handle" => sender}) do
    if IMessageLinks.photon_claim_code?(sender, text),
      do: {:connect, String.trim(text)},
      else: :message
  end

  defp photon_code(_message), do: :message

  defp connect_message(message, code) do
    result =
      with {:ok, %{user: user, workspace: workspace, claim: claim}} <-
             IMessageLinks.take_claim(code, message["transport"], message["sender_handle"]) do
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
               Map.put(message, "assignment_id", proof.assignment_id),
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
           IMessage.current_transport?(connect) and
             IMessage.transport(connect) == link.transport and
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
  defp reply(%{"transport" => "photon"} = message, text) do
    _ = PhotonIMessage.send_text(message["agent_user_id"], message["chat_guid"], text)
    :ok
  end

  defp reply(message, text) do
    _ = IMessageRelay.send_text(message["sender_handle"], message["chat_guid"], text)
    :ok
  end

  defp require_configured("photon"),
    do: if(PhotonIMessage.configured?(), do: :ok, else: {:error, :imessage_unavailable})

  defp require_configured(_relay),
    do: if(IMessageRelay.configured?(), do: :ok, else: {:error, :imessage_unavailable})
end
