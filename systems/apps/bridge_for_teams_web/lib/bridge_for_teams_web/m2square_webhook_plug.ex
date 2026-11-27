defmodule BridgeForTeamsWeb.M2squareWebhookPlug do
  @moduledoc """
  Captures and bounds raw request bytes for `POST /v1/billing/m2square/webhook`
  before `Plug.Parsers` runs, independently of `Content-Type`.

  Enforces a strict 64 KiB (65,536 bytes) payload ceiling, halting with HTTP 413
  when exceeded. All other routes pass through untouched.
  """

  import Plug.Conn

  @max_webhook_bytes 65_536

  def init(opts), do: opts

  def call(
        %Plug.Conn{method: "POST", path_info: ["v1", "billing", "m2square", "webhook"]} = conn,
        _opts
      ) do
    case read_bounded_body(conn, "") do
      {:ok, raw_body, conn} ->
        put_private(conn, :m2square_raw_body, raw_body)

      {:error, :too_large, conn} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(413, "payload_too_large")
        |> halt()

      {:error, _reason, conn} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "bad_request")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp read_bounded_body(conn, acc) do
    remaining = @max_webhook_bytes - byte_size(acc) + 1

    case Plug.Conn.read_body(conn, length: remaining, read_length: remaining) do
      {:ok, chunk, conn} ->
        raw = acc <> chunk

        if byte_size(raw) > @max_webhook_bytes do
          {:error, :too_large, conn}
        else
          {:ok, raw, conn}
        end

      {:more, chunk, conn} ->
        raw = acc <> chunk

        if byte_size(raw) > @max_webhook_bytes do
          {:error, :too_large, conn}
        else
          read_bounded_body(conn, raw)
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end
end
