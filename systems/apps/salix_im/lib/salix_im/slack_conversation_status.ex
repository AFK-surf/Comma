defmodule SalixIM.SlackConversationStatus do
  @moduledoc false

  alias SalixIM.{
    ConversationParticipantActivity,
    ConversationParticipantProjection,
    Conversations
  }

  alias SalixIM.Ports.SessionActivity

  import SalixIM.Provider.Util, only: [int_or: 2, str: 1]

  @max_status_length 96
  @separator " | "

  @spec project(String.t(), String.t(), String.t(), MapSet.t()) ::
          {:ok, String.t(), MapSet.t(), MapSet.t()}
          | {:unknown, MapSet.t() | :preserve, MapSet.t()}
  def project(group_id, conversation_id, excluded_agent_id, subscribed_sessions) do
    case ConversationParticipantProjection.list_bounded(group_id, conversation_id) do
      {:ok, participants} ->
        project_participants(
          group_id,
          conversation_id,
          participants,
          excluded_agent_id,
          subscribed_sessions
        )

      {:error, :not_found} ->
        {:ok, "", MapSet.new(), subscribed_sessions}

      {:error, _reason} ->
        {:unknown, :preserve, subscribed_sessions}
    end
  end

  defp project_participants(
         group_id,
         conversation_id,
         participants,
         excluded_agent_id,
         subscribed_sessions
       ) do
    workers =
      participants
      |> Enum.filter(&worker?(&1, excluded_agent_id))
      |> Enum.sort_by(&{int_or(&1["created_at"], 0), str(&1["participant_id"])})

    session_refs =
      workers
      |> Enum.map(&ConversationParticipantActivity.session_ref/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    with {:ok, subscribed_sessions} <- subscribe(session_refs, subscribed_sessions),
         {:ok, statuses} <-
           Conversations.group_conversation_participant_statuses(
             group_id,
             conversation_id,
             workers
           ) do
      projections =
        Enum.map(workers, fn participant ->
          status = Map.get(statuses, str(participant["participant_id"]), %{})
          {participant, activity_state(status), activity_status(status)}
        end)

      cond do
        Enum.any?(projections, fn {_participant, state, _status} -> state == "" end) ->
          {:unknown, session_refs, subscribed_sessions}

        true ->
          visible =
            Enum.reject(projections, fn {_participant, state, _status} -> state == "stopped" end)

          {:ok, render(visible), session_refs, subscribed_sessions}
      end
    else
      {:error, subscribed_sessions} -> {:unknown, session_refs, subscribed_sessions}
    end
  end

  defp worker?(participant, excluded_agent_id) when is_map(participant) do
    agent_id = str(participant["agent_id"])

    str(participant["actor_type"]) == "agent" and agent_id != "" and
      agent_id != str(excluded_agent_id)
  end

  defp worker?(_participant, _excluded_agent_id), do: false

  defp subscribe(session_refs, subscribed_sessions) do
    session_refs
    |> MapSet.difference(subscribed_sessions)
    |> Enum.reduce_while({:ok, subscribed_sessions}, fn
      {agent_id, session_id} = session_ref, {:ok, subscribed} ->
        case SessionActivity.subscribe(agent_id, session_id) do
          :ok -> {:cont, {:ok, MapSet.put(subscribed, session_ref)}}
          {:error, _reason} -> {:halt, {:error, subscribed}}
        end
    end)
  end

  defp activity_state(status), do: status |> get_in(["activity", "state"]) |> str()
  defp activity_status(status), do: status |> get_in(["activity", "status"]) |> str()

  defp render(projections) do
    segments =
      Enum.map(projections, fn {participant, _state, status} ->
        "#{worker_name(participant)} #{status}"
      end)

    {shown, shown_count} =
      Enum.reduce_while(segments, {[], 0}, fn segment, {shown, count} ->
        if status_length(shown ++ [segment]) <= @max_status_length do
          {:cont, {shown ++ [segment], count + 1}}
        else
          {:halt, {shown, count}}
        end
      end)

    add_hidden_suffix(shown, length(segments) - shown_count)
  end

  defp add_hidden_suffix(shown, 0), do: Enum.join(shown, @separator)

  defp add_hidden_suffix(shown, hidden) do
    suffix = "+#{hidden} more"

    if status_length(shown ++ [suffix]) <= @max_status_length do
      Enum.join(shown ++ [suffix], @separator)
    else
      {_removed, kept} = List.pop_at(shown, -1)
      add_hidden_suffix(kept, hidden + 1)
    end
  end

  defp worker_name(participant) do
    name = str(participant["agent_name"])
    name = if name == "", do: str(participant["agent_id"]), else: name
    name = name |> String.replace(~r/[|\s]+/, " ") |> String.trim()

    if String.length(name) <= 24,
      do: name,
      else: String.slice(name, 0, 21) <> "..."
  end

  defp status_length(segments), do: segments |> Enum.join(@separator) |> String.length()
end
