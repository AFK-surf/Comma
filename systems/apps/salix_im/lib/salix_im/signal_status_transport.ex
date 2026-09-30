defmodule SalixIM.SignalStatusTransport do
  @moduledoc """
  Native Signal typing indicator for a bound private chat, through the
  account runtime (`SalixIM.Ports.SignalAccount.send_typing/3`). It is
  presentation only, not an agent tool or message egress.

  The binding is the authority: the chat must still be a private peer bound
  to this connect, and the typing message goes from the account that the
  binding names. A missing binding revokes the surface.
  """

  alias SalixIM.Ports.SignalAccount
  alias SalixIM.SignalConnects

  def authorized?(connect, target), do: binding(connect, target) != nil

  def send(connect, target, kind, _ticket, _text) when kind in [:typing, :cancel] do
    started = System.monotonic_time()
    result = send_status(connect, target, kind)
    observe(result, started)
    result
  end

  def send(_connect, _target, _kind, _ticket, _text), do: {:error, :unsupported}

  defp send_status(connect, target, kind) do
    case binding(connect, target) do
      nil ->
        {:error, :revoked}

      binding ->
        action = if kind == :typing, do: :started, else: :stopped

        case SignalAccount.send_typing(binding["account_id"], binding["peer"], action) do
          {:ok, _result} -> {:ok, nil}
          {:error, {:rate_limited, seconds}} -> {:error, {:retry_after, retry_ms(seconds)}}
          {:error, _reason} -> {:error, :unavailable}
          _other -> {:error, :unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp binding(connect, target) do
    with true <-
           connect["provider"] == "signal" and connect["status"] == "connected" and
             is_nil(connect["deleted_at"]) and is_nil(connect["disabled_at"]),
         true <- target["chat_type"] == "private",
         peer when is_binary(peer) and peer != "" <- target["chat_id"],
         %{"kind" => "user", "account_id" => account_id} = binding
         when is_binary(account_id) and account_id != "" <-
           SignalConnects.binding_for_peer(connect, peer) do
      binding
    else
      _ -> nil
    end
  end

  defp retry_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000
  defp retry_ms(_seconds), do: 60_000

  defp observe(result, started) do
    outcome =
      case result do
        {:ok, _} -> :ok
        {:error, :revoked} -> :rejected
        _ -> :unavailable
      end

    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
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
