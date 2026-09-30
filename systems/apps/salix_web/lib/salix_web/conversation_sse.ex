defmodule SalixWeb.ConversationSSE do
  @moduledoc """
  Canonical Group Conversation mutation stream under
  `/v1/runtime/agent-groups/:id/conversations/events`.

  The endpoint subscribes to the exact Group owner. Successful Conversation
  commits publish one mutation hint there; this process then performs only the
  exact bounded read needed to render that event. It never scans a Group or
  polls Conversation records.

  This stream carries stored `conversation_upsert`, `conversation_delete`, and
  `message_created` facts only. Realtime activity and draft presentation remain
  on the independent exact Participant subscription boundary.
  """

  import Plug.Conn

  alias SalixIM.{ConversationServer, Conversations}

  @heartbeat_ms 5_000

  @spec serve_group(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def serve_group(conn, group_id) do
    case ConversationServer.subscribe_group_conversation_mutations(group_id, self()) do
      {:ok, %{"owner_pid" => owner_pid, "version" => version}}
      when is_pid(owner_pid) and is_binary(version) ->
        owner_ref = Process.monitor(owner_pid)

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        case emit(
               conn,
               "resync_required",
               %{"group_id" => group_id, "version" => version},
               version
             ) do
          {:ok, conn} -> loop(conn, group_id, owner_ref)
          {:error, _reason} -> conn
        end

      {:error, :not_found} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(404, Jason.encode!(%{error: "agent group not found"}))

      {:error, reason} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(503, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp loop(conn, group_id, owner_ref) do
    receive do
      {:group_conversation_mutated, ^group_id, mutation, version} ->
        case safe_event(group_id, mutation) do
          {:ok, event, data} ->
            case emit(conn, event, data, version) do
              {:ok, conn} -> loop(conn, group_id, owner_ref)
              {:error, _reason} -> conn
            end

          {:error, _reason} ->
            # The mutation is only an invalidation hint. If its exact canonical
            # reread cannot be completed, keeping this generation connected
            # would silently lose freshness. Closing forces the next request
            # through the resync_required snapshot fence.
            conn
        end

      {:DOWN, ^owner_ref, :process, _owner_pid, _reason} ->
        conn

      _other ->
        loop(conn, group_id, owner_ref)
    after
      @heartbeat_ms ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> loop(conn, group_id, owner_ref)
          {:error, _reason} -> conn
        end
    end
  end

  defp safe_event(group_id, mutation) do
    event(group_id, mutation)
  rescue
    _exception -> {:error, :canonical_reread_failed}
  catch
    :exit, _reason -> {:error, :canonical_reread_failed}
  end

  defp event(group_id, %{
         event: :conversation_upsert,
         conversation_id: conversation_id
       }) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, conversation} -> {:ok, "conversation_upsert", conversation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event(_group_id, %{
         event: :conversation_delete,
         conversation_id: conversation_id
       }) do
    {:ok, "conversation_delete", %{"conversation_id" => conversation_id}}
  end

  defp event(group_id, %{
         event: :message_created,
         conversation_id: conversation_id,
         message_id: message_id
       }) do
    case Conversations.get_group_conversation_message(group_id, conversation_id, message_id) do
      {:ok, message} ->
        {:ok, "message_created", Map.put(message, "conversation_id", conversation_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp event(_group_id, _mutation), do: {:error, :invalid_mutation}

  defp emit(conn, event, data, version) do
    chunk(conn, "id: #{version}\nevent: #{event}\ndata: #{Jason.encode!(data)}\n\n")
  end
end
