defmodule SalixIM.ConversationParticipantStore do
  @moduledoc """
  Private persistence capability owned by one ConversationParticipantActor.

  It is unnamed and accepts calls only from its owner PID. The actor owns
  delivery decisions; this store persists Participant state and exact provider receipts.
  Conditional receipt writes prevent a stale result from replacing another claim.
  Historical delivery objects are removed only with their owning Participant.
  """

  alias SystemsRuntime.Proc
  use SystemsRuntime.Server

  alias SalixStore.CasRecord
  alias SalixIM.ConversationParticipantPGStore, as: PG

  @call_timeout :infinity
  @guarded_upsert_retries 8
  defstruct [:owner, :owner_ref, :group_id, :conversation_id, :participant_id, :scope, :pending]

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)
  def load(pid), do: call(pid, :load)
  def load_conversation(pid), do: call(pid, :load_conversation)
  def settle_pending(pid), do: call(pid, :settle_pending)
  def put_new(pid, record), do: call(pid, {:put_new, record})
  def update(pid, fun), do: call(pid, {:update, fun})
  def guarded_upsert(pid, guard, fun), do: call(pid, {:guarded_upsert, guard, fun})
  def tombstone(pid), do: call(pid, :tombstone)
  def cleanup(pid, limit), do: call(pid, {:cleanup, limit})
  def read_delivery(pid, id), do: call(pid, {:read_delivery, id})

  def put_delivery_state(pid, id, record, revision),
    do: call(pid, {:put_delivery_state, id, record, revision})

  def put_delivery(pid, record), do: call(pid, {:put_delivery, record})
  def delivery_by_id(pid, id), do: call(pid, {:delivery_by_id, id})
  defp call(pid, request), do: SystemsRuntime.Server.call(pid, request, @call_timeout)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    group = Keyword.fetch!(opts, :group_id)
    conversation = Keyword.fetch!(opts, :conversation_id)
    participant = Keyword.fetch!(opts, :participant_id)

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_ref: Proc.monitor(owner),
       group_id: group,
       conversation_id: conversation,
       participant_id: participant,
       scope: PG.new(group, conversation, participant)
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

  defp execute(:load, state), do: {without_revision(PG.read(state.scope)), state}

  defp execute(:load_conversation, state),
    do:
      {SalixIM.Conversations.get_group_conversation_record(state.group_id, state.conversation_id),
       state}

  defp execute({:read_delivery, id}, state),
    do: {PG.read_delivery(state.scope, id), state}

  defp execute({:delivery_by_id, id}, state),
    do: {without_revision(PG.read_delivery(state.scope, id)), state}

  defp execute(:settle_pending, %{pending: nil} = state), do: {:none, state}

  defp execute(:settle_pending, %{pending: pending} = state) do
    case PG.settle(pending) do
      {:error, :commit_indeterminate} = error ->
        {error, state}

      {:error, _} = error ->
        {error, %{state | pending: nil}}

      result ->
        {{:ok, %{delivery_id: pending.delivery_id, record: pending.record, result: result}},
         %{state | pending: nil}}
    end
  end

  defp execute(_request, %{pending: pending} = state) when not is_nil(pending),
    do: {{:error, :commit_indeterminate}, state}

  defp execute({:put_new, record}, state),
    do: commit(PG.prepare(state.scope, 0, record, :inserted), state)

  defp execute({:update, fun}, state) do
    with {:ok, current, revision} <- PG.read(state.scope),
         updated when is_map(updated) <- fun.(current) do
      commit(PG.prepare(state.scope, revision, updated, :updated), state)
    else
      error -> {error, state}
    end
  end

  defp execute({:guarded_upsert, guard, fun}, state),
    do: guarded_upsert(state, guard, fun, @guarded_upsert_retries)

  defp execute(:tombstone, state) do
    case execute(
           {:update, &Map.put_new(&1, "deleted_at", SystemsClock.system_time(:millisecond))},
           state
         ) do
      {{:ok, _}, state} -> {:ok, state}
      {{:error, :not_found}, state} -> {:ok, state}
      other -> other
    end
  end

  defp execute({:cleanup, limit}, state), do: {PG.cleanup(state.scope, limit), state}

  defp execute({:put_delivery_state, id, record, revision}, state)
       when is_binary(id) and id != "",
       do: commit(PG.prepare(state.scope, revision, record, :receipt, id), state)

  defp execute({:put_delivery, %{"delivery_id" => id} = record}, state)
       when is_binary(id) and id != "" do
    case commit(PG.prepare(state.scope, 0, record, :receipt, id), state) do
      {{:ok, _}, state} -> {:inserted, state}
      {{:error, :precondition_failed}, state} -> {:exists, state}
      other -> other
    end
  end

  defp execute(_, state), do: {{:error, :unsupported_store_operation}, state}

  defp guarded_upsert(state, _guard, _fun, 0), do: {{:error, :precondition_failed}, state}

  defp guarded_upsert(state, guard, fun, attempts) do
    with :ok <- exact_record_guard(guard),
         {:ok, current, revision} <- guarded_snapshot(state),
         :ok <- exact_record_guard(guard),
         {:ok, status, updated} when is_map(updated) <- fun.(current) do
      case commit(PG.prepare(state.scope, revision, updated, status), state) do
        {{:error, :precondition_failed}, state} -> guarded_upsert(state, guard, fun, attempts - 1)
        other -> other
      end
    else
      error -> {error, state}
    end
  end

  defp guarded_snapshot(state) do
    case PG.read(state.scope) do
      {:error, :not_found} -> {:ok, :not_found, 0}
      other -> other
    end
  end

  defp commit(pending, state) do
    result =
      case PG.execute(pending) do
        {:error, :commit_indeterminate} -> PG.settle(pending)
        other -> other
      end

    case result do
      {:error, :commit_indeterminate} = error ->
        Proc.send(state.owner, {:participant_commit_indeterminate, Proc.self()})
        {error, %{state | pending: pending}}

      other ->
        {other, state}
    end
  end

  defp without_revision({:ok, record, _}), do: {:ok, record}
  defp without_revision(other), do: other

  defp exact_record_guard(%{
         "record_key" => key,
         "required" => required,
         "one_of" => one_of,
         "optional_expected" => optional_expected
       })
       when is_binary(key) and key != "" and is_map(required) and is_map(one_of) and
              is_map(optional_expected) do
    case CasRecord.get(key) do
      {:ok, record} when is_map(record) ->
        if exact_required_fields?(record, required) and
             allowed_record_fields?(record, one_of) and
             optional_expected_fields?(record, optional_expected) do
          :ok
        else
          {:error, :guard_record_mismatch}
        end

      {:error, :not_found} ->
        {:error, :guard_record_mismatch}

      {:error, reason} ->
        {:error, {:guard_record_unavailable, reason}}
    end
  end

  defp exact_record_guard(_guard), do: {:error, :invalid_record_guard}

  defp exact_required_fields?(record, required),
    do: Enum.all?(required, fn {field, expected} -> Map.get(record, field) == expected end)

  defp allowed_record_fields?(record, one_of) do
    Enum.all?(one_of, fn
      {field, allowed} when is_list(allowed) -> Map.get(record, field) in allowed
      _invalid -> false
    end)
  end

  defp optional_expected_fields?(record, optional_expected) do
    Enum.all?(optional_expected, fn {field, expected} ->
      Map.get(record, field) in [nil, "", expected]
    end)
  end
end
