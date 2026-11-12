defmodule SalixAgent.Tools.ChannelLink do
  @moduledoc """
  A Router connects a chat channel (WeChat, Telegram, iMessage, Signal) to
  the Workspace it serves, from the chat: the user says "connect WeChat", the
  Router calls `channel.link`, posts them what the channel needs (a QR code to
  scan, a link to open, a code to send), and the call waits until the channel
  is connected, so the Router can tell them without asking again.

  The product adapter (`:channel_link_adapter_mod`) owns the channels: who may
  connect them (the Workspace owner, from the message's server-sealed
  principal, never from the model), how each attempt starts, and when it is
  connected (`SalixAgent.CapabilityRequests.complete_channel_link/4`) or over
  (`fail_channel_link_request/4`; an attempt that runs out ends as the request
  expires). Its `start/3` answers `{:ok, %{"status" => "connected", ...}}`,
  `{:ok, %{"status" => "pending", "provider", "attempt_id", "expires_at",
  ...}}` (what the Router shows the user, with `instructions`; a QR code comes
  as `qr_png`, which this tool writes into the Router's workspace so the Router
  sends it as an image) or `{:error, reason}`; `watch/3` is told the request a
  pending attempt must settle.
  """

  alias SalixAgent.{CapabilityRequestStore, FileBackend, Waits}
  alias SalixAgent.Tools.AsyncPolicy

  @providers ~w(wechat telegram imessage signal)
  @user_interaction_auto_wait_seconds AsyncPolicy.user_interaction_tool_auto_wait_seconds()

  def defs do
    [
      {"channel.link",
       "Connect a chat channel (wechat, telegram, imessage or signal) to this Workspace for the user you serve, from this chat, when they ask to connect or bind one. " <>
         "Only the Workspace owner can; the requester is the sender of the message you are answering. " <>
         "An already connected channel answers status connected: tell the user, and call again with replace true only when they want to connect another account. " <>
         "Otherwise it answers status pending with what the user must do and instructions: post that to them in this chat at once, through the current reply path. " <>
         "A QR code comes as qr_image_path, a file in your workspace: send it as an image content block ({\"type\":\"image\",\"path\":qr_image_path}), never as text or a link. A link_url goes as a link, a command as text they can copy. " <>
         "The call then waits until the channel is connected and returns status linked (or failed / expired): then tell them. " <>
         "WeChat may answer status verification_code_required: ask the user for the code WeChat sent to their phone, then call again with the same provider, attempt_id and verify_code. " <>
         "imessage takes an optional handle (the user's phone number or Apple Account email) for a Photon line.",
       schema(), &__MODULE__.link/2, @user_interaction_auto_wait_seconds,
       [safety: "write", roles: ["router"], runtimes: [:internal]]}
    ]
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["provider"],
      "properties" => %{
        "provider" => %{"type" => "string", "enum" => @providers},
        "handle" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
        "replace" => %{"type" => "boolean"},
        "attempt_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "verify_code" => %{"type" => "string", "pattern" => "^[0-9]{1,16}$"}
      }
    }
  end

  def link(args, ctx) do
    with :ok <- SalixAgent.Tools.validate_schema(args, schema()),
         :ok <- validate_verification(args),
         {:ok, result} <- adapter().start(args["provider"], args, ctx) do
      case result do
        %{"status" => "pending"} = attempt ->
          # The QR image is written before anything waits on it: a write the
          # Workspace cannot afford leaves no attempt half started.
          case write_qr(attempt, ctx) do
            {:ok, attempt, workspace_events} -> await(attempt, workspace_events, ctx)
            {:error, reason} -> storage_failure(reason)
          end

        other ->
          Jason.encode!(other)
      end
    else
      {:error, reason} when is_binary(reason) ->
        failure("invalid_arguments", reason)

      {:error, :forbidden} ->
        failure("forbidden", "Only the Workspace owner can connect its channels.")

      {:error, :requester_unknown} ->
        failure(
          "requester_unknown",
          "The requester is not known as this Workspace's owner; the owner must ask in their own chat."
        )

      {:error, :unsupported_provider} ->
        failure("unsupported_provider", "This channel cannot be connected from the chat.")

      {:error, {:unavailable, provider}} ->
        failure(
          "channel_unavailable",
          "#{provider} is not configured on this server; the channel cannot be connected."
        )

      {:error, :verification_code_rejected} ->
        failure(
          "verification_code_rejected",
          "WeChat did not accept that verification code; ask the user for it again and call again with the same attempt_id."
        )

      {:error, :attempt_unknown} ->
        failure(
          "attempt_unknown",
          "That attempt is no longer open (it expired, or the user cancelled or replaced it); call again without attempt_id to start a new one."
        )

      {:error, reason} ->
        failure("channel_link_failed", "The channel link could not start: #{inspect(reason)}")
    end
  end

  defp validate_verification(%{"verify_code" => _} = args)
       when not is_map_key(args, "attempt_id"),
       do: {:error, "verify_code needs the attempt_id the code is for"}

  defp validate_verification(_args), do: :ok

  # The attempt is open. The call stays open as a capability request until the
  # product completes or fails it, or the attempt's own expiry ends it; the
  # Agent posts what the user must do meanwhile.
  defp await(attempt, workspace_events, ctx) do
    {:ok, %{tenant: tenant, group_id: group_id}} =
      SalixAgent.OAuthStore.agent_oauth_context(ctx.agent_id)

    session_id = ctx.session_id
    tool_call_id = ctx[:tool_call_id] || random_id()
    provider = attempt["provider"]

    {:ok, request} =
      CapabilityRequestStore.create_capability_request(%{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "source_agent_id" => ctx.agent_id,
        "source_session_id" => session_id,
        "tool_call_id" => tool_call_id,
        "request_type" => "channel_link",
        "request_payload" => %{
          "channel_link" => %{
            "provider" => provider,
            "attempt_id" => attempt["attempt_id"],
            "tool_name" => "channel.link"
          }
        },
        "expires_at" => attempt["expires_at"]
      })

    :ok =
      adapter().watch(provider, attempt, %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "request_id" => request["request_id"]
      })

    # Who asked and where is the product's, not the model's.
    content =
      attempt
      |> Map.drop(["user_id", "workspace_id", "verify_code"])
      |> Map.put("tool_call_id", tool_call_id)
      |> Map.update("instructions", "", fn instructions ->
        instructions <>
          " Post this to the user in this chat now, through the current reply path. " <>
          "This call returns status linked once the channel is connected; then tell them."
      end)
      |> Jason.encode!()

    wait =
      Waits.build(
        "channel link",
        @user_interaction_auto_wait_seconds,
        "auto_wait",
        %{"tool_call_id" => tool_call_id, "tool_name" => "channel.link"}
      )

    {content,
     workspace_events ++
       [
         %{
           "type" => "async_tool_call_started",
           "session_id" => session_id,
           "tool_call_id" => tool_call_id,
           "tool_name" => "channel.link",
           "input" => Jason.encode!(%{"provider" => provider}),
           "status" => "running",
           "completion_mode" => "external_callback",
           "started_at" => SystemsClock.system_time(:millisecond),
           "auto_wait_seconds" => @user_interaction_auto_wait_seconds
         }
         |> Map.merge(CapabilityRequestStore.execution_fields(request)),
         Waits.event(session_id, wait)
       ]}
  end

  # A QR code is an image in the Router's workspace, which it sends as an
  # image: the payload would not scan as text or a link.
  defp write_qr(%{"qr_png" => png} = attempt, ctx) when is_binary(png) do
    path = "/channels/#{attempt["provider"]}-qr-#{random_id()}.png"

    case FileBackend.prepare_write(ctx, path, png) do
      {:ok, event} ->
        {:ok, attempt |> Map.delete("qr_png") |> Map.put("qr_image_path", path), [event]}

      {:error, _reason} = error ->
        error
    end
  end

  defp write_qr(attempt, _ctx), do: {:ok, attempt, []}

  defp storage_failure({:billing_unavailable, _decision}),
    do:
      failure(
        "insufficient_credits",
        "The Workspace has no credits left to store the QR code image; the user adds credits first."
      )

  defp storage_failure(reason),
    do:
      failure("storage_unavailable", "The QR code image could not be stored: #{inspect(reason)}")

  defp random_id, do: SystemsRuntime.Proc.random_bytes(8) |> Base.encode16(case: :lower)

  defp adapter do
    case SystemsRuntime.get_env(:salix_agent, :channel_link_adapter_mod) do
      nil -> raise "channel links are not available here"
      module -> module
    end
  end

  defp failure(code, message) do
    {:tool_failure, Jason.encode!(%{"code" => code, "message" => message}), code,
     "user_reportable", message, []}
  end
end
