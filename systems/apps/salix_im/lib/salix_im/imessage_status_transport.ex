defmodule SalixIM.IMessageStatusTransport do
  @moduledoc """
  Native iMessage typing indicator for a Comma-managed Photon private chat,
  through `POST /spaces/{spaceId}/typing` (`SalixIM.PhotonIMessage.set_typing/3`).
  It is presentation only, not an agent tool or message egress.

  The managed connect is the authority: the target must be its bound Space,
  and the indicator comes from its assigned line. The relay transport has no
  typing indicator.
  """

  alias SalixIM.PhotonIMessage
  alias SalixIM.Provider.IMessage

  def authorized?(connect, target) do
    connect["provider"] == "imessage" and connect["runtime_mode"] == "photon" and
      connect["status"] == "connected" and is_nil(connect["deleted_at"]) and
      is_nil(connect["disabled_at"]) and IMessage.current_transport?(connect) and
      target["chat_type"] == "private" and nonblank?(connect["bot_user_id"]) and
      nonblank?(target["chat_id"]) and target["chat_id"] == connect["managed_chat_id"]
  end

  def send(connect, target, kind, _ticket, _text) when kind in [:typing, :cancel] do
    started = SystemsClock.monotonic_time()
    result = send_status(connect, target, kind)
    observe(result, started)
    result
  end

  def send(_connect, _target, _kind, _ticket, _text), do: {:error, :unsupported}

  defp send_status(connect, target, kind) do
    if authorized?(connect, target) do
      case PhotonIMessage.set_typing(connect["bot_user_id"], target["chat_id"], kind == :typing) do
        :ok -> {:ok, nil}
        {:error, {:photon, 429, _}} -> {:error, {:retry_after, 5_000}}
        {:error, {:photon, status, _}} when status in [401, 403, 404] -> {:error, :revoked}
        {:error, {:photon, 422, _}} -> {:error, :unsupported}
        _ -> {:error, :unavailable}
      end
    else
      {:error, :revoked}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp nonblank?(value), do: is_binary(value) and value != ""

  defp observe(result, started) do
    outcome =
      case result do
        {:ok, _} -> :ok
        {:error, :revoked} -> :rejected
        _ -> :unavailable
      end

    SystemsRuntime.Telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: SystemsClock.monotonic_time() - started},
      %{
        component: "salix_im",
        operation: "private_chat_status",
        surface: "comma",
        outcome: outcome
      }
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
