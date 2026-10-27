defmodule CommaWeb.AgentRequestEndpoints do
  @moduledoc """
  An Agent's requests to a person in a Comma Conversation, for the app's
  request cards: `/v1/comma/groups/:group/conversations/:conversation/requests*`.

  A request is a Capability Request (`SalixAgent.CapabilityRequests`), which
  owns its status, deadline and the winning outcome; these routes read and
  answer the ones a Conversation's Agent raised there (`surface_ref`). A member
  sees them when they may read the Conversation. Only the connect-account kind
  (`oauth_authorization`) has a card so far; its success is the verified OAuth
  callback, so a person here only opens the authorization page or declines.

  Bounds: a read lists only the Conversation's own requests (every pending one
  and the newest finished ones, at most 100 in all); a stream update reads one.
  A store that cannot be read fails the read, never answers with fewer cards.
  """

  require Logger
  require SystemsRuntime.Proc
  import Plug.Conn

  alias SalixAgent.CapabilityRequests

  @card_types ~w(oauth_authorization)

  def list(conn, group_id, conversation_id) do
    with_user(conn, fn user, session ->
      case scope(user, session, group_id, conversation_id) do
        {:ok, tenant_id} ->
          case requests(group_id, tenant_id, conversation_id) do
            {:ok, data} -> json(conn, 200, %{data: data})
            error -> error(conn, error)
          end

        error ->
          error(conn, error)
      end
    end)
  end

  @doc "The Conversation's requests now (`event: snapshot`), then each change (`event: request`)."
  def events(conn, group_id, conversation_id) do
    with_user(conn, fn user, session ->
      with {:ok, tenant_id} <- scope(user, session, group_id, conversation_id),
           {:ok, data} <- requests(group_id, tenant_id, conversation_id) do
        Phoenix.PubSub.subscribe(SalixWeb.PubSub, CapabilityRequests.topic(group_id))

        conn =
          conn
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        case chunk(conn, event("snapshot", %{data: data})) do
          {:ok, conn} ->
            SystemsClock.send_after(
              SystemsRuntime.Proc.self(),
              :agent_requests_tick,
              heartbeat_ms()
            )

            loop(conn, user, session, {group_id, tenant_id, conversation_id})

          {:error, _} ->
            conn
        end
      else
        error -> error(conn, error)
      end
    end)
  end

  def decline(conn, group_id, conversation_id, request_id) do
    with_user(conn, fn user, session ->
      with {:ok, tenant_id} <- scope(user, session, group_id, conversation_id),
           {:ok, request} <- CapabilityRequests.get(group_id, request_id, tenant_id),
           true <- shown_in?(request, conversation_id) || {:error, :not_found},
           {:ok, declined} <-
             CapabilityRequests.decline_oauth_authorization(group_id, request_id, tenant_id) do
        json(conn, 200, project(declined))
      else
        error -> error(conn, error)
      end
    end)
  end

  defp loop(conn, user, session, {group_id, tenant_id, conversation_id} = scope) do
    SystemsRuntime.Proc.receive do
      {:capability_request_event, ^group_id, request_id} ->
        with {:ok, request} <- CapabilityRequests.get(group_id, request_id, tenant_id),
             true <- shown_in?(request, conversation_id) do
          case chunk(conn, event("request", project(request))) do
            {:ok, conn} -> loop(conn, user, session, scope)
            {:error, _} -> conn
          end
        else
          _ -> loop(conn, user, session, scope)
        end

      # A timer, not quiet time, drives the recheck: steady event traffic
      # cannot postpone it.
      :agent_requests_tick ->
        with {:ok, ^tenant_id} <-
               scope(user, session, group_id, conversation_id),
             {:ok, _user, _session} <- Comma.Accounts.resolve_session_id(session["id"]),
             {:ok, conn} <- chunk(conn, ": heartbeat\n\n") do
          SystemsClock.send_after(
            SystemsRuntime.Proc.self(),
            :agent_requests_tick,
            heartbeat_ms()
          )

          loop(conn, user, session, scope)
        else
          _ -> conn
        end

      _other ->
        loop(conn, user, session, scope)
    end
  end

  defp scope(user, session, group_id, conversation_id) do
    case Comma.Conversations.authorize_read(user, session, group_id, conversation_id) do
      {:ok, %{"salix_tenant_id" => tenant_id}} when is_binary(tenant_id) -> {:ok, tenant_id}
      {:ok, _workspace} -> {:error, :not_found}
      error -> error
    end
  end

  defp requests(group_id, tenant_id, conversation_id) do
    with {:ok, records} <-
           CapabilityRequests.list_conversation(group_id, tenant_id, conversation_id) do
      {:ok,
       records
       |> Enum.filter(&shown_in?(&1, conversation_id))
       |> Enum.map(&project/1)}
    end
  end

  # A card shows the requests the Conversation's Agent raised there, of the kinds the app draws.
  defp shown_in?(
         %{
           "request_type" => type,
           "surface_kind" => "conversation",
           "surface_ref" => %{"conversation_id" => conversation_id}
         },
         conversation_id
       )
       when type in @card_types,
       do: true

  defp shown_in?(_request, _conversation_id), do: false

  # What a card needs, without the tenant, session, Agent and tool call it came from.
  defp project(request) do
    oauth = get_in(request, ["request_payload", "oauth_authorization"]) || %{}
    response = request["response_payload"] || %{}
    status = status(request)

    %{
      "id" => request["request_id"],
      "type" => request["request_type"],
      "status" => status,
      "outcome" => outcome(status, response),
      "expires_at" => request["expires_at"],
      "created_at" => request["created_at"],
      "updated_at" => request["updated_at"],
      "conversation_id" => get_in(request, ["surface_ref", "conversation_id"]),
      "source_message_id" => get_in(request, ["surface_ref", "message_id"]),
      "oauth" =>
        %{
          "provider" => oauth["provider"],
          "alias" => oauth["alias"],
          "reason" => oauth["reason"],
          "scopes" => List.wrap(oauth["scopes"])
        }
        # The page to authorize on matters only while the request waits.
        |> put_present("authorization_url", status == "pending" && oauth["authorization_url"])
        |> put_present("account", response["provider_account_name"])
    }
  end

  # A pending request past its deadline has expired, though nothing settled it yet.
  defp status(%{"status" => "pending", "expires_at" => expires_at})
       when is_integer(expires_at) do
    if SystemsClock.system_time(:second) >= expires_at, do: "expired", else: "pending"
  end

  defp status(%{"status" => status}) when is_binary(status), do: status
  defp status(_request), do: "pending"

  defp outcome("completed", %{"status" => "connected"}), do: "connected"
  defp outcome("completed", %{"status" => "declined"}), do: "declined"
  defp outcome("completed", %{"status" => "confirmed"}), do: "connected"
  defp outcome(_status, _response), do: nil

  defp put_present(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_present(map, _key, _value), do: map

  defp event(name, data), do: "event: #{name}\ndata: #{Jason.encode!(data)}\n\n"

  defp heartbeat_ms,
    do: SystemsRuntime.get_env(:comma_web, :agent_requests_heartbeat_ms, 25_000)

  defp with_user(conn, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        fun.(user, session)

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp error(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})
  defp error(conn, {:error, :forbidden}), do: json(conn, 403, %{error: "forbidden"})

  defp error(conn, {:error, {:bad_request, message}}) when is_binary(message),
    do: json(conn, 400, %{error: "bad_request", message: message})

  defp error(conn, {:error, {:conflict, _}}), do: json(conn, 409, %{error: "conflict"})

  defp error(conn, reason) do
    Logger.info("agent request route failed: #{inspect(reason) |> String.slice(0, 300)}")
    json(conn, 503, %{error: "temporarily_unavailable"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
