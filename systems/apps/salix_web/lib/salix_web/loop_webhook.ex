defmodule SalixWeb.LoopWebhook do
  @moduledoc "Secret-URL ingress for one Agent-owned Loop."
  import Plug.Conn

  alias SalixAgent.Loops
  alias SalixStore.Loops, as: Store
  alias Salix.App.RouterInbox.RateLimit

  # Authenticate and limit before the parser reads the request body. Redis
  # buckets contain Loop IDs, never secrets, and expire through Hammer.
  def admit(conn) do
    secret = List.last(conn.path_info)

    with :ok <- limit("global", 6_000),
         {:ok, record} <- Store.get_by_webhook_secret(secret),
         :ok <- limit("loop:" <> record["id"], 60) do
      conn |> put_resp_header("cache-control", "no-store")
    else
      {:error, :not_found} ->
        reply(conn, 404, %{error: "not_found"}) |> halt()

      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", to_string(seconds))
        |> reply(429, %{error: "rate_limited"})
        |> halt()

      {:error, _} ->
        reply(conn, 503, %{error: "unavailable"}) |> halt()
    end
  end

  def receive_event(conn, secret) do
    cond do
      conn.assigns[:raw_body_too_large] == true ->
        reply(conn, 413, %{error: "payload_too_large"})

      not json_content_type?(conn) ->
        reply(conn, 415, %{error: "json_required"})

      not is_map(conn.body_params) or match?(%Plug.Conn.Unfetched{}, conn.body_params) or
        not is_binary(conn.assigns[:raw_body]) or
          not String.starts_with?(String.trim_leading(conn.assigns[:raw_body]), "{") ->
        reply(conn, 400, %{error: "json_object_required"})

      true ->
        event_id =
          case get_req_header(conn, "idempotency-key") do
            [] -> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
            [value] -> String.trim(value)
            _ -> nil
          end

        if is_nil(event_id) or event_id == "" or byte_size(event_id) > 128 do
          reply(conn, 422, %{error: "invalid_event_id"})
        else
          event = %{"event_id" => event_id, "topic" => "webhook", "payload" => conn.body_params}
          deliver(conn, secret, event)
        end
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
          "application/json"

      _ ->
        false
    end
  end

  defp deliver(conn, secret, event) do
    case Loops.deliver_webhook_event(secret, event) do
      {:ok, result} ->
        reply(conn, 202, %{
          status: "accepted",
          event_id: event["event_id"],
          duplicate: result["duplicate"] == true
        })

      {:error, :not_found} ->
        reply(conn, 404, %{error: "not_found"})

      {:error, {:not_active, status}} ->
        reply(conn, 409, %{error: "loop_not_active", status: status})

      {:error, {:invalid_event, field}} ->
        reply(conn, 422, %{error: "invalid_request", field: field})

      {:error, :mailbox_full} ->
        conn |> put_resp_header("retry-after", "5") |> reply(429, %{error: "mailbox_full"})

      {:error, _} ->
        reply(conn, 503, %{error: "unavailable"})
    end
  end

  defp limit(bucket, count) do
    case RateLimit.hit("loop-webhook:" <> bucket, 60_000, count) do
      {:allow, _} -> :ok
      {:deny, ms} -> {:error, {:rate_limited, max(1, div(ms + 999, 1000))}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
