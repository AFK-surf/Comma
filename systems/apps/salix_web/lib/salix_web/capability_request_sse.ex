defmodule SalixWeb.CapabilityRequestSSE do
  @moduledoc """
  Live durable capability request stream for agent groups.

  The stream is snapshot-then-live: it first emits current pending durable
  requests, then publishes durable request updates for the group.
  """

  import Plug.Conn

  alias Salix.Control.Groups
  alias SalixAgent.CapabilityRequests

  @heartbeat_ms 15_000

  @spec serve(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def serve(conn, group_id, tenant_id) do
    with {:ok, _group} <- Groups.get(group_id, tenant_id) do
      if Process.whereis(SalixWeb.PubSub) do
        Phoenix.PubSub.subscribe(
          SalixWeb.PubSub,
          CapabilityRequests.topic(group_id)
        )
      end

      case CapabilityRequests.list_group(group_id, tenant_id, status: "pending") do
        {:ok, requests} ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("x-accel-buffering", "no")
            |> send_chunked(200)

          case emit_all(conn, Enum.map(requests, &{"request_upsert", &1})) do
            {:ok, conn} -> loop(conn, group_id, tenant_id)
            {:error, _reason} -> conn
          end

        {:error, reason} ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(500, Jason.encode!(%{error: inspect(reason)}))
      end
    else
      {:error, :not_found} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(404, Jason.encode!(%{error: "agent group not found"}))

      {:error, reason} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp loop(conn, group_id, tenant_id) do
    receive do
      {:capability_request_event, ^group_id, request_id} ->
        case CapabilityRequests.get(group_id, request_id, tenant_id) do
          {:ok, request} ->
            case emit(conn, "request_upsert", request) do
              {:ok, conn} -> loop(conn, group_id, tenant_id)
              {:error, _reason} -> conn
            end

          {:error, _reason} ->
            loop(conn, group_id, tenant_id)
        end
    after
      @heartbeat_ms ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> loop(conn, group_id, tenant_id)
          {:error, _reason} -> conn
        end
    end
  end

  defp emit_all(conn, []), do: {:ok, conn}

  defp emit_all(conn, [{event, data} | rest]) do
    case emit(conn, event, data) do
      {:ok, conn} -> emit_all(conn, rest)
      {:error, _reason} = err -> err
    end
  end

  defp emit(conn, event, data) do
    chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")
  end
end
