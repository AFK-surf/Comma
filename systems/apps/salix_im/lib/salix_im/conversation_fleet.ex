defmodule SalixIM.ConversationFleet do
  @moduledoc """
  Node-local spawn-on-demand helper for conversation owner actors.

  Cross-node placement happens before this module is called. This module only
  guarantees one local process for each group collection, conversation, or
  participant owner identity.

  A demand start can replace a dead owner before its supervisor handles the
  exit. The old child's automatic restart must then leave that replacement
  running instead of retrying an already registered identity.
  """

  alias SalixIM.{ConversationActor, ConversationGroupActor}

  @start_retry_attempts 5
  @start_retry_sleep_ms 10

  @spec ensure_started(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(group_id, conversation_id, opts \\ [])
      when is_binary(group_id) and is_binary(conversation_id) do
    with true <- SalixStore.Ids.valid_group_id?(group_id),
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id) do
      opts =
        opts
        |> Keyword.put(:group_id, group_id)
        |> Keyword.put(:conversation_id, conversation_id)

      start_child_or_lookup(
        ConversationActor.key(group_id, conversation_id),
        {ConversationActor, opts}
      )
    else
      false -> {:error, :invalid_conversation_owner_identity}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec ensure_group_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_group_started(group_id, opts \\ []) when is_binary(group_id) do
    if SalixStore.Ids.valid_group_id?(group_id) do
      opts = Keyword.put(opts, :group_id, group_id)

      start_child_or_lookup(
        ConversationGroupActor.key(group_id),
        {ConversationGroupActor, opts}
      )
    else
      {:error, :invalid_conversation_group_owner_identity}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec ensure_participant_started(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_participant_started(group_id, conversation_id, participant_id, opts \\ [])
      when is_binary(group_id) and is_binary(conversation_id) and is_binary(participant_id) do
    with true <- SalixStore.Ids.valid_group_id?(group_id),
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         true <- SalixStore.Ids.valid_participant_id?(participant_id) do
      opts =
        opts
        |> Keyword.put(:group_id, group_id)
        |> Keyword.put(:conversation_id, conversation_id)
        |> Keyword.put(:participant_id, participant_id)

      start_child_or_lookup(
        SalixIM.ConversationParticipantActor.key(group_id, conversation_id, participant_id),
        {SalixIM.ConversationParticipantActor, opts}
      )
    else
      false -> {:error, :invalid_conversation_participant_identity}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec running?(String.t(), String.t()) :: boolean()
  def running?(group_id, conversation_id) do
    Registry.lookup(
      SalixIM.ConversationRegistry,
      ConversationActor.key(group_id, conversation_id)
    ) != []
  end

  @spec stop(String.t(), String.t()) :: :ok
  def stop(group_id, conversation_id) do
    stop_participants(group_id, conversation_id)
    terminate_registered_child(ConversationActor.key(group_id, conversation_id))

    :ok
  catch
    :exit, _ -> :ok
  end

  @spec stop_participants(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_participants(group_id, conversation_id) do
    with :ok <- terminate_participant_children(group_id, conversation_id),
         [] <- participant_children(group_id, conversation_id) do
      :ok
    else
      [_pid | _rest] -> {:error, :participant_owners_still_running}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:participant_stop_exit, reason}}
  end

  defp terminate_registered_child(key) do
    case Registry.lookup(SalixIM.ConversationRegistry, key) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid)
      [] -> :ok
    end
  end

  defp terminate_participant_children(group_id, conversation_id) do
    group_id
    |> participant_children(conversation_id)
    |> Enum.reduce_while(:ok, fn pid, :ok ->
      case DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:participant_stop_failed, reason}}}
      end
    end)
  end

  defp participant_children(group_id, conversation_id) do
    match = {
      {SalixIM.ConversationParticipantActor.key(group_id, conversation_id, :"$1"), :"$2", :"$3"},
      [],
      [:"$2"]
    }

    SalixIM.ConversationRegistry
    |> Registry.select([match])
    |> Enum.filter(&Process.alive?/1)
  end

  defp start_child_or_lookup(key, child_spec),
    do: start_child_or_lookup(key, child_spec, @start_retry_attempts)

  @doc false
  def start_owner_link({module, function, args}) do
    case apply(module, function, args) do
      {:error, {:already_started, _pid}} -> :ignore
      result -> result
    end
  end

  defp start_child_or_lookup(key, child_spec, attempts_left) do
    spec = Supervisor.child_spec(child_spec, [])
    spec = %{spec | start: {__MODULE__, :start_owner_link, [spec.start]}}

    case DynamicSupervisor.start_child(SalixIM.ConversationFleetSup, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      result when result in [:ignore, {:error, :already_present}] ->
        case Registry.lookup(SalixIM.ConversationRegistry, key) do
          [{pid, _}] ->
            {:ok, pid}

          [] when attempts_left > 0 ->
            Process.sleep(@start_retry_sleep_ms)
            start_child_or_lookup(key, child_spec, attempts_left - 1)

          [] ->
            {:error, :owner_start_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
