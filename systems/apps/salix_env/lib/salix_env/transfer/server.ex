defmodule SalixEnv.Transfer.Server do
  @moduledoc """
  Inbound byte-stream listener — the h2c transfer server's role in
  the BEAM rewrite. Bulk bytes never ride Erlang distribution (head-of-line
  blocking); a peer POSTs them to `POST /stream/:token` on a dedicated listener.

  The token is claimed atomically (one-time); the body is streamed to the
  registered owner process, and the response carries the completion envelope
  (`{ok, bytes}` or `{error}`) — the same "reply before/with the body completion"
  contract the Go server preserves. A 404 means an unknown/used/expired token.

  Bodies are relayed chunk-by-chunk to the token owner. The handler waits for
  an owner ack after every chunk, so downstream consumers provide backpressure
  instead of allowing mailbox growth for large copies.
  """
  import Plug.Conn
  alias SalixEnv.Transfer.Tokens

  @chunk 64 * 1024

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: ["stream", token]} = conn, _opts) do
    case Tokens.claim(token) do
      {:ok, owner} ->
        with {:ok, conn, bytes} <- relay_body(conn, owner, token, 0),
             {:ok, envelope} <- await_completion(token) do
          json(conn, 200, Map.put(envelope, "bytes", bytes))
        else
          {:error, reason} -> json(conn, 500, %{"ok" => false, "error" => inspect(reason)})
        end

      :error ->
        json(conn, 404, %{"ok" => false, "error" => "unknown or used token"})
    end
  end

  def call(conn, _opts), do: json(conn, 404, %{"error" => "not found"})

  defp relay_body(conn, owner, token, bytes) do
    case read_body(conn, length: @chunk, read_length: @chunk) do
      {:more, chunk, conn} ->
        with :ok <- deliver(owner, token, {:chunk, chunk}) do
          relay_body(conn, owner, token, bytes + byte_size(chunk))
        end

      {:ok, chunk, conn} ->
        with :ok <- maybe_deliver(owner, token, chunk),
             :ok <- deliver(owner, token, :eof) do
          {:ok, conn, bytes + byte_size(chunk)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_deliver(_owner, _token, ""), do: :ok
  defp maybe_deliver(owner, token, chunk), do: deliver(owner, token, {:chunk, chunk})

  defp deliver(owner, token, {:chunk, chunk}) do
    send(owner, {:transfer_chunk, token, self(), chunk})
    await_ack(token)
  end

  defp deliver(owner, token, :eof) do
    send(owner, {:transfer_eof, token, self()})
    await_ack(token)
  end

  defp await_ack(token) do
    receive do
      {:transfer_ack, ^token} -> :ok
    after
      180_000 -> {:error, :transfer_ack_timeout}
    end
  end

  defp await_completion(token) do
    receive do
      {:transfer_complete, ^token, envelope} when is_map(envelope) -> {:ok, envelope}
    after
      180_000 -> {:error, :transfer_completion_timeout}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
