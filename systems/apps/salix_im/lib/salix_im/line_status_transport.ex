defmodule SalixIM.LineStatusTransport do
  @moduledoc """
  Native LINE loading animation for the private chat of a Comma-managed LINE
  connect, through `POST /v2/bot/chat/loading/start`
  (`SalixIM.Provider.Line.start_loading/3`). It is presentation only, not an
  agent tool or message egress.

  The managed connect is the authority: the target must be the private chat
  of its bound LINE user. LINE shows the animation only in one-on-one chats.
  It has no stop request: the animation ends when the next message from the
  account arrives or after `@loading_seconds`, so a cancel sends nothing.
  """

  alias SalixIM.Provider.Line

  # LINE takes 5 to 60 seconds, in steps of 5. The actor refreshes before
  # the animation ends, and a turn that ends without a reply leaves it
  # visible for at most this long.
  @loading_seconds 20

  def loading_seconds, do: @loading_seconds

  def authorized?(connect, target) do
    connect["provider"] == "line" and connect["managed_by"] == "comma_product" and
      connect["status"] == "connected" and is_nil(connect["deleted_at"]) and
      is_nil(connect["disabled_at"]) and target["chat_type"] == "private" and
      nonblank?(connect["managed_peer_id"]) and
      target["chat_id"] == "user:" <> connect["managed_peer_id"]
  end

  def send(connect, target, :typing, _ticket, _text) do
    started = SystemsClock.monotonic_time()
    result = send_status(connect, target)
    observe(result, started)
    result
  end

  def send(connect, target, :cancel, _ticket, _text) do
    if authorized?(connect, target), do: {:ok, nil}, else: {:error, :revoked}
  end

  def send(_connect, _target, _kind, _ticket, _text), do: {:error, :unsupported}

  defp send_status(connect, target) do
    if authorized?(connect, target) do
      case Line.start_loading(
             connect["channel_access_token"],
             connect["managed_peer_id"],
             @loading_seconds
           ) do
        {:ok, _body} -> {:ok, nil}
        {:error, {:line_api, 429, _}} -> {:error, {:retry_after, 10_000}}
        {:error, {:line_api, status, _}} when status in [401, 403] -> {:error, :revoked}
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
