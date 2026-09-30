defmodule SalixIM.ConversationParticipantActivity do
  @moduledoc false

  alias SalixIM.Ports.SessionActivity

  import SalixIM.Provider.Util, only: [str: 1]

  @participant_realtime_key "_participant_realtime"

  def read(group_id, conversation_id, participant_id, participant) when is_map(participant) do
    if str(participant["actor_type"]) == "agent" do
      read_agent(group_id, conversation_id, participant_id, participant)
    else
      {:error, :participant_status_unavailable}
    end
  end

  def session_ref(participant) when is_map(participant) do
    agent_id = str(participant["agent_id"])
    session_id = participant |> Map.get("payload", %{}) |> session_id_from_payload()

    if str(participant["actor_type"]) != "agent" or not active_participant?(participant) or
         agent_id == "" or session_id == "",
       do: nil,
       else: {agent_id, session_id}
  end

  def session_ref(_participant), do: nil

  @doc false
  def session_snapshot(canonical, activity, draft) when is_map(canonical) do
    realtime =
      %{}
      |> put_optional("activity", activity)
      |> put_optional("draft", draft)

    if realtime == %{},
      do: canonical,
      else: Map.put(canonical, @participant_realtime_key, realtime)
  end

  defp read_agent(group_id, conversation_id, participant_id, participant) do
    case session_ref(participant) do
      nil ->
        reason =
          cond do
            not active_participant?(participant) -> :participant_status_unavailable
            str(participant["agent_id"]) == "" -> :agent_id_missing
            true -> :session_id_missing
          end

        {:error, reason}

      {agent_id, session_id} ->
        case SessionActivity.get(agent_id, session_id) do
          {:ok, activity} when is_map(activity) ->
            {:ok, status_result(group_id, conversation_id, participant_id, activity)}

          {:error, :not_found} ->
            {:error, :session_not_found}

          {:error, _reason} ->
            {:error, :runtime_unavailable}
        end
    end
  end

  def status_result(group_id, conversation_id, participant_id, session_snapshot)
      when is_binary(group_id) and is_binary(conversation_id) and is_binary(participant_id) and
             is_map(session_snapshot) do
    realtime = session_snapshot[@participant_realtime_key] || %{}

    canonical = Map.drop(session_snapshot, [@participant_realtime_key, "draft"])

    presentation_activity =
      case realtime["activity"] do
        %{} = candidate ->
          if exact_scope?(candidate, group_id, conversation_id, participant_id),
            do: presentation_activity(candidate),
            else: nil

        _other ->
          nil
      end

    draft =
      case realtime["draft"] do
        %{} = candidate ->
          if exact_scope?(candidate, group_id, conversation_id, participant_id),
            do: draft(candidate),
            else: nil

        _other ->
          nil
      end

    %{
      "conversation_id" => conversation_id,
      "participant_id" => participant_id,
      "activity" =>
        canonical
        |> Map.take(~w(state status updated_at issue))
        |> put_optional("working_provider", working_provider(canonical))
        |> put_optional("loop_wake", loop_wake(canonical))
    }
    |> put_optional("presentation_activity", presentation_activity)
    |> put_optional("wait", canonical["wait"])
    |> put_optional("issue", canonical["issue"])
    |> put_optional("draft", draft)
  end

  # One bounded activation, already owned by the runtime; never scan history or
  # expose provider source IDs. Mixed activations keep the generic presentation.
  defp working_provider(%{"state" => "active", "_active_source_message_ids" => sources})
       when is_list(sources) and sources != [] do
    case Enum.map(sources, &source_provider/1) |> Enum.uniq() do
      [provider] when provider in ["wechat", "telegram", "signal"] -> provider
      _ -> nil
    end
  end

  defp working_provider(_), do: nil

  # Keep the source IDs private. A mixed activation still represents chat work.
  defp loop_wake(%{"state" => "active", "_active_source_message_ids" => sources})
       when is_list(sources) and sources != [] do
    if Enum.all?(sources, &loop_source?/1), do: true, else: nil
  end

  defp loop_wake(_), do: nil

  defp loop_source?("loop:" <> source), do: source != ""
  defp loop_source?(_), do: false

  defp source_provider("im_provider:" <> source) do
    case String.split(source, ":", parts: 3) do
      [provider, connect_id, event_id]
      when provider in ["wechat", "telegram", "signal"] and connect_id != "" and event_id != "" ->
        provider

      _ ->
        nil
    end
  end

  defp source_provider(_), do: nil

  defp exact_scope?(candidate, group_id, conversation_id, participant_id) do
    candidate["agent_group_id"] == group_id and
      candidate["conversation_id"] == conversation_id and
      candidate["participant_id"] == participant_id
  end

  defp presentation_activity(%{} = activity) do
    Map.take(
      activity,
      ~w(phase status action summary summary_class goal tool_name display_strength display_priority display_hold_ms producer_epoch response_key sequence source_message_ids started_at completed_at updated_at)
    )
  end

  defp draft(%{} = draft) do
    case Map.take(
           draft,
           ~w(response_key revision status text source_message_ids created_at updated_at)
         ) do
      %{"response_key" => response_key} = public
      when is_binary(response_key) and response_key != "" ->
        public

      _other ->
        nil
    end
  end

  defp session_id_from_payload(payload) when is_map(payload), do: str(payload["session_id"])
  defp session_id_from_payload(_payload), do: ""

  defp active_participant?(participant) do
    str(participant["state"]) in ["", "active"]
  end

  defp put_optional(map, _key, value) when value in [nil, ""], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
