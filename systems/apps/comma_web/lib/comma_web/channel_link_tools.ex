defmodule CommaWeb.ChannelLinkTools do
  @moduledoc """
  The Comma side of the `channel.link` Router tool
  (`SalixAgent.Tools.ChannelLink`): a Workspace owner connects WeChat,
  Telegram, iMessage or Signal to their Workspace from the Router chat, the
  way Settings › Channels does it, without opening Settings.

  The requester is the sender of the message the turn answers, from its
  server-sealed principal (`SalixAgent.IFC.principal/1`): the Comma user who
  owns the Group's Workspace, or a chat user linked to that account
  (`Comma.ProviderUserLinks`). Nobody else connects a channel.

  Each provider keeps its own attempt (`CommaWeb.WeChatIntegration`,
  `CommaWeb.TelegramIntegration`, `CommaWeb.IMessageIntegration`,
  `Salix.Control.Signal`); this module starts it and answers what the user
  must do. A WeChat QR code is rendered here as a PNG (`qr_png`), which the
  tool puts in the Router's workspace for it to send as an image. The attempt
  completes where it always did (the QR poll, the OIDC callback, the claim
  message), and that path calls `linked/3`, which ends every `channel.link`
  call waiting for the provider. A WeChat attempt is polled by
  `CommaWeb.WeChatLinkWatch` while a Router waits, since nothing else polls
  it without the Settings page open; when WeChat asks for a verification code
  the waiting call returns so the Router can ask the user, and a second call
  with `attempt_id` and `verify_code` submits it.
  """

  @behaviour SalixIM.Ports.ChannelLinks

  require Logger

  alias Comma.{Accounts, ProviderUserLinks, Workspaces}
  alias CommaWeb.{IMessageIntegration, TelegramIntegration, WeChatIntegration}
  alias SalixAgent.CapabilityRequests

  @telegram_attempt_seconds 600
  @qr_width 360

  @doc """
  Starts connecting `provider` for the requester's Workspace, or reports it
  connected. `{:ok, %{"status" => "connected" | "pending", ...}}` or an error.
  """
  def start(provider, args, ctx) when provider in ~w(wechat telegram imessage signal) do
    with {:ok, user, workspace} <- owner(ctx) do
      start(provider, user, workspace, args)
    end
  end

  def start(_provider, _args, _ctx), do: {:error, :unsupported_provider}

  @doc "A pending attempt the tool recorded a waiting request for: WeChat needs polling."
  def watch("wechat", attempt, waiting) do
    {:ok, _pid} =
      CommaWeb.WeChatLinkWatch.start(%{
        user_id: attempt["user_id"],
        workspace_id: attempt["workspace_id"],
        attempt_id: attempt["attempt_id"],
        verify_code: attempt["verify_code"],
        expires_at: attempt["expires_at"],
        waiting: waiting
      })

    :ok
  end

  def watch(_provider, _attempt, _waiting), do: :ok

  @doc """
  The Workspace connected `provider`, through any path: every `channel.link`
  call waiting for it returns linked. Never changes the binding's result.
  """
  def linked(workspace, provider, details) when is_map(workspace) and is_binary(provider) do
    CapabilityRequests.complete_channel_link(
      workspace["default_group_id"],
      workspace["salix_tenant_id"],
      provider,
      details
    )
  rescue
    error ->
      Logger.warning("channel link completion failed: #{Exception.message(error)}")
      :ok
  end

  @doc "The WeChat attempt a Router waited for ended without connecting: its call fails."
  def failed(
        %{"group_id" => group_id, "tenant_id" => tenant_id, "request_id" => request_id},
        reason
      ) do
    CapabilityRequests.fail_channel_link_request(group_id, tenant_id, request_id, reason)
  rescue
    error ->
      Logger.warning("channel link failure not recorded: #{Exception.message(error)}")
      :ok
  end

  @doc """
  WeChat asks the user for a verification code before it connects the scanned
  attempt: the Router's call returns so it can ask, and the attempt stays open
  for the call that brings the code.
  """
  def verification_code_required(
        %{"group_id" => group_id, "tenant_id" => tenant_id, "request_id" => request_id},
        attempt_id
      ) do
    CapabilityRequests.complete_channel_link_request(
      group_id,
      tenant_id,
      request_id,
      %{
        "status" => "verification_code_required",
        "provider" => "wechat",
        "attempt_id" => attempt_id
      },
      "WeChat sent the user a verification code after they scanned; ask them for it, then call channel.link again with provider wechat, this attempt_id and verify_code"
    )
  rescue
    error ->
      Logger.warning("channel link verification step not recorded: #{Exception.message(error)}")
      :ok
  end

  @impl SalixIM.Ports.ChannelLinks
  def signal_bound(%{"tenant_id" => tenant_id, "group_id" => group_id} = bound) do
    CapabilityRequests.complete_channel_link(group_id, tenant_id, "signal", %{
      "peer" => get_in(bound, ["binding", "display_name"]) || get_in(bound, ["binding", "peer"])
    })
  rescue
    error ->
      Logger.warning("channel link completion failed: #{Exception.message(error)}")
      :ok
  end

  # ---- providers ----

  # The user has the code WeChat sent them: submit it for the attempt they scanned.
  defp start("wechat", user, workspace, %{"verify_code" => code, "attempt_id" => attempt_id}) do
    case WeChatIntegration.poll_connect(user, %{}, workspace["id"], attempt_id, code) do
      {:ok, %{"connection_active" => true} = public} ->
        connected("wechat", %{"wechat_id" => public["wechat_id"]})

      {:ok, %{"login_status" => "need_verifycode"}} ->
        {:error, :verification_code_rejected}

      {:ok, %{"expires_at" => expires_at}} ->
        pending("wechat", attempt_id, expires_at, user, workspace, %{
          "verify_code" => code,
          "instructions" =>
            "WeChat took the verification code; tell the user it is connecting, and that they may need to confirm on their phone."
        })

      {:error, reason}
      when reason in [:wechat_login_expired, :invalid_wechat_connection_attempt] ->
        {:error, :attempt_unknown}

      {:error, :invalid_wechat_verification_code} ->
        {:error, :verification_code_rejected}

      {:error, _reason} = error ->
        error
    end
  end

  defp start("wechat", user, workspace, args) do
    with {:ok, state} <- WeChatIntegration.state(user, %{}, workspace["id"]) do
      if active?(state["connection"]) and not replace?(args) do
        connected("wechat", %{"wechat_id" => state["connection"]["wechat_id"]})
      else
        with {:ok, attempt} <- WeChatIntegration.start_connect(user, %{}, workspace["id"]) do
          pending("wechat", attempt["connect_id"], attempt["expires_at"], user, workspace, %{
            "qr_png" => qr_png(attempt["qrcode_url"]),
            "instructions" =>
              "Send the user the QR code image (qr_image_path, as an image content block) and ask them to scan it in WeChat within five minutes, then confirm on their phone."
          })
        end
      end
    end
  end

  defp start("telegram", user, workspace, args) do
    with {:ok, state} <- TelegramIntegration.state(user, %{}, workspace["id"]),
         true <- state["configured"] or {:error, {:unavailable, "telegram"}} do
      if state["connection_active"] and not replace?(args) do
        connected("telegram", %{"telegram_username" => state["link"]["telegram_username"]})
      else
        with {:ok, attempt} <-
               TelegramIntegration.start_connect(user, %{}, workspace["id"], nil) do
          pending(
            "telegram",
            attempt["attempt_id"],
            SystemsClock.system_time(:second) + @telegram_attempt_seconds,
            user,
            workspace,
            %{
              "link_url" => attempt["authorization_url"],
              "bot_url" => state["bot_url"],
              "instructions" =>
                "Give the user link_url to open: they sign in with Telegram there and allow the bot, within ten minutes."
            }
          )
        end
      end
    end
  end

  defp start("imessage", user, workspace, args) do
    with {:ok, state} <- IMessageIntegration.state(user, %{}, workspace["id"]),
         true <- state["configured"] or {:error, {:unavailable, "imessage"}} do
      if state["connection_active"] and not replace?(args) do
        connected("imessage", %{"sender_handle" => state["link"]["sender_handle"]})
      else
        attrs =
          cond do
            is_binary(args["handle"]) -> %{"handle" => args["handle"]}
            state["relay_configured"] -> %{}
            true -> %{"transport" => "photon"}
          end

        with {:ok, claim} <- IMessageIntegration.start_connect(user, %{}, workspace["id"], attrs) do
          command = "bridgebot connect " <> claim["code"]

          send_to =
            if claim["transport"] == "photon",
              do: claim["line_handle"],
              else: state["shared_handle"]

          pending("imessage", claim["code"], claim["expires_at"], user, workspace, %{
            "command" => command,
            "send_to" => send_to,
            "instructions" =>
              "Ask the user to send the text `#{command}` from Messages on their iPhone or Mac to #{send_to || "the Comma iMessage line"}, within ten minutes."
          })
        end
      end
    end
  end

  defp start("signal", user, workspace, args) do
    group_id = workspace["default_group_id"]
    tenant_id = workspace["salix_tenant_id"]

    with {:ok, status} <- Salix.Control.Signal.status(group_id, tenant_id) do
      if status["bindings"] != [] and not replace?(args) do
        connected("signal", %{"peers" => Enum.map(status["bindings"], & &1["display_name"])})
      else
        case Salix.Control.Signal.start_claim(group_id, tenant_id, "comma_user:" <> user["id"]) do
          {:ok, %{"claim" => claim}} ->
            pending(
              "signal",
              claim["claim_id"],
              div(claim["expires_at"], 1000),
              user,
              workspace,
              %{
                "command" => claim["command"],
                "number" => claim["number"],
                "instructions" =>
                  "Ask the user to send the text `#{claim["command"]}` on Signal to #{claim["number"]}, within ten minutes."
              }
            )

          {:error, :not_configured} ->
            {:error, {:unavailable, "signal"}}

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  # The QR payload WeChat gave, as the image Settings renders from it.
  defp qr_png(payload) when is_binary(payload) and payload != "",
    do: payload |> EQRCode.encode() |> EQRCode.png(width: @qr_width)

  defp connected(provider, details) do
    {:ok,
     Map.merge(
       %{
         "status" => "connected",
         "provider" => provider,
         "message" =>
           "#{provider} is already connected to this Workspace. Call again with replace true only if the user wants to connect another account."
       },
       details
     )}
  end

  defp pending(provider, attempt_id, expires_at, user, workspace, presentation) do
    {:ok,
     Map.merge(presentation, %{
       "status" => "pending",
       "provider" => provider,
       "attempt_id" => attempt_id,
       "expires_at" => expires_at,
       "user_id" => user["id"],
       "workspace_id" => workspace["id"]
     })}
  end

  defp active?(%{"connection_active" => true}), do: true
  defp active?(_connection), do: false

  defp replace?(args), do: args["replace"] == true

  # ---- the requester ----

  @doc """
  The Group's Workspace and its owner, when the sender of the message the
  turn answers is that owner (a Comma user, or a chat user linked to their
  account), from the message's server-sealed principal. Router tools that
  only the owner may use (`plugin.request_install` too) ask this.
  """
  def owner(ctx) do
    origin = ctx[:trusted_origin] || %{}

    with {:ok, workspace} <- Workspaces.get_by_group(ctx[:group_id]),
         {:ok, user_id} <- requester_id(SalixAgent.IFC.principal(origin)),
         true <- workspace["owner_user_id"] == user_id || {:error, :forbidden},
         {:ok, user} <- Accounts.get_user(user_id) do
      {:ok, user, workspace}
    else
      {:error, :not_found} -> {:error, :requester_unknown}
      {:error, _reason} = error -> error
    end
  end

  defp requester_id({:comma_user, subject}), do: {:ok, subject}

  defp requester_id({:provider_user, connect, subject}) do
    case ProviderUserLinks.resolve(connect, subject) do
      {:ok, user_id} -> {:ok, user_id}
      :none -> {:error, :requester_unknown}
    end
  end

  defp requester_id(_principal), do: {:error, :requester_unknown}
end
