defmodule SalixIM.ConversationParticipantStore do
  @moduledoc """
  Private persistence capability owned by one ConversationParticipantActor.

  It is unnamed and accepts calls only from its owner PID. The actor owns
  delivery decisions; this store persists Participant state and exact provider receipts.
  Conditional receipt writes prevent a stale result from replacing another claim.
  Historical delivery objects are removed only with their owning Participant.
  """
  use GenServer

  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @call_timeout :infinity
  @guarded_upsert_retries 8

  defstruct owner: nil,
            owner_ref: nil,
            group_id: nil,
            conversation_id: nil,
            participant_id: nil,
            participant_key: nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def load(pid), do: call(pid, :load)
  def load_conversation(pid), do: call(pid, :load_conversation)
  def put_new(pid, participant), do: call(pid, {:put_new, participant})
  def update(pid, fun), do: call(pid, {:update, fun})

  def guarded_upsert(pid, guard, fun) when is_map(guard) and is_function(fun, 1),
    do: call(pid, {:guarded_upsert, guard, fun})

  def tombstone(pid), do: call(pid, :tombstone)
  def cleanup(pid, limit), do: call(pid, {:cleanup, limit})

  def read_delivery(pid, delivery_id), do: call(pid, {:read_delivery, delivery_id})

  def put_delivery_state(pid, delivery_id, record, revision),
    do: call(pid, {:put_delivery_state, delivery_id, record, revision})

  def put_delivery(pid, record), do: call(pid, {:put_delivery, record})

  def delivery_by_id(pid, delivery_id), do: call(pid, {:delivery_by_id, delivery_id})

  defp call(pid, request), do: GenServer.call(pid, request, @call_timeout)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    group_id = Keyword.fetch!(opts, :group_id)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    participant_id = Keyword.fetch!(opts, :participant_id)

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_ref: Process.monitor(owner),
       group_id: group_id,
       conversation_id: conversation_id,
       participant_id: participant_id,
       participant_key:
         Keys.ctl_group_conversation_participant_state(
           group_id,
           conversation_id,
           participant_id
         )
     }}
  end

  @impl true
  def handle_call(_request, {caller, _tag}, state) when caller != state.owner,
    do: {:reply, {:error, :unauthorized_store_caller}, state}

  def handle_call(request, _from, state) do
    {reply, state} = execute(request, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %{owner_ref: ref, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  defp execute(:load, state),
    do: {seg_get_participant(state.group_id, state.conversation_id, state.participant_id), state}

  defp execute(:load_conversation, state) do
    key = Keys.ctl_group_conversation(state.group_id, state.conversation_id)
    {seg_get_conversation(key), state}
  end

  defp execute({:put_new, participant}, state) do
    participant =
      participant
      |> Map.put("participant_id", state.participant_id)
      |> Map.put("conversation_id", state.conversation_id)

    reply =
      case S3.put(state.participant_key, Jason.encode!(participant), if_none_match: "*") do
        {:ok, _result} ->
          {:ok, :inserted, participant}

        {:error, failure} when failure in [:precondition_failed] ->
          verify_existing_participant(state.participant_key, participant)

        {:error, {:ambiguous, _reason}} ->
          verify_existing_participant(state.participant_key, participant)

        {:error, reason} ->
          {:error, reason}
      end

    {reply, state}
  end

  defp execute({:update, fun}, state) do
    update = fn current ->
      case fun.(current) do
        %{} = updated -> canonical_participant(updated, state)
        {:error, _reason} = error -> error
        other -> other
      end
    end

    {seg_update_participant_state(
       state.group_id,
       state.conversation_id,
       state.participant_id,
       update
     ), state}
  end

  defp execute({:guarded_upsert, guard, fun}, state) do
    transition = fn current ->
      case fun.(current) do
        {:ok, status, %{} = updated} ->
          {:ok, status, canonical_participant(updated, state)}

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:invalid_guarded_participant_transition, other}}
      end
    end

    reply =
      guarded_upsert_participant(
        state.participant_key,
        guard,
        transition,
        @guarded_upsert_retries
      )

    {reply, state}
  end

  defp execute(:tombstone, state),
    do: {tombstone_participant(state, 5), state}

  defp execute({:cleanup, limit}, state) do
    prefix =
      Keys.ctl_group_conversation_participant_dir(
        state.group_id,
        state.conversation_id,
        state.participant_id
      )

    reply =
      with :empty <- delete_prefix_page(prefix, limit),
           :ok <-
             seg_delete_participant_delivery_wakeup_marker(
               state.group_id,
               state.conversation_id,
               state.participant_id
             ),
           :ok <- delete_if_present(state.participant_key) do
        :done
      else
        :more -> :more
        {:error, _reason} = error -> error
      end

    {reply, state}
  end

  defp execute({:read_delivery, delivery_id}, state),
    do: {seg_read_delivery(state, delivery_id), state}

  defp execute({:put_delivery_state, delivery_id, record, revision}, state),
    do: {seg_put_delivery_state(state, delivery_id, record, revision), state}

  defp execute({:put_delivery, record}, state),
    do: {seg_put_delivery(state, record), state}

  defp execute({:delivery_by_id, delivery_id}, state),
    do: {seg_delivery_by_id(state, delivery_id), state}

  defp execute(_request, state), do: {{:error, :unsupported_store_operation}, state}

  defp verify_existing_participant(key, expected) do
    case seg_read_json(key) do
      {:ok, ^expected} -> {:ok, :exists, expected}
      {:ok, _other} -> {:error, {:participant_id_collision, expected["participant_id"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_participant(participant, state) do
    participant
    |> Map.put("conversation_id", state.conversation_id)
    |> Map.put("participant_id", state.participant_id)
  end

  # The exact-record guard is intentionally read on both sides of the physical
  # Participant snapshot. A conditional-write conflict restarts here, before
  # either guard read; it must never rebase only the Participant mutation.
  # SlackTaskThreadGenerationFence models this ordering together with Stage B's
  # future fence -> Participant CAS -> binding delete protocol.
  defp guarded_upsert_participant(_key, _guard, _transition, 0),
    do: {:error, :precondition_failed}

  defp guarded_upsert_participant(key, guard, transition, attempts) do
    with :ok <- exact_record_guard(guard),
         {:ok, current, etag} <- guarded_participant_snapshot(key),
         :ok <- exact_record_guard(guard),
         {:ok, status, updated} <- transition.(current) do
      cond do
        is_map(current) and current == updated ->
          {:ok, status, current}

        true ->
          put_guarded_participant(
            key,
            current,
            updated,
            etag,
            status,
            guard,
            transition,
            attempts
          )
      end
    end
  end

  defp guarded_participant_snapshot(key) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, current} when is_map(current) -> {:ok, current, etag}
          {:ok, _invalid} -> {:error, :invalid_participant_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:ok, :not_found, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_guarded_participant(
         key,
         current,
         updated,
         etag,
         status,
         guard,
         transition,
         attempts
       ) do
    opts = if current == :not_found, do: [if_none_match: "*"], else: [if_match: etag]

    case S3.put(key, Jason.encode!(updated), opts) do
      {:ok, _result} ->
        {:ok, status, updated}

      {:error, :precondition_failed} ->
        guarded_upsert_participant(key, guard, transition, attempts - 1)

      {:error, {:ambiguous, reason}} ->
        settle_guarded_participant(
          key,
          updated,
          status,
          guard,
          transition,
          attempts - 1,
          reason
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_guarded_participant(
         key,
         updated,
         status,
         guard,
         transition,
         attempts,
         ambiguous_reason
       ) do
    case guarded_participant_snapshot(key) do
      {:ok, ^updated, _etag} ->
        {:ok, status, updated}

      {:ok, _other, _etag} when attempts > 0 ->
        guarded_upsert_participant(key, guard, transition, attempts)

      {:ok, _other, _etag} ->
        {:error, {:ambiguous, {:guarded_participant_write_unsettled, key, ambiguous_reason}}}

      {:error, reason} ->
        {:error, {:ambiguous, {:guarded_participant_readback_failed, key, reason}}}
    end
  end

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

  defp tombstone_participant(_state, 0), do: {:error, :precondition_failed}

  defp tombstone_participant(state, attempts) do
    case seg_update_participant_state(
           state.group_id,
           state.conversation_id,
           state.participant_id,
           &Map.put_new(&1, "deleted_at", System.system_time(:millisecond))
         ) do
      {:ok, _participant} -> :ok
      {:error, :not_found} -> :ok
      {:error, :precondition_failed} -> tombstone_participant(state, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_prefix_page(prefix, limit) do
    case S3.list(prefix, max_keys: limit) do
      {:ok, %{objects: []}} ->
        :empty

      {:ok, %{objects: objects}} ->
        Enum.reduce_while(objects, :more, fn object, :more ->
          case delete_if_present(object.key) do
            :ok -> {:cont, :more}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_if_present(key) do
    case S3.delete(key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_get_conversation(key) do
    with {:ok, meta} <- seg_read_json(key),
         true <- is_nil(meta["deleted_at"]) do
      {:ok, meta}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_get_participant(group_id, conversation_id, participant_id) do
    if Ids.valid_group_id?(group_id) and Ids.valid_conversation_id?(conversation_id) and
         Ids.valid_participant_id?(participant_id) do
      group_id
      |> Keys.ctl_group_conversation_participant_state(conversation_id, participant_id)
      |> seg_read_json()
    else
      {:error, {:bad_request, "invalid conversation participant identity"}}
    end
  end

  defp seg_update_participant_state(group_id, conversation_id, participant_id, fun)
       when is_function(fun, 1) do
    key = Keys.ctl_group_conversation_participant_state(group_id, conversation_id, participant_id)

    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, current} when is_map(current) <- Jason.decode(body),
         updated when is_map(updated) <- fun.(current) do
      put_participant_update(key, current, updated, etag, 1)
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp put_participant_update(key, current, updated, etag, retries) do
    case S3.put(key, Jason.encode!(updated), if_match: etag) do
      {:ok, _} ->
        {:ok, updated}

      {:error, {:ambiguous, reason}} ->
        settle_participant_update(key, current, updated, retries, reason)

      {:error, :precondition_failed} ->
        {:error, :precondition_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_participant_update(key, current, updated, retries, ambiguous_reason) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, ^updated} ->
            {:ok, updated}

          {:ok, ^current} when retries > 0 ->
            put_participant_update(key, current, updated, etag, retries - 1)

          {:ok, ^current} ->
            {:error, {:ambiguous, {:participant_update_not_landed, key, ambiguous_reason}}}

          {:ok, _other} ->
            {:error, :precondition_failed}

          {:error, reason} ->
            {:error, {:ambiguous, {:readback_undecodable, key, reason}}}
        end

      {:error, reason} ->
        {:error, {:ambiguous, {:readback_failed, key, reason}}}
    end
  end

  defp seg_put_delivery(state, rec) do
    with {:ok, delivery_id} <- seg_require_delivery_id(rec) do
      rec = canonical_delivery_record(rec, state, delivery_id)

      case S3.put(delivery_key(state, delivery_id), Jason.encode!(rec), if_none_match: "*") do
        {:ok, _} -> :inserted
        {:error, :precondition_failed} -> :exists
        error -> error
      end
    end
  end

  defp seg_delivery_by_id(state, delivery_id) do
    with {:ok, delivery_id} <- seg_require_delivery_id(%{"delivery_id" => delivery_id}),
         {:ok, rec} <- delivery_key(state, delivery_id) |> seg_read_json() do
      {:ok, canonical_delivery_record(rec, state, delivery_id)}
    end
  end

  defp seg_read_delivery(state, delivery_id) do
    with {:ok, delivery_id} <- seg_require_delivery_id(%{"delivery_id" => delivery_id}),
         {:ok, rec, revision} <- delivery_key(state, delivery_id) |> seg_read_json_with_etag() do
      {:ok, canonical_delivery_record(rec, state, delivery_id), revision}
    end
  end

  defp seg_delete_participant_delivery_wakeup_marker(
         group_id,
         conversation_id,
         participant_id
       ) do
    key =
      Keys.ctl_group_conversation_participant_delivery_wakeup(
        group_id,
        conversation_id,
        participant_id
      )

    case S3.delete(key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_put_delivery_state(state, delivery_id, rec, revision) do
    with {:ok, delivery_id} <- seg_require_delivery_id(%{"delivery_id" => delivery_id}) do
      rec = canonical_delivery_record(rec, state, delivery_id)
      condition = if is_nil(revision), do: [if_none_match: "*"], else: [if_match: revision]
      S3.put(delivery_key(state, delivery_id), Jason.encode!(rec), condition)
    end
  end

  defp delivery_key(state, delivery_id) do
    Keys.ctl_group_conversation_participant_delivery_state(
      state.group_id,
      state.conversation_id,
      state.participant_id,
      delivery_id
    )
  end

  defp canonical_delivery_record(rec, state, delivery_id) do
    rec
    |> Map.put("agent_group_id", state.group_id)
    |> Map.put("conversation_id", state.conversation_id)
    |> Map.put("participant_id", state.participant_id)
    |> Map.put("delivery_id", delivery_id)
  end

  defp seg_require_delivery_id(rec) do
    case rec["delivery_id"] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:bad_request, "delivery_id is required"}}
    end
  end

  defp seg_read_json(key), do: CasRecord.get(key)

  defp seg_read_json_with_etag(key) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, rec} when is_map(rec) <- Jason.decode(body) do
      {:ok, rec, etag}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end
end
