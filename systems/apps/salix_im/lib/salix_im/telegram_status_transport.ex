defmodule SalixIM.TelegramStatusTransport do
  @moduledoc """
  Narrow Bot API presentation adapter, not an agent tool or message egress.

  The existing Telegram provider uses Req with per-connect credentials. There
  is no official Elixir SDK; Telegex's documented global token configuration
  does not fit concurrent per-connect authority. Keep this additive surface
  here (no handwritten encoding/signing), with HTTP contract tests, rather than
  changing the provider framework or exposing draft APIs to agents.
  """

  def send(connect, target, :typing, _draft_id, _text) do
    call(connect, target, "sendChatAction", %{"action" => "typing"})
  end

  def send(_connect, _target, _kind, _draft_id, _text), do: {:error, :unsupported}

  defp call(connect, target, method, fields) do
    if authorized?(connect, target) do
      started = System.monotonic_time()
      result = request(connect, target, method, fields)
      observe(result, started)
      result
    else
      {:error, :revoked}
    end
  end

  def authorized?(connect, target) do
    connect["provider"] == "telegram" and connect["managed_by"] == "comma_product" and
      connect["status"] == "connected" and is_nil(connect["deleted_at"]) and
      is_nil(connect["disabled_at"]) and target["chat_type"] == "private" and
      is_binary(connect["bot_token"]) and connect["bot_token"] != "" and
      is_binary(target["chat_id"]) and target["chat_id"] != "" and
      to_string(connect["managed_peer_id"]) == target["chat_id"] and
      not is_nil(positive_id(target["chat_id"])) and
      (target["message_thread_id"] in [nil, ""] or
         not is_nil(positive_id(target["message_thread_id"])))
  end

  defp request(connect, target, method, fields) do
    base = Application.get_env(:salix_im, :telegram_api_base_url, "https://api.telegram.org")
    body = Map.put(fields, "chat_id", positive_id(target["chat_id"]))
    thread = target["message_thread_id"]

    body =
      if thread in [nil, ""],
        do: body,
        else: Map.put(body, "message_thread_id", positive_id(thread))

    case Req.post("#{String.trim_trailing(base, "/")}/bot#{connect["bot_token"]}/#{method}",
           json: body,
           retry: false,
           redirect: false,
           receive_timeout: 2_000,
           connect_options: [timeout: 2_000]
         ) do
      {:ok, %{status: code, body: %{"ok" => true, "result" => true}}} when code in 200..299 ->
        :ok

      {:ok, %{status: http, body: body}} ->
        code = if is_map(body), do: body["error_code"] || http, else: http

        cond do
          code in [401, 403] -> {:error, :revoked}
          code in [400, 404] -> {:error, :unsupported}
          code == 429 -> {:error, {:retry_after, retry_after(body)}}
          true -> {:error, :unavailable}
        end

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp retry_after(%{"parameters" => %{"retry_after" => seconds}})
       when is_integer(seconds) and seconds > 0,
       do: seconds * 1_000

  defp retry_after(_), do: 5_000

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: value
  defp positive_id(_value), do: nil

  defp observe(result, started) do
    outcome =
      case result do
        :ok -> :ok
        {:error, :revoked} -> :rejected
        {:error, :timeout} -> :timeout
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
