defmodule SalixWeb.Dashboard.GroupLive.Show do
  @moduledoc """
  Agent group detail with tabs: Overview, OAuth bindings, Router messages, and
  IM connects. The active tab is driven by the `?tab=` param (patched links).
  """
  use SalixWeb.Dashboard, :live_view

  require Logger

  alias Salix.Control.{Groups, OAuthBindings}
  alias SalixAgent.Control, as: AgentControl
  alias SalixWeb.{OAuthFlow}
  alias SalixIM.{ConversationInput, ConversationServer}
  alias SalixIM.Conversations
  alias SalixIM.ProviderConnects
  alias SalixIM.RouterConversationInput
  alias SalixWeb.Dashboard.{Format, MessageContent}

  @tabs ~w(overview conversations oauth composio drive router im connectors api-keys voice signal)
  @tab_labels %{"api-keys" => "Inbound API"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Groups.get(id, socket.assigns.current_tenant) do
      {:ok, group} ->
        {:ok,
         assign(socket,
           active_nav: :groups,
           group_id: id,
           group: group,
           page_title: group["name"],
           providers: SalixStore.OAuth.Adapters.supported(),
           env_connect: nil,
           new_api_key: nil,
           new_voice_key: nil,
           voice_pending: nil,
           signal_claim: nil,
           selected_conversation_id: nil,
           selected_conversation: nil,
           conversation_messages: [],
           tab: "overview"
         )}

      {:error, _} ->
        {:ok,
         socket |> put_flash(:error, "Group not found.") |> push_navigate(to: "/dash/groups")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "overview"
    selected_conversation_id = if tab == "conversations", do: params["conversation_id"]

    {:noreply,
     socket
     |> assign(
       tab: tab,
       selected_conversation_id: selected_conversation_id,
       breadcrumbs: crumbs(socket, tab),
       env_connect: nil
     )
     |> load_tab(tab)}
  end

  defp crumbs(socket, tab) do
    [{"Agent Groups", "/dash/groups"}, {socket.assigns.group["name"], nil}] ++
      if(tab == "overview",
        do: [],
        else: [{Map.get(@tab_labels, tab, String.capitalize(tab)), nil}]
      )
  end

  # Inbound API keys (docs/product-features.md). The list is
  # the public projection; the plaintext of a freshly minted key lives only in
  # `new_api_key` until the operator dismisses it.
  defp load_tab(socket, "api-keys") do
    case Salix.Control.GroupApiKeys.list(socket.assigns.group_id, socket.assigns.current_tenant) do
      {:ok, keys} ->
        assign(socket, api_keys: keys, api_keys_error: nil)

      {:error, reason} ->
        assign(socket, api_keys: [], api_keys_error: inspect(reason))
    end
  end

  # Voice (docs/messaging-voice.md): verified caller numbers of the Group's
  # voice connect and its voice agent keys. The plaintext of a new voice key
  # lives only in `new_voice_key` until the operator dismisses it.
  defp load_tab(socket, "voice") do
    group_id = socket.assigns.group_id
    tenant_id = socket.assigns.current_tenant

    {status, status_error} =
      case Salix.Control.VoiceNumbers.status(group_id, tenant_id) do
        {:ok, status} -> {status, nil}
        {:error, reason} -> {nil, voice_error(reason)}
      end

    {keys, keys_error} =
      case Salix.Control.GroupApiKeys.list(group_id, tenant_id, "voice") do
        {:ok, keys} -> {keys, nil}
        {:error, reason} -> {[], inspect(reason)}
      end

    assign(socket,
      voice_status: status,
      voice_error: status_error,
      voice_keys: keys,
      voice_keys_error: keys_error
    )
  end

  # Signal (docs/messaging-voice.md): the peers bound to the Group's Signal
  # connect and pending claim codes. A new code lives only in `signal_claim`
  # until the operator dismisses it.
  defp load_tab(socket, "signal") do
    case Salix.Control.Signal.status(socket.assigns.group_id, socket.assigns.current_tenant) do
      {:ok, status} -> assign(socket, signal_status: status, signal_error: nil)
      {:error, reason} -> assign(socket, signal_status: nil, signal_error: signal_error(reason))
    end
  end

  defp load_tab(socket, "oauth"),
    do:
      assign(socket,
        bindings: OAuthBindings.list(socket.assigns.group_id),
        auth_url: nil
      )

  # The Composio tab reads live from the Composio API (settings permitting):
  # the group's connected accounts are Composio-side state keyed by the group
  # id as Composio user_id — there is no local mirror to list.
  defp load_tab(socket, "composio") do
    case Salix.Control.ComposioSettings.get(socket.assigns.current_tenant) do
      {:ok, settings} ->
        case composio_client().list_connected_accounts(settings, socket.assigns.group_id) do
          {:ok, items} ->
            assign(socket,
              composio_configured: true,
              composio_connections: items,
              composio_error: nil,
              composio_connect_url: nil
            )

          {:error, reason} ->
            assign(socket,
              composio_configured: true,
              composio_connections: [],
              composio_error: format_composio_error(reason),
              composio_connect_url: nil
            )
        end

      {:error, :not_configured} ->
        assign(socket,
          composio_configured: false,
          composio_connections: [],
          composio_error: nil,
          composio_connect_url: nil
        )
    end
  end

  # The Drive tab: the group's binding (redacted) and, on request, what the
  # control plane says about it.
  defp load_tab(socket, "drive") do
    assign(socket,
      drive_binding: Salix.Control.DriveBindings.view(socket.assigns.group_id),
      drive_settings: Salix.Control.DriveSettings.view(socket.assigns.current_tenant),
      drive_status: nil
    )
  end

  defp load_tab(socket, "router") do
    case SalixIM.RouterConversationProjection.list_group_router_messages(socket.assigns.group_id) do
      {:ok, messages} ->
        assign(socket, router_messages: messages, router_messages_error: nil)

      {:error, reason} ->
        assign(socket, router_messages: [], router_messages_error: inspect(reason))
    end
  end

  defp load_tab(socket, "conversations") do
    conversations =
      case Conversations.list_group_conversations(socket.assigns.group_id, limit: 100) do
        {:ok, %{"data" => list}} -> list
        _ -> []
      end

    selected_id = socket.assigns.selected_conversation_id

    {selected, messages, participants} =
      if selected_id in [nil, ""] do
        {nil, [], []}
      else
        with {:ok, conversation} <-
               Conversations.get_group_conversation(socket.assigns.group_id, selected_id),
             {:ok, %{"participants" => participants}} <-
               Conversations.list_group_conversation_participants(
                 socket.assigns.group_id,
                 selected_id,
                 limit: 100
               ),
             {:ok, messages} <-
               Conversations.list_group_conversation_messages(
                 socket.assigns.group_id,
                 selected_id,
                 limit: 500
               ) do
          {conversation, Enum.sort_by(messages, &(&1["created_at"] || 0)), participants}
        else
          _ -> {nil, [], []}
        end
      end

    assign(socket,
      conversations: conversations,
      selected_conversation: selected,
      selected_conversation_participants: participants,
      conversation_messages: messages
    )
  end

  defp load_tab(socket, "im"), do: assign(socket, im_connects: list_im(socket.assigns.group_id))

  defp load_tab(socket, "connectors"),
    do:
      assign(socket,
        environments:
          socket.assigns.current_tenant
          |> SalixEnv.Control.list_environments()
          |> group_environments(socket.assigns.group_id)
      )

  defp load_tab(socket, "overview") do
    assign(socket,
      group_agents:
        AgentControl.list(socket.assigns.current_tenant, group_id: socket.assigns.group_id)
    )
  end

  defp load_tab(socket, _), do: socket

  defp list_im(group_id) do
    case ProviderConnects.list_group_im_connects(group_id, nil) do
      {:ok, connects} -> connects
      _ -> []
    end
  end

  defp composio_client,
    do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)

  defp format_composio_error(reason) when is_binary(reason), do: reason
  defp format_composio_error(reason), do: inspect(reason)

  defp group_environments(environments, group_id) do
    Enum.filter(environments, &(&1["group_id"] == group_id))
  end

  # ---- OAuth events ----

  @impl true
  def handle_event("authorize", params, socket) do
    attrs = %{"alias" => params["alias"], "scopes" => params["scopes"]}

    case OAuthFlow.start_authorization(
           socket.assigns.current_tenant,
           socket.assigns.group_id,
           params["provider"],
           attrs
         ) do
      {:ok, %{"authorization_url" => url}} ->
        {:noreply, assign(socket, auth_url: url)}

      {:error, {_, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("update-alias", %{"binding" => bid, "alias" => alias_name}, socket) do
    case OAuthBindings.update(socket.assigns.group_id, bid, %{
           "alias" => alias_name
         }) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Alias updated.") |> load_tab("oauth")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("set-binding-enabled", %{"binding" => bid, "enabled" => enabled}, socket) do
    case OAuthBindings.update(socket.assigns.group_id, bid, %{
           "enabled" => enabled == "true"
         }) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Binding updated.") |> load_tab("oauth")}

      {:error, reason} ->
        Logger.warning("oauth_binding_enabled_update_failed reason=#{inspect(reason)}",
          group_id: socket.assigns.group_id,
          binding_id: bid
        )

        {:noreply, put_flash(socket, :error, "Binding update failed.")}
    end
  end

  def handle_event("revoke-binding", %{"binding" => bid}, socket) do
    case OAuthFlow.delete_binding(socket.assigns.current_tenant, socket.assigns.group_id, bid) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Binding revoked.") |> load_tab("oauth")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{inspect(reason)}")}
    end
  end

  # ---- Composio events ----

  def handle_event("composio-connect", %{"toolkit" => toolkit}, socket) do
    toolkit = toolkit |> to_string() |> String.trim() |> String.downcase()

    with {:ok, settings} <- Salix.Control.ComposioSettings.get(socket.assigns.current_tenant),
         {:ok, auth_config_id} <- composio_client().ensure_auth_config(settings, toolkit),
         {:ok, link} <-
           composio_client().create_connect_link(
             settings,
             auth_config_id,
             socket.assigns.group_id
           ) do
      {:noreply, assign(socket, composio_connect_url: link["redirect_url"])}
    else
      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, "Composio is not configured for this tenant.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Connect failed: #{format_composio_error(reason)}")}
    end
  end

  def handle_event("composio-disconnect", %{"account" => account_id}, socket) do
    with {:ok, settings} <- Salix.Control.ComposioSettings.get(socket.assigns.current_tenant),
         :ok <- composio_client().delete_connected_account(settings, account_id) do
      {:noreply, socket |> put_flash(:info, "Connection deleted.") |> load_tab("composio")}
    else
      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, "Composio is not configured for this tenant.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Disconnect failed: #{format_composio_error(reason)}")}
    end
  end

  # ---- Drive events ----

  # A blank api_key keeps the stored one ("leave blank to keep"); a binding
  # saved here is the operator's (`manual`), whoever wrote it before.
  def handle_event("drive-save", params, socket) do
    attrs = %{
      "org_slug" => params["org_slug"] || "",
      "network" => params["network"] || "",
      "space" => params["space"] || "",
      "base_url" => params["base_url"] || "",
      "source" => "manual",
      "enabled" => params["enabled"] == "true"
    }

    attrs =
      case String.trim(to_string(params["api_key"] || "")) do
        "" -> attrs
        api_key -> Map.put(attrs, "api_key", api_key)
      end

    case Salix.Control.DriveBindings.put(socket.assigns.group_id, attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Drive binding saved.") |> load_tab("drive")}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("drive-delete", _params, socket) do
    case Salix.Control.DriveBindings.delete(socket.assigns.group_id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Drive binding removed.") |> load_tab("drive")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("drive-probe", _params, socket) do
    {:ok, status} = Salix.Bindings.AgentDrive.status(socket.assigns.group_id)
    {:noreply, assign(socket, drive_status: status)}
  end

  # ---- Router events ----

  def handle_event("send-router", %{"content" => content}, socket) when content != "" do
    attrs = %{"content" => content, "client_request_id" => Format.request_id()}

    case RouterConversationInput.append_user_message(socket.assigns.group_id, attrs) do
      {:ok, _} -> {:noreply, load_tab(socket, "router")}
      {:error, {_, msg}} -> {:noreply, put_flash(socket, :error, msg)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Send failed: #{inspect(reason)}")}
    end
  end

  def handle_event("send-router", _params, socket), do: {:noreply, socket}

  # ---- Conversations ----

  def handle_event("create-conversation", params, socket) do
    attrs =
      params
      |> Map.take(["title"])
      |> Map.put_new("title", "")
      |> Map.put("participants", dashboard_conversation_participants(socket.assigns.group))

    case ConversationInput.create_group_conversation(socket.assigns.group_id, attrs) do
      {:ok, conversation} ->
        {:noreply,
         push_patch(socket,
           to:
             conversation_tab_path(
               socket.assigns.group_id,
               conversation["conversation_id"]
             )
         )}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "send-conversation",
        %{"conversation_id" => conversation_id, "text" => text},
        socket
      )
      when text != "" do
    attrs = %{
      "kind" => "message",
      "content" => [%{"type" => "text", "text" => text}],
      "client_request_id" => Format.request_id()
    }

    case ConversationServer.append_group_conversation_message(
           socket.assigns.group_id,
           conversation_id,
           attrs
         ) do
      {:ok, _} ->
        {:noreply, load_tab(socket, "conversations")}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Send failed: #{inspect(reason)}")}
    end
  end

  def handle_event("send-conversation", _params, socket), do: {:noreply, socket}

  # ---- Group ----

  def handle_event("set-router-agent", %{"router_agent_id" => agent_id}, socket) do
    value = if agent_id in [nil, ""], do: nil, else: agent_id

    case Groups.update(
           socket.assigns.group_id,
           %{"router_agent_id" => value},
           socket.assigns.current_tenant
         ) do
      {:ok, group} ->
        {:noreply,
         socket
         |> assign(group: group)
         |> put_flash(:info, "Router agent updated.")
         |> load_tab("overview")}

      {:error, {_, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle-memory-ask-worker", %{"enabled" => enabled}, socket) do
    enabled = enabled == "true"

    case Groups.update(
           socket.assigns.group_id,
           %{"memory_ask_worker_enabled" => enabled},
           socket.assigns.current_tenant
         ) do
      {:ok, group} ->
        {:noreply,
         socket
         |> assign(group: group)
         |> put_flash(
           :info,
           if(enabled,
             do: "Worker memory consultation enabled.",
             else: "Worker memory consultation disabled."
           )
         )}

      {:error, {_, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle-control-command-vfs", %{"enabled" => enabled}, socket) do
    enabled = enabled == "true"

    case Groups.update(
           socket.assigns.group_id,
           %{"control_command_vfs_enabled" => enabled},
           socket.assigns.current_tenant
         ) do
      {:ok, group} ->
        {:noreply,
         socket
         |> assign(group: group)
         |> put_flash(
           :info,
           if(enabled,
             do: "VFS control commands enabled.",
             else: "VFS control commands disabled."
           )
         )}

      {:error, {_, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-group", _params, socket) do
    case Groups.delete(socket.assigns.group_id, socket.assigns.current_tenant) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "Group deleted.") |> push_navigate(to: "/dash/groups")}

      {:ok, _} ->
        {:noreply, push_navigate(socket, to: "/dash/groups")}

      {:error, {:conflict, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  # ---- IM events ----

  def handle_event("im-" <> action, %{"id" => connect_id}, socket)
      when action in ~w(enable disable delete) do
    gid = socket.assigns.group_id

    result =
      case action do
        "enable" ->
          ProviderConnects.enable_im_connect(socket.assigns.current_tenant, gid, connect_id)

        "disable" ->
          ProviderConnects.disable_im_connect(socket.assigns.current_tenant, gid, connect_id)

        "delete" ->
          ProviderConnects.delete_im_connect(socket.assigns.current_tenant, gid, connect_id)
      end

    case result do
      :ok -> {:noreply, socket |> put_flash(:info, "Connect #{action}d.") |> load_tab("im")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  # ---- Connectors ----

  def handle_event("mint-connector-token", params, socket) do
    attrs =
      params
      |> Map.take(["name", "alias", "expires_in_seconds"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    case SalixEnv.ConnectorTokens.create_group_connector_token(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           attrs
         ) do
      {:ok, token} ->
        {:noreply,
         socket
         |> load_tab("connectors")
         |> assign(env_connect: token)
         |> put_flash(:info, "Connector credential minted. Copy it now; it is shown once.")}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mint failed: #{inspect(reason)}")}
    end
  end

  def handle_event("clear-connector-token", _params, socket) do
    {:noreply, assign(socket, env_connect: nil)}
  end

  # ---- Inbound API keys ----

  def handle_event("create-api-key", params, socket) do
    attrs =
      params
      |> Map.take(["name", "expires_at"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    case Salix.Control.GroupApiKeys.create(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           attrs,
           "salix_admin"
         ) do
      {:ok, key} ->
        {:noreply,
         socket
         |> load_tab("api-keys")
         |> assign(new_api_key: key)
         |> put_flash(:info, "Inbound API key created. Copy it now; it is shown once.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, api_key_error(reason))}
    end
  end

  def handle_event("update-api-key", %{"key_id" => key_id} = params, socket) do
    attrs = params |> Map.take(["name", "status"]) |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    case Salix.Control.GroupApiKeys.update(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           key_id,
           attrs
         ) do
      {:ok, _key} ->
        {:noreply, socket |> put_flash(:info, "Inbound API key updated.") |> load_tab("api-keys")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, api_key_error(reason))}
    end
  end

  def handle_event("delete-api-key", %{"key_id" => key_id}, socket) do
    case Salix.Control.GroupApiKeys.delete(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           key_id
         ) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Inbound API key deleted.") |> load_tab("api-keys")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, api_key_error(reason))}
    end
  end

  def handle_event("dismiss-api-key", _params, socket),
    do: {:noreply, assign(socket, new_api_key: nil)}

  # ---- Voice ----

  def handle_event("voice-verify-start", params, socket) do
    attrs = voice_attrs(params, ["e164", "line"])

    case Salix.Control.VoiceNumbers.verify_start(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           attrs
         ) do
      {:ok, pending} ->
        {:noreply,
         socket
         |> assign(voice_pending: pending)
         |> put_flash(:info, "Verification code sent to #{pending["e164"]}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, voice_error(reason))}
    end
  end

  def handle_event("voice-verify-check", params, socket) do
    attrs = voice_attrs(params, ["e164", "line", "code"])

    case Salix.Control.VoiceNumbers.verify_check(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           attrs
         ) do
      {:ok, _status} ->
        {:noreply,
         socket
         |> assign(voice_pending: nil)
         |> put_flash(:info, "Caller number #{attrs["e164"]} verified.")
         |> load_tab("voice")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, voice_error(reason))}
    end
  end

  def handle_event("voice-cancel-verify", _params, socket),
    do: {:noreply, assign(socket, voice_pending: nil)}

  def handle_event("voice-remove-number", %{"e164" => e164}, socket) do
    case Salix.Control.VoiceNumbers.remove_number(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           e164
         ) do
      {:ok, _status} ->
        {:noreply, socket |> put_flash(:info, "Caller number removed.") |> load_tab("voice")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, voice_error(reason))}
    end
  end

  def handle_event("voice-set-pin", params, socket) do
    attrs = %{"e164" => params["e164"], "pin" => params["pin"] || ""}

    case Salix.Control.VoiceNumbers.set_pin(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           attrs
         ) do
      {:ok, _status} ->
        message = if attrs["pin"] == "", do: "PIN cleared.", else: "PIN saved."
        {:noreply, socket |> put_flash(:info, message) |> load_tab("voice")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, voice_error(reason))}
    end
  end

  def handle_event("create-voice-key", params, socket) do
    attrs = voice_attrs(params, ["name", "expires_at"])

    case Salix.Control.GroupApiKeys.create(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           attrs,
           "salix_admin",
           "voice"
         ) do
      {:ok, key} ->
        {:noreply,
         socket
         |> load_tab("voice")
         |> assign(new_voice_key: key)
         |> put_flash(:info, "Voice API key created. Copy it now; it is shown once.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, api_key_error(reason))}
    end
  end

  def handle_event("update-voice-key", %{"key_id" => key_id} = params, socket) do
    attrs = voice_attrs(params, ["name", "status"])

    case Salix.Control.GroupApiKeys.update(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           key_id,
           attrs,
           "voice"
         ) do
      {:ok, _key} ->
        {:noreply, socket |> put_flash(:info, "Voice API key updated.") |> load_tab("voice")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, api_key_error(reason))}
    end
  end

  def handle_event("delete-voice-key", %{"key_id" => key_id}, socket) do
    case Salix.Control.GroupApiKeys.delete(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           key_id,
           "voice"
         ) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Voice API key deleted.") |> load_tab("voice")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, api_key_error(reason))}
    end
  end

  def handle_event("dismiss-voice-key", _params, socket),
    do: {:noreply, assign(socket, new_voice_key: nil)}

  # ---- Signal ----

  def handle_event("signal-start-claim", _params, socket) do
    case Salix.Control.Signal.start_claim(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           "salix_dashboard"
         ) do
      {:ok, status} ->
        {:noreply,
         socket
         |> assign(signal_status: status, signal_error: nil, signal_claim: status["claim"])}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, signal_error(reason))}
    end
  end

  def handle_event("signal-cancel-claim", %{"claim_id" => claim_id}, socket) do
    case Salix.Control.Signal.cancel_claim(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           claim_id
         ) do
      {:ok, status} -> {:noreply, assign(socket, signal_status: status, signal_claim: nil)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, signal_error(reason))}
    end
  end

  def handle_event("signal-remove-binding", %{"binding_id" => binding_id}, socket) do
    case Salix.Control.Signal.remove_binding(
           socket.assigns.group_id,
           socket.assigns.current_tenant,
           binding_id
         ) do
      {:ok, status} ->
        {:noreply,
         socket |> put_flash(:info, "Signal chat disconnected.") |> assign(signal_status: status)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, signal_error(reason))}
    end
  end

  def handle_event("dismiss-signal-claim", _params, socket),
    do: {:noreply, assign(socket, signal_claim: nil)}

  defp signal_error(:not_configured),
    do: "Signal has no number. Set the platform number on the Signal page."

  defp signal_error(reason) do
    {_status, error} = Salix.Control.Signal.http_error(reason)
    "Signal is unavailable: #{error}"
  end

  defp voice_attrs(params, fields) do
    params
    |> Map.take(fields)
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp voice_error({:bad_request, message}), do: message
  defp voice_error(:voice_number_in_use), do: "This number is already bound to another group."
  defp voice_error(:invalid_code), do: "The verification code is not correct or has expired."
  defp voice_error(:rate_limited), do: "Too many verification attempts. Try again later."

  defp voice_error(:not_configured),
    do: "Voice is not configured. Set Twilio and the platform lines on the Voice page."

  defp voice_error(:not_found), do: "Not found."
  defp voice_error({:unavailable, message}), do: "Unavailable: #{message}"
  defp voice_error(reason), do: "Failed: #{inspect(reason)}"

  defp voice_session_example(group_id, key) do
    urls = Salix.Control.VoiceNumbers.voice_urls(group_id)

    "export COMMA_VOICE_API_KEY=#{key}\n" <>
      "curl -H \"Authorization: Bearer $COMMA_VOICE_API_KEY\" #{urls["readiness_url"]}\n" <>
      "# Sessions: #{urls["sessions_url"]} (subprotocol comma.voice.v1)"
  end

  defp voice_pin_state(number) do
    cond do
      is_integer(number["pin_locked_until"]) -> "locked"
      number["pin_configured"] -> "set"
      true -> "none"
    end
  end

  defp api_key_error({:bad_request, message}), do: message
  defp api_key_error({:conflict, message}), do: message
  defp api_key_error(:not_found), do: "Inbound API key not found."
  defp api_key_error(reason), do: "Failed: #{inspect(reason)}"

  defp api_key_curl(group_id, key) do
    "curl -X POST #{Salix.App.RouterInbox.post_message_url(group_id)} \\\n" <>
      "  -H 'Authorization: Bearer #{key}' \\\n" <>
      "  -H 'Content-Type: application/json' \\\n" <>
      ~s|  -d '{"text": "Hello from an external service", "source_message_id": "example-1"}'|
  end

  defp api_key_time(nil), do: "—"

  defp api_key_time(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!() |> Format.time_ago()

  defp api_key_time(_other), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <h1 class="break-words text-xl font-semibold">{@group["name"]}</h1>
          <p class="mt-1 break-all font-mono text-xs text-neutral-500">{@group["group_id"]}</p>
        </div>
        <.button
          variant="danger"
          phx-click="delete-group"
          data-confirm="Delete this group?"
        >
          Delete group
        </.button>
      </div>

      <.tabs class="[&>nav]:flex-wrap [&>nav]:gap-y-0">
        <:tab label="Overview" patch={"/dash/groups/#{@group_id}"} active={@tab == "overview"} />
        <:tab
          label="Conversations"
          patch={"/dash/groups/#{@group_id}?tab=conversations"}
          active={@tab == "conversations"}
        />
        <:tab label="OAuth" patch={"/dash/groups/#{@group_id}?tab=oauth"} active={@tab == "oauth"} />
        <:tab label="Composio" patch={"/dash/groups/#{@group_id}?tab=composio"} active={@tab == "composio"} />
        <:tab label="Drive" patch={"/dash/groups/#{@group_id}?tab=drive"} active={@tab == "drive"} />
        <:tab label="Router" patch={"/dash/groups/#{@group_id}?tab=router"} active={@tab == "router"} />
        <:tab label="IM connects" patch={"/dash/groups/#{@group_id}?tab=im"} active={@tab == "im"} />
        <:tab
          label="Connectors"
          patch={"/dash/groups/#{@group_id}?tab=connectors"}
          active={@tab == "connectors"}
        />
        <:tab
          label="Inbound API"
          patch={"/dash/groups/#{@group_id}?tab=api-keys"}
          active={@tab == "api-keys"}
        />
        <:tab label="Voice" patch={"/dash/groups/#{@group_id}?tab=voice"} active={@tab == "voice"} />
        <:tab label="Signal" patch={"/dash/groups/#{@group_id}?tab=signal"} active={@tab == "signal"} />
      </.tabs>

      <div :if={@tab == "overview"} class="space-y-3">
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.kv label="Purpose">{@group["purpose"] || "—"}</.kv>
          <.kv label="Created">{Format.datetime(@group["created_at"])}</.kv>
          <.kv label="Router agent">{@group["router_agent_id"] || "—"}</.kv>
        </div>

        <.card>
          <:title>Router agent</:title>
          <p class="mb-3 text-xs text-neutral-500">
            The router agent receives inbound IM and bridge messages for this group.
          </p>
          <form id="router-agent-form" phx-submit="set-router-agent" class="flex flex-wrap items-end gap-2">
            <.select
              id="router_agent_id"
              name="router_agent_id"
              label="Agent"
              options={router_agent_options(@group_agents)}
              value={@group["router_agent_id"] || ""}
              class="w-80"
            />
            <.button type="submit" variant="primary">Save</.button>
          </form>
          <p :if={@group_agents == []} class="mt-2 text-xs text-neutral-500">
            This group has no agents yet. Create an agent before assigning a router.
          </p>
        </.card>

        <.card>
          <:title>Worker memory consultation</:title>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="max-w-2xl">
              <p class="text-sm text-neutral-700">
                Let the Router use <code class="font-mono text-xs">memory.ask_worker</code>
                to consult historical Worker Sessions in this group.
              </p>
              <p class="mt-1 text-xs text-neutral-500">
                Disabled by default. Changes apply when the Router builds its next tool list.
              </p>
            </div>
            <.toggle
              id="memory-ask-worker-toggle"
              name="memory_ask_worker_enabled"
              label={if @group["memory_ask_worker_enabled"] == true, do: "Enabled", else: "Disabled"}
              checked={@group["memory_ask_worker_enabled"] == true}
              phx-click="toggle-memory-ask-worker"
              phx-value-enabled={
                if @group["memory_ask_worker_enabled"] == true, do: "false", else: "true"
              }
            />
          </div>
        </.card>
        <.card>
          <:title>VFS control commands</:title>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="max-w-2xl">
              <p class="text-sm text-neutral-700">
                Allow IM senders who address the bot to use salix-command ls and cat
                to read the Router workspace into their chat.
              </p>
              <p class="mt-1 text-xs text-neutral-500">
                Disabled by default. Applies to this group only. Checked before each command runs.
              </p>
            </div>
            <.toggle
              id="control-command-vfs-toggle"
              name="control_command_vfs_enabled"
              label={if @group["control_command_vfs_enabled"] == true, do: "Enabled", else: "Disabled"}
              checked={@group["control_command_vfs_enabled"] == true}
              phx-click="toggle-control-command-vfs"
              phx-value-enabled={
                if @group["control_command_vfs_enabled"] == true, do: "false", else: "true"
              }
            />
          </div>
        </.card>
      </div>

      <div :if={@tab == "conversations"} class="grid grid-cols-1 gap-4 xl:grid-cols-[24rem_1fr]">
        <div class="space-y-4">
          <.card>
            <:title>New conversation</:title>
            <form id="group-conversation-form" phx-submit="create-conversation" class="flex items-end gap-2">
              <.input name="title" label="Title" placeholder="Optional title" class="flex-1" />
              <.button type="submit" variant="primary">Create</.button>
            </form>
          </.card>

          <.card>
            <:title>Conversations</:title>
            <div :if={@conversations != []} class="divide-y divide-neutral-100">
              <.link
                :for={conversation <- @conversations}
                patch={conversation_tab_path(@group_id, conversation["conversation_id"])}
                class={[
                  "block px-1 py-2 hover:bg-neutral-50",
                  @selected_conversation_id == conversation["conversation_id"] && "bg-brand-50"
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="truncate text-sm font-medium text-neutral-800">
                    {conversation_title(conversation)}
                  </span>
                  <span class="shrink-0 text-xs text-neutral-500">
                    {conversation["message_count"] || 0}
                  </span>
                </div>
                <div class="mt-1 flex items-center gap-2 text-xs text-neutral-500">
                  <span>{conversation["kind"]}</span>
                  <span>·</span>
                  <span>{Format.time_ago(iso(conversation["updated_at"]))}</span>
                </div>
              </.link>
            </div>
            <.empty_state :if={@conversations == []} icon="chat" title="No conversations" />
          </.card>
        </div>

        <.card :if={@selected_conversation}>
          <:title>{conversation_title(@selected_conversation)}</:title>

          <div class="mb-4 grid grid-cols-1 gap-3 md:grid-cols-2">
            <.kv label="Conversation ID">
              <span class="font-mono text-xs">{@selected_conversation["conversation_id"]}</span>
            </.kv>
            <.kv label="Kind">{@selected_conversation["kind"]}</.kv>
          </div>

          <div class="mb-4">
            <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-neutral-500">
              Participants
            </h3>
            <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
              <div
                :for={participant <- @selected_conversation_participants}
                class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2"
              >
                <div class="flex items-center justify-between gap-2">
                  <div class="min-w-0">
                    <div class="truncate text-sm font-medium text-neutral-800">
                      {participant_label(participant)}
                    </div>
                    <div class="mt-0.5 font-mono text-[11px] text-neutral-500">
                      {participant["participant_id"]}
                    </div>
                  </div>
                  <.status_pill status={participant["state"] || "active"} />
                </div>
                <div class="mt-2 flex flex-wrap items-center gap-2 text-xs">
                  <.link
                    :if={participant_agent_path(participant)}
                    navigate={participant_agent_path(participant)}
                    class="text-brand-600 hover:underline"
                  >
                    Agent
                  </.link>
                  <.link
                    :if={participant_session_path(participant)}
                    navigate={participant_session_path(participant)}
                    class="text-brand-600 hover:underline"
                  >
                    Session
                  </.link>
                  <span :if={!participant_session_path(participant)} class="text-neutral-500">
                    No session recorded
                  </span>
                </div>
              </div>
            </div>
          </div>

          <div
            id="conversation-messages"
            class="mb-3 max-h-[32rem] space-y-3 overflow-y-auto rounded-md border border-neutral-200 bg-neutral-50 p-3"
          >
            <div
              :for={message <- @conversation_messages}
              class={[
                "rounded-md border px-3 py-2",
                message_user?(message) && "border-brand-200 bg-brand-50",
                !message_user?(message) && "border-neutral-200 bg-white"
              ]}
            >
              <div class="mb-1 flex items-center justify-between gap-2">
                <span class="text-[11px] font-medium uppercase tracking-wide text-neutral-400">
                  {message_actor(message)}
                </span>
                <span class="text-[11px] text-neutral-400">{Format.timestamp(iso(message["created_at"]))}</span>
              </div>
              <.markdown text={MessageContent.text(message["content"])} />
            </div>
            <p :if={@conversation_messages == []} class="py-4 text-center text-sm text-neutral-400">
              No messages yet.
            </p>
          </div>

          <form phx-submit="send-conversation" class="flex items-end gap-2">
            <input type="hidden" name="conversation_id" value={@selected_conversation["conversation_id"]} />
            <.input name="text" placeholder="Message this conversation" class="flex-1" />
            <.button type="submit" variant="primary">Send</.button>
          </form>
        </.card>

        <.card :if={!@selected_conversation}>
          <:title>Select a conversation</:title>
          <p class="text-sm text-neutral-500">
            Open a group conversation to inspect messages, participants, and any participant-linked runtime sessions.
          </p>
        </.card>
      </div>

      <div :if={@tab == "oauth"} class="space-y-4">
        <.card>
          <:title>Authorize a provider</:title>
          <form phx-submit="authorize" class="flex flex-wrap items-end gap-2">
            <.select name="provider" label="Provider" options={Enum.map(@providers, &{&1, &1})} class="w-40" />
            <.input name="alias" label="Alias" placeholder="default" class="w-40" />
            <.input name="scopes" label="Scopes (space-sep)" class="w-64" />
            <.button type="submit" variant="primary">Authorize</.button>
          </form>
          <div :if={@auth_url} class="mt-3 rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-sm">
            <p class="text-xs font-medium text-brand-800">Open this URL to complete authorization:</p>
            <a href={@auth_url} target="_blank" class="break-all text-brand-700 underline">{@auth_url}</a>
          </div>
        </.card>

        <.table :if={@bindings != []} id="bindings" rows={@bindings}>
          <:col :let={b} label="Provider">{b["provider"]}</:col>
          <:col :let={b} label="Alias">
            <form phx-submit="update-alias" class="flex items-center gap-1">
              <input type="hidden" name="binding" value={b["binding_id"]} />
              <input
                name="alias"
                value={b["alias"]}
                class="h-7 w-28 rounded-md border border-neutral-300 px-2 text-xs"
              />
              <.button size="sm" type="submit">Save</.button>
            </form>
          </:col>
          <:col :let={b} label="Account">{b["provider_account_name"] || "—"}</:col>
          <:col :let={b} label="Status"><.status_pill status={b["status"]} /></:col>
          <:action :let={b}>
            <.button
              :if={Map.get(b, "enabled", true) != false}
              size="sm"
              phx-click="set-binding-enabled"
              phx-value-binding={b["binding_id"]}
              phx-value-enabled="false"
            >
              Disable
            </.button>
            <.button
              :if={Map.get(b, "enabled", true) == false}
              size="sm"
              variant="primary"
              phx-click="set-binding-enabled"
              phx-value-binding={b["binding_id"]}
              phx-value-enabled="true"
            >
              Enable
            </.button>
            <.button
              size="sm"
              variant="danger"
              phx-click="revoke-binding"
              phx-value-binding={b["binding_id"]}
              data-confirm="Revoke this binding?"
            >
              Revoke
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@bindings == []} icon="key" title="No OAuth bindings" />
      </div>

      <div :if={@tab == "drive"} class="space-y-4">
        <.card>
          <:title>Drive binding</:title>
          <:actions>
            <.badge :if={@drive_binding["source"] == "comma"} color="brand">comma</.badge>
            <.badge color={if @drive_binding["configured"], do: "green", else: "neutral"}>
              {if @drive_binding["configured"], do: "configured", else: "not configured"}
            </.badge>
          </:actions>
          <p class="text-sm text-neutral-500">
            The Synchronicity org, network and space this group's agents reach at
            <code>/drive/...</code>, and the org API key (member role) they reach it with.
            The key is write-only and never shown back.
          </p>
          <p :if={@drive_binding["source"] == "comma"} class="text-xs text-neutral-500">
            Comma created this binding for its Workspace. Saving here makes it an operator-managed
            binding; Comma will not replace it afterwards.
          </p>
          <p
            :if={@drive_binding["retired_key_ids"] != [] and @drive_binding["source"] == "comma"}
            class="text-xs text-amber-700"
          >
            Earlier keys not yet confirmed revoked on the control plane; Comma retries on its next
            convergence, and saving here stops that: {Enum.join(@drive_binding["retired_key_ids"], ", ")}
          </p>
          <p
            :if={@drive_binding["retired_key_ids"] != [] and @drive_binding["source"] != "comma"}
            class="text-xs text-amber-700"
          >
            Earlier keys not confirmed revoked on the control plane. Comma does not retry keys of an
            operator-managed binding: revoke them in the Synchronicity dashboard (Settings → API keys):
            {Enum.join(@drive_binding["retired_key_ids"], ", ")}
          </p>
          <p :if={@drive_settings["source"] == "none" and @drive_binding["base_url"] == ""} class="text-xs text-amber-700">
            No control plane origin is configured. Name one below, or on the
            <.link navigate="/dash/drive" class="text-brand-700 underline">Drive settings page</.link>.
          </p>
          <form id="drive-binding-form" phx-submit="drive-save" class="space-y-3">
            <.input name="org_slug" label="Org slug" value={@drive_binding["org_slug"]} placeholder="acme" />
            <.input name="network" label="Network" value={@drive_binding["network"]} placeholder="default" />
            <.input name="space" label="Space" value={@drive_binding["space"]} placeholder="comma-drive" />
            <.input
              type="password"
              name="api_key"
              label="Org API key"
              placeholder={if @drive_binding["api_key_configured"], do: "•••••• (leave blank to keep)", else: "synch_…"}
            />
            <.input
              name="base_url"
              label="Control plane origin (optional)"
              value={@drive_binding["base_url"]}
              placeholder={@drive_settings["base_url"] || "https://sync.example.com"}
            />
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="enabled" value="false" />
              <input type="checkbox" name="enabled" value="true" checked={@drive_binding["enabled"] or not @drive_binding["api_key_configured"]} />
              Enabled
            </label>
            <div class="flex justify-between">
              <.button
                type="button"
                variant="danger"
                size="sm"
                phx-click="drive-delete"
                data-confirm="Remove this group's Drive binding?"
              >
                Remove
              </.button>
              <div class="flex gap-2">
                <.button type="button" size="sm" phx-click="drive-probe">Check</.button>
                <.button type="submit" variant="primary" size="sm">Save</.button>
              </div>
            </div>
          </form>
        </.card>

        <.card :if={@drive_status}>
          <:title>Control plane says</:title>
          <:actions>
            <.badge color={if @drive_status.available, do: "green", else: "neutral"}>
              {if @drive_status.available, do: "readable", else: "unavailable"}
            </.badge>
            <.badge color={if @drive_status.writable, do: "green", else: "neutral"}>
              {if @drive_status.writable, do: "writable", else: "read-only"}
            </.badge>
          </:actions>
          <p class="text-sm text-neutral-600">{@drive_status.detail}</p>
        </.card>
      </div>

      <div :if={@tab == "composio"} class="space-y-4">
        <.card :if={!@composio_configured}>
          <:title>Composio is not configured</:title>
          <p class="text-sm text-neutral-500">
            Add a Composio API key on the
            <.link navigate="/dash/composio" class="text-brand-700 underline">Composio settings page</.link>
            to let this group connect toolkits and call them directly.
          </p>
        </.card>

        <.card :if={@composio_configured}>
          <:title>Connect a toolkit</:title>
          <form phx-submit="composio-connect" class="flex flex-wrap items-end gap-2">
            <.input name="toolkit" label="Toolkit slug" placeholder="gmail, googlecalendar, notion, …" class="w-64" />
            <.button type="submit" variant="primary">Connect</.button>
          </form>
          <div
            :if={@composio_connect_url}
            class="mt-3 rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-sm"
          >
            <p class="text-xs font-medium text-brand-800">Open this URL to complete the connection:</p>
            <a href={@composio_connect_url} target="_blank" class="break-all text-brand-700 underline">
              {@composio_connect_url}
            </a>
          </div>
        </.card>

        <.card :if={@composio_configured && @composio_error}>
          <:title>Composio unavailable</:title>
          <p class="text-sm text-red-600">{@composio_error}</p>
        </.card>

        <.table
          :if={@composio_configured && @composio_connections != []}
          id="composio-connections"
          rows={@composio_connections}
        >
          <:col :let={c} label="Toolkit">{get_in(c, ["toolkit", "slug"]) || "—"}</:col>
          <:col :let={c} label="Account">{c["id"]}</:col>
          <:col :let={c} label="Status"><.status_pill status={c["status"]} /></:col>
          <:action :let={c}>
            <.button
              size="sm"
              variant="danger"
              phx-click="composio-disconnect"
              phx-value-account={c["id"]}
              data-confirm="Delete this Composio connection?"
            >
              Disconnect
            </.button>
          </:action>
        </.table>
        <.empty_state
          :if={@composio_configured && @composio_error == nil && @composio_connections == []}
          icon="bolt"
          title="No Composio connections"
        />
      </div>

      <div :if={@tab == "router"} class="space-y-4">
        <.card>
          <:title>Send router message</:title>
          <form phx-submit="send-router" class="flex items-end gap-2">
            <.input name="content" placeholder="Message to router agent" class="flex-1" />
            <.button type="submit" variant="primary">Send</.button>
          </form>
        </.card>
        <.table :if={@router_messages != []} id="router-msgs" rows={@router_messages}>
          <:col :let={m} label="Actor">{m["actor_type"] || m["role"] || "—"}</:col>
          <:col :let={m} label="Content">{MessageContent.preview(m["content"])}</:col>
          <:col :let={m} label="At">{Format.time_ago(m["created_at"])}</:col>
        </.table>
        <.empty_state :if={@router_messages == []} icon="chat" title="No router messages" />
      </div>

      <div :if={@tab == "im"} class="space-y-4">
        <.table :if={@im_connects != []} id="im-connects" rows={@im_connects}>
          <:col :let={c} label="Provider">{c["provider"]}</:col>
          <:col :let={c} label="Connect ID"><span class="font-mono text-xs">{Format.short_id(c["connect_id"] || c["id"])}</span></:col>
          <:col :let={c} label="Status"><.status_pill status={c["status"] || (if c["enabled"] == false, do: "disabled", else: "enabled")} /></:col>
          <:action :let={c}>
            <.button :if={c["provider"] == "slack"} size="sm" navigate={"/dash/groups/#{@group_id}/slack/#{c["connect_id"]}/commands"}>Commands</.button>
            <.button size="sm" phx-click="im-enable" phx-value-id={c["connect_id"] || c["id"]}>Enable</.button>
            <.button size="sm" phx-click="im-disable" phx-value-id={c["connect_id"] || c["id"]}>Disable</.button>
            <.button
              size="sm"
              variant="danger"
              phx-click="im-delete"
              phx-value-id={c["connect_id"] || c["id"]}
              data-confirm="Delete this IM connect?"
            >
              Delete
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@im_connects == []} icon="chat" title="No IM connects" />
      </div>

      <div :if={@tab == "connectors"} class="space-y-4">
        <.card>
          <:title>Mint connector credential</:title>
          <form
            id="group-connector-token-form"
            phx-submit="mint-connector-token"
            class="flex flex-wrap items-end gap-2"
          >
            <.input name="name" label="Name" placeholder="Mac Studio" class="w-56" />
            <.input name="alias" label="Alias" placeholder="studio" class="w-40" />
            <.button type="submit" variant="primary">Mint connector credential</.button>
          </form>
        </.card>

        <.card :if={@env_connect}>
          <:title>Connect a device</:title>
          <p class="mb-3 text-xs text-amber-700">
            This connector credential is shown only once. Copy it now.
          </p>
          <div class="space-y-3">
            <div>
              <p class="mb-1 text-xs font-medium text-neutral-600">Connect command</p>
              <pre class="overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">salix-connect --server {@env_connect["server"]} --connector-token {@env_connect["token"]}</pre>
            </div>
            <div>
              <p class="mb-1 text-xs font-medium text-neutral-600">Environment variables</p>
              <pre class="overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">{env_vars(@env_connect)}</pre>
            </div>
            <div>
              <p class="mb-1 text-xs font-medium text-neutral-600">Connector credential</p>
              <pre class="overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">{@env_connect["token"]}</pre>
            </div>
          </div>
          <div class="mt-4 flex justify-end">
            <.button size="sm" phx-click="clear-connector-token">Done</.button>
          </div>
        </.card>

        <.table :if={@environments != []} id="group-environments" rows={@environments}>
          <:col :let={e} label="Name">{e["name"]}</:col>
          <:col :let={e} label="Device"><span class="font-mono text-xs">{e["device_id"]}</span></:col>
          <:col :let={e} label="Host">{env_host_label(e)}</:col>
          <:col :let={e} label="OS / Arch">{env_os_arch(e)}</:col>
          <:col :let={e} label="Status"><.status_pill status={e["status"]} /></:col>
          <:col :let={e} label="Connected">{Format.time_ago(env_iso(e["connected_at"]))}</:col>
          <:action :let={e}>
            <.button size="sm" navigate={"/dash/environments/#{e["group_id"]}/#{e["device_id"]}"}>Open</.button>
          </:action>
        </.table>
        <.empty_state :if={@environments == []} icon="bolt" title="No devices" />
      </div>

      <div :if={@tab == "api-keys"} class="space-y-4">
        <.card>
          <:title>Create inbound API key</:title>
          <p class="mb-3 text-xs text-neutral-500">
            An inbound API key lets an external service post a message to this group's Router.
            It can send messages and nothing else. Keys created here act as <code>system</code>
            under information-flow checking.
          </p>
          <form id="group-api-key-form" phx-submit="create-api-key" class="flex flex-wrap items-end gap-2">
            <.input name="name" label="Name" placeholder="Zendesk" class="w-56" />
            <.input name="expires_at" label="Expires (ISO 8601, optional)" placeholder="2027-01-01T00:00:00Z" class="w-64" />
            <.button type="submit" variant="primary">Create key</.button>
          </form>
        </.card>

        <.card :if={@new_api_key}>
          <:title>New key: {@new_api_key["name"]}</:title>
          <p class="mb-3 text-xs text-amber-700">
            This key is shown only once. Copy it now.
          </p>
          <div class="space-y-3">
            <div>
              <p class="mb-1 text-xs font-medium text-neutral-600">Key</p>
              <pre id="new-api-key-value" class="overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">{@new_api_key["key"]}</pre>
            </div>
            <div>
              <p class="mb-1 text-xs font-medium text-neutral-600">Example</p>
              <pre class="overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">{api_key_curl(@group_id, @new_api_key["key"])}</pre>
            </div>
          </div>
          <div class="mt-4 flex justify-end">
            <.button size="sm" phx-click="dismiss-api-key">Done</.button>
          </div>
        </.card>

        <p :if={@api_keys_error} class="text-xs text-red-700">
          Inbound API keys are unavailable: {@api_keys_error}
        </p>

        <.table :if={@api_keys != []} id="group-api-keys" rows={@api_keys}>
          <:col :let={k} label="Name">{k["name"]}</:col>
          <:col :let={k} label="Prefix"><span class="font-mono text-xs">{k["prefix"]}…</span></:col>
          <:col :let={k} label="Status"><.status_pill status={k["status"]} /></:col>
          <:col :let={k} label="Created by">{k["created_by"]}</:col>
          <:col :let={k} label="Created">{api_key_time(k["created_at"])}</:col>
          <:col :let={k} label="Last used">{api_key_time(k["last_used_at"])}</:col>
          <:col :let={k} label="Expires">{api_key_time(k["expires_at"])}</:col>
          <:action :let={k}>
            <form phx-submit="update-api-key" class="inline-flex items-center gap-1">
              <input type="hidden" name="key_id" value={k["key_id"]} />
              <.input name="name" value={k["name"]} class="w-36" />
              <.button size="sm" type="submit">Rename</.button>
            </form>
            <.button
              :if={k["status"] == "active"}
              size="sm"
              phx-click="update-api-key"
              phx-value-key_id={k["key_id"]}
              phx-value-status="disabled"
            >
              Disable
            </.button>
            <.button
              :if={k["status"] != "active"}
              size="sm"
              phx-click="update-api-key"
              phx-value-key_id={k["key_id"]}
              phx-value-status="active"
            >
              Enable
            </.button>
            <.button
              size="sm"
              variant="danger"
              phx-click="delete-api-key"
              phx-value-key_id={k["key_id"]}
              data-confirm="Delete this inbound API key? Callers using it will be refused."
            >
              Delete
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@api_keys == [] and is_nil(@api_keys_error)} icon="key" title="No inbound API keys" />
      </div>

      <div :if={@tab == "voice"} class="space-y-4">
        <p :if={@voice_error} class="text-xs text-red-700">Voice is unavailable: {@voice_error}</p>

        <.card :if={@voice_status}>
          <:title>Phone callers</:title>
          <:actions>
            <.badge color={if @voice_status["readiness"]["ready"], do: "green", else: "neutral"}>
              {if @voice_status["readiness"]["ready"],
                do: "ready",
                else: "not ready: #{@voice_status["readiness"]["reason"]}"}
            </.badge>
          </:actions>
          <p class="mb-3 text-xs text-neutral-500">
            A verified caller number may call a platform line ({Enum.join(@voice_status["lines"], ", ")})
            and reach this group's Router. A caller without full carrier attestation must enter the
            number's PIN.
          </p>
          <form
            :if={is_nil(@voice_pending)}
            id="voice-verify-start-form"
            phx-submit="voice-verify-start"
            class="flex flex-wrap items-end gap-2"
          >
            <.input name="e164" label="Caller number (E.164)" placeholder="+15551234567" class="w-56" />
            <.input
              :if={length(@voice_status["lines"]) > 1}
              name="line"
              label="Platform line"
              placeholder={List.first(@voice_status["lines"])}
              class="w-48"
            />
            <.button type="submit" variant="primary">Send code</.button>
          </form>
          <form
            :if={@voice_pending}
            id="voice-verify-check-form"
            phx-submit="voice-verify-check"
            class="flex flex-wrap items-end gap-2"
          >
            <input type="hidden" name="e164" value={@voice_pending["e164"]} />
            <input type="hidden" name="line" value={@voice_pending["line"]} />
            <.input name="code" label={"Code sent to #{@voice_pending["e164"]}"} class="w-48" />
            <.button type="submit" variant="primary">Verify</.button>
            <.button type="button" phx-click="voice-cancel-verify">Cancel</.button>
          </form>
        </.card>

        <.table :if={@voice_status && @voice_status["numbers"] != []} id="voice-numbers" rows={@voice_status["numbers"]}>
          <:col :let={n} label="Number"><span class="font-mono text-xs">{n["e164"]}</span></:col>
          <:col :let={n} label="Line"><span class="font-mono text-xs">{n["line"]}</span></:col>
          <:col :let={n} label="PIN">{voice_pin_state(n)}</:col>
          <:col :let={n} label="Verified">{api_key_time(n["verified_at"] && div(n["verified_at"], 1000))}</:col>
          <:action :let={n}>
            <form id={"voice-pin-#{n["line"]}-#{n["e164"]}"} phx-submit="voice-set-pin" class="inline-flex items-center gap-1">
              <input type="hidden" name="e164" value={n["e164"]} />
              <.input type="password" name="pin" placeholder="4-8 digits" class="w-28" />
              <.button size="sm" type="submit">Set PIN</.button>
            </form>
            <.button
              size="sm"
              variant="danger"
              phx-click="voice-remove-number"
              phx-value-e164={n["e164"]}
              data-confirm="Remove this caller number? Calls from it will be refused."
            >
              Remove
            </.button>
          </:action>
        </.table>
        <.empty_state
          :if={@voice_status && @voice_status["numbers"] == []}
          icon="chat"
          title="No verified caller numbers"
        />

        <.card>
          <:title>Create voice API key</:title>
          <p class="mb-3 text-xs text-neutral-500">
            A voice API key opens live voice sessions (<code>comma.voice.v1</code>) with this group's
            Router and nothing else. Sessions spend model time.
          </p>
          <form id="voice-key-form" phx-submit="create-voice-key" class="flex flex-wrap items-end gap-2">
            <.input name="name" label="Name" placeholder="Kiosk" class="w-56" />
            <.input name="expires_at" label="Expires (ISO 8601, optional)" placeholder="2027-01-01T00:00:00Z" class="w-64" />
            <.button type="submit" variant="primary">Create key</.button>
          </form>
        </.card>

        <.card :if={@new_voice_key}>
          <:title>New voice key: {@new_voice_key["name"]}</:title>
          <p class="mb-3 text-xs text-amber-700">This key is shown only once. Copy it now.</p>
          <pre id="new-voice-key-value" class="overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">{@new_voice_key["key"]}</pre>
          <pre class="mt-3 overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs text-neutral-800">{voice_session_example(@group_id, @new_voice_key["key"])}</pre>
          <div class="mt-4 flex justify-end">
            <.button size="sm" phx-click="dismiss-voice-key">Done</.button>
          </div>
        </.card>

        <p :if={@voice_keys_error} class="text-xs text-red-700">
          Voice API keys are unavailable: {@voice_keys_error}
        </p>

        <.table :if={@voice_keys != []} id="voice-keys" rows={@voice_keys}>
          <:col :let={k} label="Name">{k["name"]}</:col>
          <:col :let={k} label="Prefix"><span class="font-mono text-xs">{k["prefix"]}…</span></:col>
          <:col :let={k} label="Status"><.status_pill status={k["status"]} /></:col>
          <:col :let={k} label="Created by">{k["created_by"]}</:col>
          <:col :let={k} label="Last used">{api_key_time(k["last_used_at"])}</:col>
          <:col :let={k} label="Expires">{api_key_time(k["expires_at"])}</:col>
          <:action :let={k}>
            <form id={"voice-key-rename-#{k["key_id"]}"} phx-submit="update-voice-key" class="inline-flex items-center gap-1">
              <input type="hidden" name="key_id" value={k["key_id"]} />
              <.input name="name" value={k["name"]} class="w-36" />
              <.button size="sm" type="submit">Rename</.button>
            </form>
            <.button
              :if={k["status"] == "active"}
              size="sm"
              phx-click="update-voice-key"
              phx-value-key_id={k["key_id"]}
              phx-value-status="disabled"
            >
              Disable
            </.button>
            <.button
              :if={k["status"] != "active"}
              size="sm"
              phx-click="update-voice-key"
              phx-value-key_id={k["key_id"]}
              phx-value-status="active"
            >
              Enable
            </.button>
            <.button
              size="sm"
              variant="danger"
              phx-click="delete-voice-key"
              phx-value-key_id={k["key_id"]}
              data-confirm="Delete this voice API key? Live sessions on it end now."
            >
              Delete
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@voice_keys == [] and is_nil(@voice_keys_error)} icon="key" title="No voice API keys" />
      </div>

      <div :if={@tab == "signal"} class="space-y-4">
        <p :if={@signal_error} class="text-xs text-red-700">{@signal_error}</p>

        <.card :if={@signal_status}>
          <:title>Signal chats</:title>
          <:actions>
            <.button
              id="signal-start-claim"
              size="sm"
              variant="primary"
              phx-click="signal-start-claim"
              disabled={is_nil(@signal_status["account"])}
            >
              New connection code
            </.button>
          </:actions>
          <p class="mb-3 text-xs text-neutral-500">
            A person or a Signal group connects by sending a connection code to
            <span class="font-mono">{(@signal_status["account"] || %{})["e164"] || "no number"}</span>.
            Messages and calls from connected chats reach this group's Router.
            Codes expire after 10 minutes and work once.
          </p>
          <div
            :if={@signal_claim}
            id="signal-claim"
            class="mb-3 flex items-center justify-between gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2"
          >
            <div class="min-w-0">
              <p class="text-xs font-medium text-amber-800">
                Send this message on Signal to {@signal_claim["number"]} (shown once)
              </p>
              <p class="font-mono text-sm text-amber-900">{@signal_claim["command"]}</p>
            </div>
            <.button size="sm" phx-click="dismiss-signal-claim">Dismiss</.button>
          </div>

          <.table :if={@signal_status["bindings"] != []} id="signal-bindings" rows={@signal_status["bindings"]}>
            <:col :let={b} label="Chat">{if b["kind"] == "group", do: "Signal group", else: "Person"}</:col>
            <:col :let={b} label="Name">{b["display_name"] || "—"}</:col>
            <:col :let={b} label="Peer"><span class="font-mono text-xs">{b["peer"]}</span></:col>
            <:col :let={b} label="Number"><span class="font-mono text-xs">{b["number"]}</span></:col>
            <:action :let={b}>
              <.button
                size="sm"
                variant="danger"
                phx-click="signal-remove-binding"
                phx-value-binding_id={b["binding_id"]}
                data-confirm="Disconnect this Signal chat? A live call from it ends now."
              >
                Disconnect
              </.button>
            </:action>
          </.table>
          <.empty_state :if={@signal_status["bindings"] == []} icon="chat" title="No connected Signal chats" />

          <div :if={@signal_status["pending_claims"] != []} class="mt-3 space-y-1">
            <p class="text-xs font-medium text-neutral-600">Pending codes</p>
            <div
              :for={c <- @signal_status["pending_claims"]}
              class="flex items-center justify-between text-xs text-neutral-600"
            >
              <span>Expires {Format.datetime_text(DateTime.from_unix!(c["expires_at"], :millisecond))}</span>
              <.button size="sm" phx-click="signal-cancel-claim" phx-value-claim_id={c["claim_id"]}>
                Cancel
              </.button>
            </div>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  defp dashboard_conversation_participants(group) do
    user = %{
      "actor_type" => "user",
      "user_id" => "current",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"}
    }

    case group["router_agent_id"] do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        [
          user,
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "role_label" => "router",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]

      _ ->
        [user]
    end
  end

  # Options for the router-agent select: a "none" entry plus each group agent,
  # labelled with its name (falling back to the id) and valued by agent id.
  defp router_agent_options(agents) do
    [{"— None —", ""}] ++
      Enum.map(agents, fn agent ->
        {agent["name"] || agent["agent_id"], agent["agent_id"]}
      end)
  end

  defp env_vars(%{"env" => env}) when is_map(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp env_vars(_), do: ""

  defp env_iso(s) when is_integer(s), do: DateTime.from_unix!(s) |> DateTime.to_iso8601()
  defp env_iso(v), do: v

  defp conversation_tab_path(group_id, conversation_id) do
    base = "/dash/groups/#{group_id}?tab=conversations"

    case conversation_id do
      value when is_binary(value) and value != "" ->
        base <> "&conversation_id=" <> URI.encode_www_form(value)

      _ ->
        base
    end
  end

  defp conversation_title(conversation) do
    first_present([
      conversation["title"],
      MessageContent.preview(conversation["last_message_preview"], 48),
      conversation["conversation_id"]
    ])
  end

  defp participant_label(participant) do
    first_present([
      participant["agent_name"],
      participant["user_id"],
      participant["agent_id"],
      participant["actor_type"],
      participant["participant_id"]
    ])
  end

  defp participant_agent_path(%{"agent_id" => agent_id})
       when is_binary(agent_id) and agent_id != "",
       do: "/dash/agents/#{agent_id}"

  defp participant_agent_path(_participant), do: nil

  defp participant_session_path(%{"actor_type" => "agent", "agent_id" => agent_id} = participant)
       when is_binary(agent_id) and agent_id != "" do
    case agent_participant_session_id(participant) do
      session_id when is_binary(session_id) and session_id != "" ->
        "/dash/agents/#{agent_id}/sessions/#{URI.encode_www_form(session_id)}"

      _ ->
        nil
    end
  end

  defp participant_session_path(_participant), do: nil

  defp agent_participant_session_id(%{"payload" => %{"session_id" => session_id}}),
    do: session_id

  defp agent_participant_session_id(_participant), do: nil

  defp message_user?(message), do: (message["actor_type"] || message["role"]) == "user"

  defp message_actor(message) do
    first_present([
      message["agent_name"],
      message["user_id"],
      message["actor_type"],
      message["participant_id"]
    ])
  end

  defp iso(ms) when is_integer(ms) do
    unit = if ms > 99_999_999_999, do: :millisecond, else: :second
    DateTime.from_unix!(ms, unit) |> DateTime.to_iso8601()
  end

  defp iso(v), do: v

  defp env_host_label(%{"system_info" => %{"hostname" => host}})
       when is_binary(host) and host != "",
       do: host

  defp env_host_label(_), do: "—"

  defp env_os_arch(e) do
    info = e["system_info"] || %{}
    os = first_present([info["os_type"], e["os"]])
    arch = first_present([info["arch"], e["arch"]])

    [os, arch] |> Enum.reject(&(&1 == "")) |> Enum.join(" / ")
  end

  defp first_present(values) do
    Enum.find(values, "", &(is_binary(&1) and &1 != ""))
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp kv(assigns) do
    ~H"""
    <div class="rounded-lg border border-neutral-200 bg-white px-4 py-3">
      <dt class="text-xs font-medium uppercase tracking-wide text-neutral-500">{@label}</dt>
      <dd class="mt-1 text-sm text-neutral-800">{render_slot(@inner_block)}</dd>
    </div>
    """
  end
end
