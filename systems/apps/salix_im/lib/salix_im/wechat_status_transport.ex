defmodule SalixIM.WeChatStatusTransport do
  @moduledoc """
  Native typing presentation through Tencent's getconfig/sendtyping endpoints.
  Reuses the existing Req adapter and JSON decoder. Tickets live only in the
  source-scoped activity actor, never in agent tools or conversation messages.
  """

  alias SalixIM.WeChatAPI

  def authorized?(connect, target) do
    connect["provider"] == "wechat" and connect["managed_by"] == "comma_product" and
      connect["status"] == "connected" and is_nil(connect["deleted_at"]) and
      is_nil(connect["disabled_at"]) and nonblank?(connect["token"]) and
      nonblank?(connect["wechat_id"]) and target["wechat_id"] == connect["wechat_id"]
  end

  def send(connect, target, kind, ticket, _text) when kind in [:typing, :cancel] do
    started = System.monotonic_time()
    result = send_status(connect, target, kind, ticket)
    observe(result, started)
    result
  end

  defp send_status(connect, target, kind, ticket) do
    with true <- authorized?(connect, target),
         {:ok, ticket} <- ticket(connect, ticket),
         {:ok, _} <-
           request(connect, "sendtyping", %{
             "ilink_user_id" => target["wechat_id"],
             "typing_ticket" => ticket,
             "status" => if(kind == :typing, do: 1, else: 2)
           }) do
      {:ok, ticket}
    else
      false -> {:error, :revoked}
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

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

  defp ticket(_connect, ticket) when is_binary(ticket) and ticket != "", do: {:ok, ticket}

  defp ticket(connect, _) do
    with {:ok, body} <-
           request(connect, "getconfig", %{
             "ilink_user_id" => connect["wechat_id"],
             "context_token" => connect["latest_context_token"]
           }),
         ticket when is_binary(ticket) and ticket != "" <- body["typing_ticket"] do
      {:ok, ticket}
    else
      {:error, _} = error -> error
      _ -> {:error, :unsupported}
    end
  end

  defp request(connect, endpoint, body) do
    with {:ok, base} <- WeChatAPI.validate_origin(connect["base_url"]) do
      case Req.post(base <> "/ilink/bot/" <> endpoint,
             json: Map.put(body, "base_info", WeChatAPI.base_info()),
             headers: WeChatAPI.headers(connect["token"]),
             retry: false,
             redirect: false,
             receive_timeout: 2_000,
             connect_options: [timeout: 2_000]
           ) do
        {:ok, %{status: status, body: raw}} when status in 200..299 ->
          with {:ok, body} <- WeChatAPI.decode_body(raw) do
            cond do
              body["ret"] in [nil, 0] and body["errcode"] in [nil, 0] -> {:ok, body}
              body["ret"] == -14 or body["errcode"] == -14 -> {:error, :revoked}
              true -> {:error, :unavailable}
            end
          end

        {:ok, %{status: status}} when status in [401, 403] ->
          {:error, :revoked}

        _ ->
          {:error, :unavailable}
      end
    end
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
