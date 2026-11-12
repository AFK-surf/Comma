defmodule SalixIM.ConversationStore do
  @moduledoc """
  Private stateful persistence capability owned by one ConversationActor.

  Only the owner PID may call this store. PostgreSQL commits Conversation
  metadata and Messages; a frozen Pending retains an unknown transaction.
  """

  use SystemsRuntime.Server
  alias SystemsRuntime.Proc
  alias SalixIM.ConversationPGStore
  alias SalixStore.Repo

  @call_timeout :infinity
  defstruct [:owner, :owner_ref, :group_id, :conversation_id, :scope, :pending]

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)
  def load(pid), do: call(pid, :load)
  def resident_snapshot(pid), do: call(pid, :load)
  def load_raw(pid), do: call(pid, :load_raw)
  def source_snapshot(pid), do: call(pid, :source_snapshot)
  def put_new(pid, record), do: call(pid, {:put_new, record})

  def put_new_with_message(pid, record, message),
    do: call(pid, {:put_new_with_message, record, message})

  def update(pid, fun), do: call(pid, {:update, fun})
  def update_with_previous(pid, fun), do: call(pid, {:update_with_previous, fun})
  def tombstone(pid, record), do: call(pid, {:tombstone, record})
  def reserve_message(pid, message), do: call(pid, {:reserve_message, message})
  def append_message(pid, message), do: call(pid, {:append_message, message})
  def message_by_id(pid, id), do: call(pid, {:message_by_id, id})

  def message_by_request_identity(pid, identity),
    do: call(pid, {:message_by_request_identity, identity})

  def identity_by_request_identity(pid, identity),
    do: call(pid, {:identity_by_request_identity, identity})

  def identity_by_id(pid, id), do: call(pid, {:identity_by_id, id})
  def recover_log(pid, target), do: call(pid, {:recover_log, target})
  def settle_pending(pid), do: call(pid, :settle_pending)
  def archive_messages(pid, limit), do: call(pid, {:archive_messages, limit})
  def cleanup_archive_bodies(pid, limit), do: call(pid, {:cleanup_archive_bodies, limit})

  def backfill_message_threads(pid, after_seq),
    do: call(pid, {:backfill_message_threads, after_seq})

  def list_participant_states_for_cleanup(pid, limit),
    do: call(pid, {:list_participant_states_for_cleanup, limit})

  def participant_objects_empty?(pid), do: call(pid, :participant_objects_empty?)

  def cleanup_conversation_objects(pid, limit),
    do: call(pid, {:cleanup_conversation_objects, limit})

  def cleanup_delivery_wakeups(pid, limit), do: call(pid, {:cleanup_delivery_wakeups, limit})
  def finish_delete(pid, record), do: call(pid, {:finish_delete, record})

  def with_request(_pid, fun), do: fun.()

  defp call(pid, request),
    do: SystemsRuntime.Server.call(pid, request, @call_timeout)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    group = Keyword.fetch!(opts, :group_id)
    conversation = Keyword.fetch!(opts, :conversation_id)

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_ref: Proc.monitor(owner),
       group_id: group,
       conversation_id: conversation,
       scope: ConversationPGStore.new(group, conversation)
     }}
  end

  @impl true
  def handle_call(_request, {caller, _}, state) when caller != state.owner,
    do: {:reply, {:error, :unauthorized_store_caller}, state}

  def handle_call(request, _from, state) do
    {reply, state} = execute(request, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{owner_ref: ref, owner: owner} = state),
    do: {:stop, :normal, state}

  defp execute(:load_raw, state), do: {read(state, false), state}
  defp execute(:load, state), do: {read(state, true), state}

  defp execute(:source_snapshot, state) do
    result = with {:ok, record} <- read(state, true), do: {:ok, record, nil}
    {result, state}
  end

  defp execute({:message_by_id, id}, state),
    do: {ConversationPGStore.message_by_id(state.scope, id), state}

  defp execute({:message_by_request_identity, identity}, state),
    do: {ConversationPGStore.message_by_request_identity(state.scope, identity), state}

  defp execute({:identity_by_request_identity, identity}, state),
    do: {ConversationPGStore.identity_by_request_identity(state.scope, identity), state}

  defp execute({:identity_by_id, id}, state),
    do: {ConversationPGStore.identity_by_id(state.scope, id), state}

  defp execute(:settle_pending, %{pending: nil} = state), do: {:ok, state}

  defp execute(:settle_pending, state) do
    case ConversationPGStore.settle(state.pending) do
      {:error, :commit_indeterminate} = error -> {error, state}
      {:error, _} = error -> {error, %{state | pending: nil}}
      result -> {{:ok, result}, %{state | pending: nil}}
    end
  end

  defp execute({:recover_log, {target, version}}, state) do
    result =
      with {:ok, record} <- read(state, true) do
        if (record["message_tail_seq"] || 0) >= target and
             (record["provider_status_version"] || 0) >= version,
           do: {:ok, record, nil},
           else: {:error, :conversation_target_unavailable}
      end

    {result, state}
  end

  defp execute(request, %{pending: pending} = state) when not is_nil(pending) do
    if mutation?(request),
      do: {{:error, :commit_indeterminate}, state},
      else: execute_cleanup(request, state)
  end

  defp execute({:put_new, record}, state),
    do: commit(ConversationPGStore.prepare_create(state.scope, normalize_create(record)), state)

  defp execute({:archive_messages, limit}, state) do
    case ConversationPGStore.prepare_archive(state.scope, limit) do
      {:ok, :empty} -> {{:ok, :empty}, state}
      {:ok, pending} -> commit(pending, state)
      error -> {error, state}
    end
  end

  defp execute({:cleanup_archive_bodies, limit}, state) do
    case ConversationPGStore.prepare_cleanup_archive_bodies(state.scope, limit) do
      {:ok, pending} -> commit(pending, state)
      error -> {error, state}
    end
  end

  defp execute({:put_new_with_message, record, message}, state),
    do:
      commit(
        ConversationPGStore.prepare_create_with_message(
          state.scope,
          normalize_create(record),
          message
        ),
        state
      )

  defp execute({:reserve_message, message}, state) do
    case ConversationPGStore.prepare_reserve(state.scope, message) do
      {:ok, pending} -> commit(pending, state)
      error -> {error, state}
    end
  end

  defp execute({:append_message, message}, state) do
    with {:ok, previous, revision} <- ConversationPGStore.read(state.scope),
         {:ok, pending} <-
           ConversationPGStore.prepare_append(state.scope, {previous, revision}, message) do
      commit(pending, state)
    else
      error -> {error, state}
    end
  end

  defp execute({kind, _fun} = request, state) when kind in [:update, :update_with_previous],
    do: execute_update(request, state, 5)

  defp execute({:tombstone, _record}, state),
    do:
      execute(
        {:update,
         fn record ->
           Map.put(
             record,
             "deleted_at",
             record["deleted_at"] || SystemsClock.system_time(:millisecond)
           )
         end},
        state
      )

  defp execute(request, state), do: execute_cleanup(request, state)

  defp execute_update(request, state, retries) do
    case execute_update_once(request, state) do
      {:retry_precondition, next_state} when retries > 0 ->
        execute_update(request, next_state, retries - 1)

      {:retry_precondition, next_state} ->
        {{:error, :precondition_failed}, next_state}

      result ->
        result
    end
  end

  defp execute_update_once({kind, fun}, state) do
    with {:ok, previous, revision} <- ConversationPGStore.read(state.scope),
         {:ok, pending} <-
           ConversationPGStore.prepare_update(state.scope, {previous, revision}, fn previous ->
             case fun.(previous) do
               updated when is_map(updated) -> normalize(updated, previous)
               error -> error
             end
           end) do
      {result, state} = commit(pending, state, true)

      case {kind, result} do
        {:update, {:ok, _, updated}} -> {{:ok, updated}, state}
        _ -> {result, state}
      end
    else
      {:error, :precondition_failed} -> {:retry_precondition, state}
      error -> {error, state}
    end
  end

  defp commit(pending, state, retry_conflict? \\ false) do
    case ConversationPGStore.execute(pending) do
      {:error, :precondition_failed} when retry_conflict? -> {:retry_precondition, state}
      result -> settle_commit(pending, state, result)
    end
  end

  defp settle_commit(pending, state, result) do
    result =
      case result do
        {:error, :commit_indeterminate} -> ConversationPGStore.settle(pending)
        result -> result
      end

    case result do
      {:error, :commit_indeterminate} = error ->
        Proc.send(state.owner, {:conversation_commit_indeterminate, Proc.self()})
        {error, %{state | pending: pending}}

      result ->
        {normalize_result(pending, result), state}
    end
  end

  defp normalize_result(%{kind: :create}, {:ok, :inserted, record, _}), do: {:ok, record}
  defp normalize_result(%{kind: :create}, {:error, :precondition_failed}), do: {:error, :exists}

  defp normalize_result(%{kind: :create_with_message}, {:ok, _, record, message, _}),
    do: {:ok, record, message}

  defp normalize_result(%{kind: :create_with_message}, {:error, :precondition_failed}),
    do: {:error, :exists}

  defp normalize_result(%{kind: :update}, {:ok, previous, record, _}), do: {:ok, previous, record}

  defp normalize_result(%{kind: :reserve, message: incoming}, {:ok, _, _, identity, _}),
    do: {:ok, Map.put(incoming, "message_id", identity["message_id"])}

  defp normalize_result(%{kind: :append}, {:ok, status, record, message, _}),
    do: {:ok, status, record, message}

  defp normalize_result(%{kind: :cleanup_messages}, {:ok, result}), do: result

  defp normalize_result(%{kind: kind}, {:ok, result})
       when kind in [:cleanup_archive_bodies, :delete_archives], do: result

  defp normalize_result(_, result), do: result

  defp read(state, live?) do
    case ConversationPGStore.read(state.scope) do
      {:ok, %{"deleted_at" => deleted} = record, _} when not live? or is_nil(deleted) ->
        {:ok, record}

      {:ok, _, _} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp mutation?({kind, _})
       when kind in [
              :put_new,
              :reserve_message,
              :append_message,
              :update,
              :update_with_previous,
              :tombstone,
              :backfill_message_threads,
              :cleanup_conversation_objects,
              :cleanup_delivery_wakeups,
              :finish_delete,
              :archive_messages,
              :cleanup_archive_bodies
            ],
       do: true

  defp mutation?({:put_new_with_message, _, _}), do: true
  defp mutation?(_), do: false

  defp normalize_create(record) do
    if record["kind"] == "agent_task" and record["status"] == "active",
      do: Map.put_new(record, "run_started_at", SystemsClock.system_time(:millisecond)),
      else: record
  end

  defp normalize(record, previous) do
    fields = ~w(status title kind source_refs)

    record =
      if Map.take(record, fields) == Map.take(previous, fields),
        do: record,
        else:
          Map.put(
            record,
            "provider_status_version",
            (previous["provider_status_version"] || 0) + 1
          )

    if record["kind"] == "agent_task" and record["status"] == "active" and
         previous["status"] != "active",
       do: Map.put(record, "run_started_at", SystemsClock.system_time(:millisecond)),
       else: record
  end

  defp execute_cleanup({:list_participant_states_for_cleanup, limit}, state) do
    result =
      case Repo.query(
             "SELECT payload FROM salix_conversation_participants WHERE group_id = $1 AND conversation_id = $2 ORDER BY participant_id LIMIT $3",
             [state.group_id, state.conversation_id, limit]
           ) do
        {:ok, %{rows: []}} ->
          :empty

        {:ok, %{rows: rows}} ->
          {:ok, Enum.map(rows, fn [payload] -> :erlang.binary_to_term(payload, [:safe]) end)}

        {:error, _} ->
          {:error, :unavailable}
      end

    {result, state}
  end

  defp execute_cleanup(:participant_objects_empty?, state) do
    result =
      case Repo.query(
             "SELECT 1 FROM salix_conversation_participants WHERE group_id = $1 AND conversation_id = $2 LIMIT 1",
             [state.group_id, state.conversation_id]
           ) do
        {:ok, %{rows: []}} -> :empty
        {:ok, _} -> :more
        {:error, _} -> {:error, :unavailable}
      end

    {result, state}
  end

  defp execute_cleanup({:cleanup_delivery_wakeups, _limit}, state), do: {:empty, state}

  defp execute_cleanup({:cleanup_conversation_objects, limit}, state) do
    case ConversationPGStore.prepare_cleanup_archives(state.scope, limit) do
      {:ok, :empty} ->
        case ConversationPGStore.prepare_cleanup_messages(state.scope, limit) do
          {:ok, pending} -> commit(pending, state)
          error -> {error, state}
        end

      {:ok, pending} ->
        commit(pending, state)

      error ->
        {error, state}
    end
  end

  defp execute_cleanup({:finish_delete, _}, state) do
    case ConversationPGStore.prepare_finish_delete(state.scope) do
      {:ok, pending} -> commit(pending, state)
      error -> {error, state}
    end
  end

  defp execute_cleanup({:backfill_message_threads, after_seq}, state) do
    case ConversationPGStore.prepare_backfill_message_threads(state.scope, after_seq) do
      {:ok, pending} -> commit(pending, state)
      error -> {error, state}
    end
  end

  defp execute_cleanup(_, state), do: {{:error, :unsupported_store_operation}, state}
end
