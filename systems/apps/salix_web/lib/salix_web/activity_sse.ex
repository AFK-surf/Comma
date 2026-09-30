defmodule SalixWeb.ActivitySSE do
  @moduledoc """
  Live agent-activity event streams. Emits `activity` events as the runtime
  publishes fine-grained activity signals (thinking / tool execution / messaging
  / idle — see `SalixAgent.ActivityEvent`) so clients can render intermediate
  state in the gap between a user's message and the committed reply. On connect it
  first replays the current snapshot, then streams live deltas.

  Two scopes:

    * `serve_agent/2` — a single agent (`/v1/runtime/agents/:id/activities/
      stream`). This is what the Commaboard proxy targets: it shares one salix
      tenant across users and scopes by agent, so a tenant-wide feed would leak
      other users' activity.
    * `serve/2` — every agent in a tenant (`/v1/runtime/agent-activities/
      stream`), for tenant-scoped dashboards.

  This agent diagnostics surface subscribes to the agents' `agent:{id}` PubSub
  topics and forwards `{:activity, _}` notifications. Product conversation
  surfaces do not consume it: they subscribe to the exact Conversation
  Participant, which owns the public realtime status. The tenant scope also
  re-discovers agents on a periodic poll so agents created mid-stream are picked
  up; both scopes use the poll as a keepalive.
  """

  import Plug.Conn

  alias SalixAgent.{Activity, Control}

  @poll_ms 5_000
  # 3 quiet polls ≈ a 15s keepalive comment.
  @quiet_polls_per_heartbeat 3

  @spec serve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def serve(conn, tenant_id) do
    agents = safe_list_agents(tenant_id)
    scope = %{tenant_id: tenant_id, snapshot: fn -> Activity.list_agents(agents) end}
    start(conn, scope, agent_routes(agents))
  end

  @spec serve_agent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def serve_agent(conn, %{"agent_id" => agent_id, "group_id" => group_id} = agent) do
    routes = %{agent_id => group_id}
    scope = %{tenant_id: nil, snapshot: fn -> Activity.list_agent(agent) end}
    start(conn, scope, routes)
  end

  defp start(conn, scope, routes) do
    Enum.each(topics(routes), &Phoenix.PubSub.subscribe(SalixWeb.PubSub, &1))

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case emit_all(conn, snapshot_events(scope, routes)) do
      {:ok, conn} -> loop(conn, scope, routes, 0)
      {:error, _} -> conn
    end
  end

  # `routes` tracks the agents whose PubSub topics belong to this stream.
  defp loop(conn, scope, routes, quiet_polls) do
    receive do
      {:salix_agent_event, agent_id, {:activity, activity}} ->
        case emit_all(conn, [{"activity", enrich(activity, agent_id, routes)}]) do
          {:ok, conn} -> loop(conn, scope, routes, 0)
          {:error, _} -> conn
        end

      # Any other agent event (deltas, drafts, settle) is not an activity signal.
      {:salix_agent_event, _agent_id, _event} ->
        loop(conn, scope, routes, quiet_polls)
    after
      @poll_ms ->
        tick(conn, scope, routes, quiet_polls)
    end
  end

  # On a quiet boundary, re-discover agents (tenant scope only) and send a
  # keepalive comment so idle connections stay open through proxies.
  defp tick(conn, scope, routes, quiet_polls) do
    if quiet_polls + 1 >= @quiet_polls_per_heartbeat do
      routes = resubscribe(scope, routes)

      case chunk(conn, ": heartbeat\n\n") do
        {:ok, conn} -> loop(conn, scope, routes, 0)
        {:error, _} -> conn
      end
    else
      loop(conn, scope, routes, quiet_polls + 1)
    end
  end

  # Only the tenant scope grows its agent set over time.
  defp resubscribe(%{tenant_id: nil}, routes), do: routes

  defp resubscribe(%{tenant_id: tenant_id}, routes) do
    new_routes = safe_agent_routes(tenant_id, routes)

    Enum.each(topics(new_routes) -- topics(routes), fn topic ->
      Phoenix.PubSub.subscribe(SalixWeb.PubSub, topic)
    end)

    new_routes
  end

  defp snapshot_events(scope, routes) do
    scope
    |> safe_snapshot()
    |> Enum.map(fn activity ->
      {"activity", enrich(activity, activity["agent_id"], routes)}
    end)
  end

  defp safe_snapshot(scope) do
    scope.snapshot.()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp enrich(activity, _agent_id, _routes), do: activity

  defp agent_routes(agents) do
    agents
    |> Enum.reduce(%{}, fn agent, acc ->
      case agent["agent_id"] do
        id when is_binary(id) and id != "" -> Map.put(acc, id, agent["group_id"])
        _ -> acc
      end
    end)
  end

  defp safe_agent_routes(tenant_id, fallback) do
    tenant_id
    |> safe_list_agents()
    |> agent_routes()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp safe_list_agents(tenant_id) do
    Control.list(tenant_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp topics(routes) do
    routes
    |> Map.keys()
    |> Enum.map(&SalixWeb.PubSubNotifier.topic/1)
  end

  defp emit_all(conn, events) do
    Enum.reduce_while(events, {:ok, conn}, fn {event, data}, {:ok, conn} ->
      payload = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

      case chunk(conn, payload) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
