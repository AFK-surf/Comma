defmodule SalixAgent.Activity do
  @moduledoc """
  Agent activity projection public API.
  """

  alias SalixAgent.{Control, Runtime}

  def list(tenant_id) do
    tenant_id
    |> Control.list()
    |> list_agents()
  end

  def list_agents(agents) when is_list(agents) do
    agents
    |> Enum.flat_map(&agent_activities/1)
    |> Enum.sort_by(&{&1["updated_at"] || 0, &1["agent_id"] || "", &1["session_id"] || ""}, :desc)
  end

  @doc """
  Activity snapshot scoped to a single agent's sessions. Used by the agent-scoped
  endpoints (`/v1/runtime/agents/:id/activities*`) so a shared-tenant proxy never
  exposes other agents' activity.
  """
  def list_agent(%{"agent_id" => _agent_id} = agent) do
    agent
    |> agent_activities()
    |> Enum.sort_by(&{&1["updated_at"] || 0, &1["session_id"] || ""}, :desc)
  end

  defp agent_activities(%{"agent_id" => agent_id} = agent) do
    case Runtime.list_sessions(agent, include_hidden: true) do
      {:ok, sessions} ->
        sessions
        |> Enum.flat_map(fn session ->
          case session_activity(agent_id, session_value(session, "session_id"), session) do
            nil -> []
            activity -> [activity]
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp session_activity(agent_id, session_id, session) do
    state = session_activity_state(session)

    if state in ["idle", "paused", "ready"] do
      nil
    else
      updated_at =
        session_value(session, "activity_status_updated_at") ||
          session_value(session, "status_updated_at") || 0

      %{
        "agent_id" => agent_id,
        "session_id" => session_id,
        "phase" => activity_phase(state),
        "status" => activity_runtime_status(state),
        "summary" => session_activity_summary(session, state),
        "sequence" => session_value(session, "next_message_id") || 0,
        "updated_at" => updated_at
      }
    end
  end

  defp session_activity_summary(session, "waiting") do
    case session_wait(session) do
      wait when is_map(wait) -> wait_value(wait, "reason") || "Waiting"
      _ -> "Agent is active"
    end
  end

  defp session_activity_summary(_session, "starting"), do: "Agent is starting"
  defp session_activity_summary(_session, "thinking"), do: "Agent is thinking"
  defp session_activity_summary(_session, "execution"), do: "Agent is executing a tool"
  defp session_activity_summary(_session, "messaging"), do: "Agent is composing a message"
  defp session_activity_summary(_session, "failed"), do: "Agent runtime failed"
  defp session_activity_summary(_session, "unknown"), do: "Agent runtime status is unknown"
  defp session_activity_summary(_session, "queued"), do: "Agent work is queued"
  defp session_activity_summary(_session, _state), do: "Agent is active"

  defp session_wait(%{wait: wait}) when is_map(wait), do: wait
  defp session_wait(%{"wait" => wait}) when is_map(wait), do: wait
  defp session_wait(_), do: nil

  defp session_activity_state(session) do
    cond do
      session_value(session, "runtime_kind") == "external" and
          session_value(session, "status") in [
            "starting",
            "running",
            "waiting",
            "failed",
            "unknown",
            "idle"
          ] ->
        session_value(session, "status")

      is_map(session_wait(session)) ->
        "waiting"

      session_value(session, "activity_status") == "active" ->
        "running"

      session_value(session, "activity_status") in [
        "starting",
        "running",
        "thinking",
        "execution",
        "messaging",
        "waiting",
        "failed",
        "unknown",
        "paused"
      ] ->
        session_value(session, "activity_status")

      session_value(session, "status") in ["active", "running"] ->
        "running"

      session_value(session, "status") == "queued" ->
        "queued"

      session_value(session, "status") in ["waiting"] ->
        "waiting"

      true ->
        "paused"
    end
  end

  defp activity_phase("waiting"), do: "execution"
  defp activity_phase("failed"), do: "idle"
  defp activity_phase(state), do: state

  defp activity_runtime_status(state) when state in ["thinking", "execution", "messaging"],
    do: "running"

  defp activity_runtime_status(state), do: state

  defp wait_value(wait, key) when is_map(wait) do
    Map.get(wait, key) || Map.get(wait, to_string(key)) || Map.get(wait, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp session_value(session, key) when is_map(session) do
    Map.get(session, key) || Map.get(session, to_string(key)) ||
      Map.get(session, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end
end
