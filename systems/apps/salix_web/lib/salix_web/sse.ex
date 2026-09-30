defmodule SalixWeb.SSE do
  @moduledoc """
  Server-Sent Events stream for a session: one chunked Bandit
  connection process per subscriber, subscribed to the agent's `Phoenix.PubSub`
  topic. Snapshot-then-live: emit the current transcript length first, then
  stream `update` events as the runtime commits, with a periodic heartbeat.

  Events carry references/summaries (`id: {last_ack}`); a client refreshes the
  transcript via the messages endpoint — the Go reference pattern preserved.
  """
  import Plug.Conn

  @heartbeat_ms 15_000

  @spec serve(Plug.Conn.t(), map(), String.t()) :: Plug.Conn.t()
  def serve(conn, %{"agent_id" => agent_id} = agent, session_id) do
    Phoenix.PubSub.subscribe(SalixWeb.PubSub, SalixWeb.PubSubNotifier.topic(agent_id))

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    case emit(conn, "snapshot", snapshot(agent, session_id)) do
      {:ok, conn} -> loop(conn, agent, session_id)
      {:error, _} -> conn
    end
  end

  defp loop(conn, %{"agent_id" => agent_id} = agent, session_id) do
    receive do
      {:salix_agent_event, ^agent_id, {:settled, _summaries}} ->
        summary = session_summary(agent, session_id)
        data = %{type: "update", session: summary}

        case emit(conn, "update", data, id: summary[:last_ack]) do
          {:ok, conn} -> loop(conn, agent, session_id)
          {:error, _} -> conn
        end

      {:salix_agent_event, ^agent_id, {:session_updated, ^session_id}} ->
        summary = session_summary(agent, session_id)
        data = %{type: "update", session: summary}

        case emit(conn, "update", data, id: summary[:last_ack]) do
          {:ok, conn} -> loop(conn, agent, session_id)
          {:error, _} -> conn
        end

      {:salix_agent_event, ^agent_id, _other} ->
        loop(conn, agent, session_id)
    after
      @heartbeat_ms ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> loop(conn, agent, session_id)
          {:error, _} -> conn
        end
    end
  end

  defp emit(conn, event, data, opts \\ []) do
    id_line = if opts[:id], do: "id: #{opts[:id]}\n", else: ""
    payload = "#{id_line}event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
    chunk(conn, payload)
  end

  defp snapshot(agent, session_id) do
    summary = session_summary(agent, session_id)

    %{
      type: "snapshot",
      status: summary.status,
      message_count: summary.message_count
    }
  end

  defp session_summary(agent, session_id) do
    case SalixAgent.Runtime.get_session(agent, session_id, projection: :status) do
      {:ok, session} ->
        %{
          status: session["status"] || session[:status],
          message_count: session["message_count"] || session[:message_count] || 0,
          last_ack: session["last_ack_message_id"] || session[:last_ack_message_id]
        }

      _ ->
        missing_session_summary(agent)
    end
  end

  defp missing_session_summary(agent) do
    if SalixAgent.Control.runtime_kind(agent) == "external",
      do: %{status: "unknown", message_count: 0, last_ack: nil},
      else: %{status: "idle", message_count: 0, last_ack: nil}
  end
end
