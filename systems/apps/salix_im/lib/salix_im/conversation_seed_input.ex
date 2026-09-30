defmodule SalixIM.ConversationSeedInput do
  @moduledoc """
  Canonical seed/import adapter shared by runtime imports and storage cutovers.

  It resolves participant identities and sender references before the exact
  conversation owner validates and persists canonical facts.
  """

  alias SalixIM.{
    AgentDeliveryPayload,
    ConversationParticipantProjection,
    Conversations,
    GroupDirectory
  }

  alias SalixStore.Ids

  @participant_limit SalixIM.ConversationLimits.participant_limit()

  def prepare(group_id, conversation_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    now = timestamp(attrs["created_at"] || System.system_time(:millisecond))
    conversation = attrs["conversation"] || %{}
    kind = nonblank(conversation["kind"] || attrs["kind"], "user_chat")

    with true <- kind in ["user_chat", "agent_task"],
         participants when is_list(participants) <- conversation["participants"],
         true <- length(participants) <= @participant_limit,
         {:ok, group} <- GroupDirectory.get_group(group_id),
         conversation <-
           conversation
           |> Map.put("conversation_id", conversation_id)
           |> Map.put("kind", kind)
           |> Map.put(
             "title",
             nonblank(conversation["title"] || conversation["name"], "Conversation")
           )
           |> Map.put("created_at", timestamp(conversation["created_at"] || now))
           |> Map.put("updated_at", timestamp(conversation["updated_at"] || now))
           |> Map.put_new("status", "active")
           |> Map.put_new("activity_status", "idle"),
         {:ok, existing} <- existing_participants(group_id, conversation_id),
         {:ok, participants} <-
           prepare_participants(group, conversation, participants, existing, now),
         {:ok, messages} <-
           prepare_messages(attrs["messages"], participants, conversation_id, now) do
      {:ok,
       attrs
       |> Map.put(
         "conversation",
         conversation
         |> Map.put("participants", participants)
         |> Map.put_new("created_by_agent_id", first_agent_id(participants))
       )
       |> Map.put("messages", messages)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:bad_request, "invalid seed participants or messages"}}
    end
  end

  defp existing_participants(group_id, conversation_id) do
    case Conversations.get_group_conversation_record(group_id, conversation_id) do
      {:ok, _conversation} ->
        ConversationParticipantProjection.list_bounded(group_id, conversation_id)

      {:error, :not_found} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_participants(group, conversation, participants, existing, now) do
    participants
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      participant = raw |> stringify() |> reuse_identity(existing)
      actor_type = trim(participant["actor_type"])
      preallocated? = trim(participant["participant_id"]) != ""

      valid? =
        actor_type in ["user", "agent", "provider"] and
          (actor_type != "agent" or trim(participant["agent_id"]) != "") and
          (actor_type != "provider" or
             (trim(participant["provider"]) != "" and trim(participant["target_key"]) != ""))

      with true <- valid?,
           true <- not preallocated? or Ids.valid_participant_id?(participant["participant_id"]),
           {:ok, participant} <-
             prepare_participant_payload(group, conversation, participant, preallocated?) do
        prepared =
          participant
          |> Map.put_new("participant_id", Ids.new_participant_id())
          |> Map.put("conversation_id", conversation["conversation_id"])
          |> Map.put("actor_type", actor_type)
          |> Map.put_new("user_id", if(actor_type == "user", do: "current"))
          |> Map.put_new("state", "active")
          |> Map.put_new("notification_filter", %{
            "messages" => "all",
            "statuses" => "none"
          })
          |> Map.put_new("created_at", now)
          |> Map.put_new("updated_at", now)
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        {:cont, {:ok, [prepared | acc]}}
      else
        false -> {:halt, {:error, :invalid_participant}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)

        if unique_participants?(prepared),
          do: {:ok, prepared},
          else: {:error, :duplicate_seed_participant}

      {:error, _reason} = error ->
        error
    end
  end

  defp reuse_identity(participant, existing) do
    case Enum.find(existing, &(participant_target(&1) == participant_target(participant))) do
      nil ->
        participant

      current ->
        participant
        |> Map.put("participant_id", current["participant_id"])
        |> Map.put("conversation_id", current["conversation_id"])
        |> Map.put("payload", current["payload"])
        |> Map.put_new("agent_name", current["agent_name"])
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp prepare_participant_payload(
         group,
         conversation,
         %{"actor_type" => "agent"} = participant,
         preallocated?
       ) do
    if preallocated? do
      {:ok, participant}
    else
      with {:ok, %{"group_id" => group_id} = agent} <-
             GroupDirectory.get_agent(participant["agent_id"]),
           true <- group_id == group["group_id"],
           {:ok, payload} <-
             AgentDeliveryPayload.materialize_participant_payload(
               group,
               agent,
               conversation,
               participant,
               preallocated: true
             ) do
        {:ok,
         participant
         |> Map.put_new("agent_name", agent["name"])
         |> Map.put("payload", payload)}
      else
        false -> {:error, :agent_outside_seed_group}
        {:error, _reason} = error -> error
      end
    end
  end

  defp prepare_participant_payload(_group, _conversation, participant, _preallocated?),
    do: {:ok, participant}

  defp unique_participants?(participants) do
    ids = Enum.map(participants, & &1["participant_id"])
    targets = Enum.map(participants, &participant_target/1)
    ids == Enum.uniq(ids) and targets == Enum.uniq(targets)
  end

  defp participant_target(%{"actor_type" => "agent"} = participant),
    do: {"agent", participant["agent_id"]}

  defp participant_target(%{"actor_type" => "user"} = participant),
    do: {"user", nonblank(participant["user_id"], "current")}

  defp participant_target(%{"actor_type" => "provider"} = participant),
    do: {"provider", participant["provider"], participant["target_key"]}

  defp participant_target(participant),
    do: {"invalid", participant["actor_type"], participant["participant_id"]}

  defp prepare_messages(messages, participants, conversation_id, now) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      message =
        raw
        |> stringify()
        |> Map.delete("dispatch_targets")
        |> Map.put_new("client_request_id", "seed:#{conversation_id}:#{index}")
        |> Map.update("created_at", now + index, &timestamp/1)

      case message_participant(participants, message) do
        %{"participant_id" => participant_id} ->
          {:cont, {:ok, [Map.put(message, "participant_id", participant_id) | acc]}}

        _ ->
          {:halt, {:error, :seed_message_participant_not_found}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, prepared |> Enum.reverse() |> Enum.sort_by(& &1["created_at"])}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_messages(_messages, _participants, _conversation_id, _now),
    do: {:error, :invalid_messages}

  defp message_participant(participants, message) do
    case trim(message["participant_id"]) do
      id when id != "" ->
        Enum.find(participants, &(&1["participant_id"] == id))

      _ ->
        actor_type = message["actor_type"] || "user"

        Enum.find(participants, fn participant ->
          case actor_type do
            "agent" ->
              participant["actor_type"] == "agent" and
                trim(participant["agent_id"]) == trim(message["agent_id"])

            "user" ->
              participant["actor_type"] == "user" and
                nonblank(participant["user_id"], "current") ==
                  nonblank(message["user_id"], "current")

            provider when provider in ["provider_user", "provider_system"] ->
              participant["actor_type"] == "provider" and
                (trim(message["provider"]) == "" or
                   participant["provider"] == message["provider"])

            _ ->
              false
          end
        end)
    end
  end

  defp timestamp(value) when is_integer(value),
    do: if(value > 99_999_999_999, do: value, else: value * 1000)

  defp timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        timestamp(integer)

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> 0
        end
    end
  end

  defp timestamp(_value), do: 0

  defp first_agent_id(participants),
    do: Enum.find_value(participants, &if(&1["actor_type"] == "agent", do: &1["agent_id"]))

  defp nonblank(value, fallback), do: if(trim(value) == "", do: fallback, else: trim(value))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
