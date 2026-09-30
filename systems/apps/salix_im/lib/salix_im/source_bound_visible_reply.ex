defmodule SalixIM.SourceBoundVisibleReply do
  @moduledoc """
  Exact Participant-draft scope authorization for internal `user_chat`.

  Draft state is transient. Canonical Messages are authored only through an
  explicit provider send and carry no draft activation identity. Their optional
  reply_to_message_id is a separate canonical reference. `append/2` is a
  rolling fail-closed shim for an older caller; it never writes a Message.
  """

  alias SalixIM.{ConversationSourceIdentity, GroupDirectory}

  @spec authorize(String.t(), map()) :: :ok | {:error, term()}
  def authorize(agent_id, scope) when is_binary(agent_id) and is_map(scope) do
    with {:ok, agent_scope} <- GroupDirectory.scope_for_agent(agent_id),
         true <- agent_scope.group_id == scope["agent_group_id"],
         "internal" <- scope["provider"],
         "user_chat" <- scope["conversation_kind"],
         "user" <- scope["source_actor_type"],
         :ok <-
           SalixIM.ConversationServer.authorize_source_reply(
             agent_scope.group_id,
             scope["conversation_id"],
             agent_id,
             scope
           ) do
      :ok
    else
      false -> permanent(:visible_reply_scope_mismatch)
      {:error, reason} -> classify_error(reason)
      _ -> permanent(:visible_reply_scope_mismatch)
    end
  end

  def authorize(_agent_id, _scope), do: permanent(:invalid_visible_reply_scope)

  @spec append(String.t(), map()) :: {:error, {:permanent, :retired_visible_reply_append}}
  def append(_agent_id, _intent), do: permanent(:retired_visible_reply_append)

  @doc false
  def authorize_snapshot(agent_id, scope, conversation, participants, fetch_message) do
    participant = Enum.find(participants, &(&1["participant_id"] == scope["participant_id"]))
    entries = scope["source_messages"]
    source_ids = scope["source_message_ids"]

    with true <- conversation["kind"] == "user_chat",
         true <- is_map(participant) and active_agent_participant?(participant, agent_id),
         :ok <- validate_sources(scope, entries, source_ids, fetch_message),
         true <- Enum.any?(participants, &active_user_participant?/1) do
      :ok
    else
      false -> {:error, :visible_reply_scope_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :visible_reply_source_mismatch}
    end
  end

  defp validate_sources(scope, entries, source_ids, fetch_message) do
    with true <- is_list(entries) and entries != [],
         true <-
           is_list(source_ids) and source_ids == Enum.map(entries, & &1["source_message_id"]) do
      validate_source_entries(
        scope["conversation_id"],
        scope["participant_id"],
        entries,
        fetch_message
      )
    else
      _ -> {:error, :visible_reply_source_mismatch}
    end
  end

  defp validate_source_entries(conversation_id, participant_id, entries, fetch_message) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case validate_source_entry(conversation_id, participant_id, entry, fetch_message) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_source_entry(conversation_id, participant_id, entry, fetch_message) do
    with source_id when is_binary(source_id) <- entry["source_message_id"],
         message_id when is_binary(message_id) <- entry["message_id"],
         {:ok, %{message_id: ^message_id, participant_id: ^participant_id}} <-
           ConversationSourceIdentity.decode(source_id, conversation_id) do
      case fetch_message.(message_id) do
        {:ok, %{"actor_type" => "user", "message_id" => ^message_id}} ->
          :ok

        {:error, :not_found} ->
          {:error, :visible_reply_source_mismatch}

        {:error, _} = error ->
          error

        _ ->
          {:error, :visible_reply_source_mismatch}
      end
    else
      _ -> {:error, :visible_reply_source_mismatch}
    end
  end

  defp active_agent_participant?(participant, agent_id) do
    participant["actor_type"] == "agent" and participant["agent_id"] == agent_id and
      participant["state"] != "inactive" and is_nil(participant["deleted_at"])
  end

  defp active_user_participant?(participant) do
    participant["actor_type"] == "user" and participant["state"] != "inactive" and
      is_nil(participant["deleted_at"])
  end

  defp classify_error(reason)
       when reason in [
              :not_found,
              :invalid_visible_reply_intent,
              :invalid_visible_reply_scope,
              :visible_reply_scope_mismatch,
              :visible_reply_source_mismatch
            ],
       do: permanent(reason)

  defp classify_error({:bad_request, _detail} = reason), do: permanent(reason)
  defp classify_error(reason), do: {:error, reason}

  defp permanent(reason), do: {:error, {:permanent, reason}}
end
