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

  require SystemsRuntime.Proc, as: Proc

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
    SystemsRuntime.Registry.lookup(
      SalixIM.ConversationRegistry,
      ConversationActor.key(group_id, conversation_id)
    ) != []
  end

  @doc """
  Group collection, conversation, and participant owners registered on this
  node, as `{registry_key, pid}`. A node-local registry read with no storage
  or remote I/O.
  """
  @spec local_owners() :: [{tuple(), pid()}]
  def local_owners do
    SystemsRuntime.Registry.select(SalixIM.ConversationRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.filter(fn {key, _pid} -> owner_key?(key) end)
  end

  @doc """
  Asks a local owner to exit once it can do so safely, because placement now
  names another node. Each owner finishes its current work first:

    * a group collection or conversation owner stops after its current command;
    * a conversation owner that is cleaning up a deletion keeps cleaning up;
    * a participant owner finishes an in-flight provider delivery first.

  A normal exit is not restarted (`:transient`). Subscribers monitor the owner,
  so their streams end and reconnect through current placement with a resync.
  Durable work left behind resumes on the current owner.
  """
  @spec release(pid()) :: :ok
  def release(pid) when Proc.is_process(pid) do
    Proc.send(pid, :release_non_owner)
    :ok
  end

  defp owner_key?({:conversation_group, _group_id}), do: true
  defp owner_key?({:conversation, _group_id, _conversation_id}), do: true

  defp owner_key?({:conversation_participant, _group_id, _conversation_id, _participant_id}),
    do: true

  defp owner_key?(_key), do: false

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
    case SystemsRuntime.Registry.lookup(SalixIM.ConversationRegistry, key) do
      [{pid, _}] ->
        SystemsRuntime.DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid)

      [] ->
        :ok
    end
  end

  defp terminate_participant_children(group_id, conversation_id) do
    group_id
    |> participant_children(conversation_id)
    |> Enum.reduce_while(:ok, fn pid, :ok ->
      case SystemsRuntime.DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid) do
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
    |> SystemsRuntime.Registry.select([match])
    |> Enum.filter(&Proc.alive?/1)
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

    case SystemsRuntime.DynamicSupervisor.start_child(SalixIM.ConversationFleetSup, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      result when result in [:ignore, {:error, :already_present}] ->
        case SystemsRuntime.Registry.lookup(SalixIM.ConversationRegistry, key) do
          [{pid, _}] ->
            {:ok, pid}

          [] when attempts_left > 0 ->
            SystemsClock.sleep(@start_retry_sleep_ms)
            start_child_or_lookup(key, child_spec, attempts_left - 1)

          [] ->
            {:error, :owner_start_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
