defmodule CommaWeb.LineIntegration do
  @moduledoc """
  Comma product LINE: one Comma LINE Official Account, one private chat per
  Workspace (docs/messaging-voice.md).

  The Workspace owner starts a claim in Settings › Channels and sends
  `link <code>` to the account from LINE (the message link fills it in). The
  binding then follows the Telegram order (CommaTelegramBinding.tla): consume
  the claim, retire routes, prepare a disabled connect, commit the binding,
  activate. After that, the person's private messages, and their messages in
  LINE groups that mention the account, reach the Workspace's Router.

  LINE signs every webhook body with the channel secret; one check covers the
  request, and each event is then routed by its sender.
  """

  require Logger

  alias Comma.{LineLinks, Workspaces}
  alias SalixIM.{LineInbound, ProviderConnects, ProviderHTTP}
  alias SalixIM.Provider.Line

  def configured? do
    config = config()

    config[:enabled] == true and
      Enum.all?([:channel_secret, :channel_access_token, :basic_id], &nonblank?(config[&1]))
  end

  def state(user, session, workspace_id) do
    with {:ok, workspace, link} <- LineLinks.get(user, session, workspace_id) do
      configured? = configured?()

      {:ok,
       %{
         "configured" => configured?,
         "basic_id" => if(configured?, do: basic_id()),
         "add_friend_url" => if(configured?, do: add_friend_url()),
         "workspace_id" => workspace["id"],
         "link" => LineLinks.public_link(link),
         "pending_claim" => public_claim(LineLinks.get_active_claim(workspace_id)),
         "connection_active" => match?({:ok, _}, active_connect(workspace, link))
       }}
    end
  end

  def start_connect(user, session, workspace_id) do
    with :ok <- require_configured(),
         {:ok, _workspace, claim} <- LineLinks.create_claim(user, session, workspace_id) do
      {:ok, public_claim(claim)}
    end
  end

  def cancel_connect(user, session, workspace_id),
    do: LineLinks.cancel_claim(user, session, workspace_id)

  def disconnect(user, session, workspace_id) do
    LineLinks.with_lifecycle_lock(fn ->
      with {:ok, workspace, link} <- LineLinks.get(user, session, workspace_id),
           :ok <- retire_link(link, workspace),
           {:ok, _workspace, removed?} <- LineLinks.delete(user, session, workspace_id) do
        {:ok, %{"disconnected" => removed?}}
      end
    end)
  end

  @doc """
  One webhook request. `:ok` answers 200; `{:error, :unauthorized}` a bad
  signature; any other error asks LINE to deliver the request again.
  """
  def handle_webhook(raw_body, headers, %{"events" => events}) when is_list(events) do
    with :ok <- require_configured(),
         :ok <- verify(headers, raw_body) do
      events
      |> Enum.filter(&is_map/1)
      |> Enum.reduce_while(:ok, fn event, :ok ->
        case handle_event(event) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  def handle_webhook(_raw_body, _headers, _payload), do: {:error, :invalid_line_payload}

  defp verify(headers, raw_body) do
    case LineInbound.verify_signature(config()[:channel_secret], headers, raw_body) do
      :ok -> :ok
      {:error, :invalid_signature} -> {:error, :unauthorized}
    end
  end

  # A person added the account: tell them how to connect, unless they did.
  defp handle_event(%{"type" => "follow", "source" => %{"type" => "user", "userId" => id}} = event) do
    case LineLinks.resolve_sender(id) do
      {:ok, %{user: user}} -> reply(event, :connected, locale(user))
      {:error, :line_not_linked} -> reply(event, :not_linked, nil)
    end
  end

  defp handle_event(%{"type" => "message", "message" => %{} = message} = event) do
    source = if is_map(event["source"]), do: event["source"], else: %{}
    sender = text(source["userId"])
    private? = source["type"] == "user"

    cond do
      sender == "" or event["mode"] == "standby" ->
        :ok

      private? and match?({:ok, _code}, LineLinks.claim_command(message["text"])) ->
        {:ok, code} = LineLinks.claim_command(message["text"])
        connect_message(event, sender, code)

      true ->
        deliver(event, sender, private?)
    end
  end

  defp handle_event(_event), do: :ok

  defp connect_message(event, sender, code) do
    result =
      with {:ok, %{user: user, workspace: workspace, claim: claim}} <- LineLinks.take_claim(code),
           {:ok, link} <- link_identity(user, workspace, sender, claim) do
        # A Router that started this attempt from the chat is waiting for it.
        CommaWeb.ChannelLinkTools.linked(workspace, "line", %{
          "line_display_name" => link.line_display_name
        })

        {:ok, user, workspace}
      end

    case result do
      {:ok, user, workspace} ->
        reply(event, {:linked, workspace["name"]}, locale(user))

      {:error, reason} ->
        Logger.warning("LINE connect failed",
          event: "line_connect_failed",
          reason_class: failure_class(reason)
        )

        reply(event, :link_failed, nil)
    end
  end

  defp link_identity(user, workspace, sender, proof) do
    LineLinks.with_lifecycle_lock(fn ->
      with :ok <- LineLinks.validate_connection_attempt(user["id"], workspace["id"], proof),
           :ok <- retire_conflicting_sender(sender, workspace["id"]),
           :ok <- retire_link(LineLinks.get_link(workspace["id"]), workspace),
           {:ok, connect} <-
             ProviderConnects.ensure_managed_line_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               %{
                 "channel_secret" => config()[:channel_secret],
                 "channel_access_token" => token(),
                 "line_user_id" => sender
               }
             ),
           {:ok, %{link: link}} <-
             LineLinks.put_link(
               user["id"],
               workspace["id"],
               %{"id" => sender, "display_name" => display_name(sender)},
               connect["connect_id"],
               proof
             ),
           :ok <-
             ProviderConnects.activate_managed_line_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               connect["connect_id"]
             ) do
        {:ok, link}
      end
    end)
  end

  # Best effort: a link without the name still works.
  defp display_name(sender) do
    case Line.profile(token(), sender) do
      {:ok, %{"displayName" => name}} when is_binary(name) and name != "" ->
        String.slice(name, 0, 200)

      _ ->
        nil
    end
  end

  defp deliver(event, sender, private?) do
    case LineLinks.resolve_sender(sender) do
      {:ok, %{workspace: workspace, link: link}} ->
        with {:ok, connect} <- active_connect(workspace, link),
             :ok <- ProviderHTTP.handle_line_event(connect, event) do
          :ok
        else
          {:error, reason} when reason in [:not_found, :line_link_inconsistent] ->
            if private?, do: reply(event, :reconnect, nil), else: :ok

          {:error, _reason} = error ->
            error
        end

      # Anyone can write to the account or mention it in a group; only a
      # private chat gets the guide.
      {:error, :line_not_linked} ->
        if private?, do: reply(event, :not_linked, nil), else: :ok
    end
  end

  defp active_connect(_workspace, nil), do: {:error, :not_found}

  defp active_connect(workspace, link) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             workspace["default_group_id"],
             link.connect_id,
             "line"
           ),
         true <-
           connect["managed_by"] == "comma_product" and
             connect["tenant_id"] == workspace["salix_tenant_id"] and
             connect["group_id"] == workspace["default_group_id"] and
             connect["managed_peer_id"] == link.line_user_id do
      {:ok, connect}
    else
      false -> {:error, :line_link_inconsistent}
      other -> other
    end
  end

  defp retire_conflicting_sender(sender, target_workspace_id) do
    case LineLinks.get_link_by_sender(sender) do
      %{workspace_id: workspace_id} = link when workspace_id != target_workspace_id ->
        with {:ok, workspace} <- Workspaces.get(workspace_id), do: retire_link(link, workspace)

      _same_workspace_or_absent ->
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
      {:error, reason} -> {:error, reason}
    end
  end

  # Account messages are best effort and use the event's free reply token; a
  # redelivered event cannot run a consumed claim again.
  defp reply(%{"replyToken" => reply_token}, kind, locale)
       when is_binary(reply_token) and reply_token != "" do
    _ = Line.reply_text(token(), reply_token, message(kind, locale))
    :ok
  end

  defp reply(_event, _kind, _locale), do: :ok

  defp message(kind, locale) do
    if is_binary(locale) and String.starts_with?(locale, "zh"),
      do: zh(kind),
      else: en(kind)
  end

  defp en({:linked, name}),
    do: "LINE is now connected to Comma workspace “#{name}”. Send a message here to get started."

  defp en(:connected), do: "LINE is connected to Comma. Send a message here to get started."

  defp en(:not_linked),
    do:
      "To chat with Comma here, open Comma Settings › Channels › LINE, choose Connect, and send the message it fills in."

  defp en(:link_failed),
    do:
      "Could not connect LINE. The code may have expired: get a new one in Comma Settings › Channels › LINE."

  defp en(:reconnect), do: "Reconnect LINE in Comma Settings › Channels."

  defp zh({:linked, name}), do: "LINE 已连接到 Comma 工作区「#{name}」。在这里发消息即可开始。"
  defp zh(:connected), do: "LINE 已连接到 Comma。在这里发消息即可开始。"
  defp zh(kind), do: en(kind)

  @doc "The link that opens a chat with the account, the text already typed in."
  def message_url(text),
    do:
      "https://line.me/R/oaMessage/" <>
        URI.encode_www_form(basic_id()) <> "/?" <> URI.encode(text, &URI.char_unreserved?/1)

  def add_friend_url, do: "https://line.me/R/ti/p/" <> URI.encode_www_form(basic_id())

  defp public_claim(nil), do: nil

  defp public_claim(claim) do
    claim
    |> LineLinks.public_claim()
    |> Map.put("message_url", message_url("link " <> claim.code))
  end

  defp locale(user), do: Comma.Accounts.locale(user["id"])

  defp failure_class(reason) when is_atom(reason), do: reason
  defp failure_class({:bad_request, _message}), do: :bad_request
  defp failure_class(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp failure_class(_reason), do: :other

  defp require_configured,
    do: if(configured?(), do: :ok, else: {:error, :line_unavailable})

  defp basic_id, do: config()[:basic_id]
  defp token, do: config()[:channel_access_token]
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp config, do: SystemsRuntime.get_env(:comma_web, :line, [])
end
