defmodule SalixIM.ConversationStore do
  @moduledoc """
  Private stateful persistence capability owned by one ConversationActor.

  The store is deliberately unnamed. Only its owner PID may call it; aggregate
  identity is fixed at startup and is never accepted by the mutation API.
  """

  use GenServer

  alias SalixIM.{ConversationMessageCodec, SlackTaskCard}
  alias SalixStore.{BoundedJsonl, CasRecord, Crypto, Ids, Keys}
  alias SalixIM.ConversationStore.RequestIO, as: S3

  @call_timeout :infinity
  @repair_retry_ms 50
  @repair_retry_max_ms 5_000
  @repair_stale_key_limit 32
  @seg_uncommitted_cleanup_pages 2
  @list_index_previous_updated_at_field "_list_index_previous_updated_at"

  defstruct owner: nil,
            owner_ref: nil,
            group_id: nil,
            conversation_id: nil,
            meta_key: nil,
            source_cache: nil,
            resident_io: %{},
            list_repair_task: nil,
            pending_list_repair: nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def load(pid), do: call(pid, :load)
  def resident_snapshot(pid), do: call(pid, :resident_snapshot)
  def load_raw(pid), do: call(pid, :load_raw)
  def new_slot(pid), do: call(pid, :new_slot)
  def put_new(pid, record), do: call(pid, {:put_new, record})

  def put_new_with_message(pid, record, message),
    do: call(pid, {:put_new_with_message, record, message})

  def discard_uncommitted_messages(pid), do: call(pid, :discard_uncommitted_messages)
  def update(pid, fun), do: call(pid, {:update, fun})

  def update_with_previous(pid, fun),
    do: call(pid, {:update_with_previous, fun})

  def tombstone(pid, record), do: call(pid, {:tombstone, record})

  def repair_list_index(pid, previous, record),
    do: call(pid, {:repair_list_index, previous, record})

  def recover_log(pid, target), do: call(pid, {:recover_log, target})

  def source_snapshot(pid), do: call(pid, :source_snapshot)

  def defer_list_repair(pid), do: call(pid, :defer_list_repair)

  def prefetch_message(pid, message), do: call(pid, {:prefetch_message, message})

  def reserve_message(pid, message), do: call(pid, {:reserve_message, message})
  def append_message(pid, message), do: call(pid, {:append_message, message})

  def message_by_id(pid, message_id), do: call(pid, {:message_by_id, message_id})

  def message_by_request_identity(pid, request_identity),
    do: call(pid, {:message_by_request_identity, request_identity})

  def backfill_message_threads(pid, after_seq),
    do: call(pid, {:backfill_message_threads, after_seq})

  def list_participant_states_for_cleanup(pid, limit),
    do: call(pid, {:list_participant_states_for_cleanup, limit})

  def participant_objects_empty?(pid), do: call(pid, :participant_objects_empty?)

  def cleanup_conversation_objects(pid, limit),
    do: call(pid, {:cleanup_conversation_objects, limit})

  def cleanup_delivery_wakeups(pid, limit),
    do: call(pid, {:cleanup_delivery_wakeups, limit})

  def finish_delete(pid, tombstone), do: call(pid, {:finish_delete, tombstone})

  def with_request(pid, fun) do
    key = {__MODULE__, pid}

    if Process.get(key) do
      fun.()
    else
      Process.put(key, %{})

      try do
        fun.()
      after
        Process.delete(key)
      end
    end
  end

  defp call(pid, request) do
    key = {__MODULE__, pid}

    case Process.get(key) do
      nil ->
        GenServer.call(pid, request, @call_timeout)

      memo ->
        {reply, memo} = GenServer.call(pid, {:request_scope, memo, request}, @call_timeout)
        Process.put(key, memo)
        reply
    end
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    group_id = Keyword.fetch!(opts, :group_id)
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_ref: Process.monitor(owner),
       group_id: group_id,
       conversation_id: conversation_id,
       meta_key: Keys.ctl_group_conversation(group_id, conversation_id)
     }}
  end

  @impl true
  def handle_call(_request, {caller, _tag}, state) when caller != state.owner,
    do: {:reply, {:error, :unauthorized_store_caller}, state}

  def handle_call({:request_scope, memo, request}, _from, state) do
    {{reply, state}, memo} =
      S3.run(Map.merge(memo, resident_io(request, state)), fn ->
        execute(request, invalidate_source(request, state))
      end)

    {:reply, {reply, memo}, %{state | resident_io: memo}}
  end

  def handle_call(request, _from, state) do
    {{reply, state}, memo} =
      S3.run(if(request == :resident_snapshot, do: state.resident_io, else: %{}), fn ->
        execute(request, invalidate_source(request, state))
      end)

    {:reply, reply, %{state | resident_io: memo}}
  end

  # Only this owner's bounded observations survive between requests. Recovery
  # explicitly rereads storage; failed conditional writes discard the memo.
  defp resident_io({:recover_log, _}, _state), do: %{}
  defp resident_io(_request, state), do: state.resident_io

  @impl true
  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %{owner_ref: ref, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(:repair_list_index, %{pending_list_repair: nil} = state),
    do: {:noreply, state}

  def handle_info(:repair_list_index, %{list_repair_task: task} = state) when not is_nil(task),
    do: {:noreply, state}

  def handle_info(:repair_list_index, %{pending_list_repair: pending} = state) do
    owner = self()

    case Task.Supervisor.start_child(SalixIM.ConversationProjectionTasks, fn ->
           result = repair_pending_list_index(state, pending)
           send(owner, {:list_projection_result, self(), pending, result})
         end) do
      {:ok, pid} ->
        {:noreply, %{state | list_repair_task: {pid, Process.monitor(pid)}}}

      {:error, _} ->
        Process.send_after(self(), :repair_list_index, @repair_retry_max_ms)
        {:noreply, state}
    end
  end

  def handle_info(
        {:list_projection_result, pid, pending, result},
        %{list_repair_task: {pid, ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = %{state | list_repair_task: nil}

    if result == :ok and state.pending_list_repair == pending do
      {:noreply, %{state | pending_list_repair: nil}}
    else
      retry_ms = if result == :ok, do: 0, else: pending.retry_ms
      Process.send_after(self(), :repair_list_index, retry_ms)
      pending = state.pending_list_repair

      pending =
        if pending,
          do: %{
            pending
            | retry_ms: min(max(retry_ms * 2, @repair_retry_ms), @repair_retry_max_ms)
          }

      {:noreply, %{state | pending_list_repair: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _}, %{list_repair_task: {pid, ref}} = state) do
    Process.send_after(self(), :repair_list_index, @repair_retry_max_ms)
    {:noreply, %{state | list_repair_task: nil}}
  end

  defp invalidate_source({command, _}, state)
       when command in [
              :append_message,
              :recover_log,
              :update,
              :update_with_previous,
              :tombstone,
              :backfill_message_threads,
              :cleanup_conversation_objects,
              :finish_delete
            ],
       do: %{state | source_cache: nil}

  defp invalidate_source(_, state), do: state

  defp execute(:source_snapshot, %{source_cache: %{conversation: conversation} = cache} = state),
    do: {{:ok, conversation, cache.messages}, state}

  defp execute(:source_snapshot, state) do
    case seg_get_conversation(state.meta_key) do
      {:ok, conversation} -> {{:ok, conversation, nil}, state}
      error -> {error, state}
    end
  end

  defp execute(:resident_snapshot, state), do: {seg_get_conversation(state.meta_key), state}

  defp execute(:load, state), do: {seg_get_conversation(state.meta_key), state}
  defp execute(:load_raw, state), do: {seg_get_conversation_raw(state.meta_key), state}

  defp execute(:defer_list_repair, state) do
    case seg_get_conversation(state.meta_key) do
      {:ok, current} -> {:ok, mark_list_index_dirty(state, nil, current)}
      error -> {error, state}
    end
  end

  defp execute({:backfill_message_threads, after_seq}, state),
    do: {seg_backfill_message_threads(state, after_seq), state}

  defp execute(:new_slot, state), do: {seg_require_new_conversation_slot(state.meta_key), state}

  defp execute({:put_new, record}, state) do
    meta =
      seg_conversation_meta(state.group_id, state.conversation_id, record)
      |> Map.put("log_start_seq", 0)

    reply =
      case seg_put_new_json_record(state.meta_key, meta) do
        {:ok, status} when status in [:inserted, :ambiguous_landed] -> {:ok, meta}
        {:ok, :preexisting} -> {:error, :exists}
        {:error, :record_conflict} -> {:error, :exists}
        {:error, reason} -> {:error, reason}
      end

    case reply do
      {:ok, created} ->
        case seg_put_conversation_list_index(state.group_id, nil, created) do
          :ok ->
            {reply, state}

          {:error, _reason} ->
            {reply, mark_list_index_dirty(state, nil, created)}
        end

      _ ->
        {reply, state}
    end
  end

  # The create-only meta write commits the conversation and its first message
  # together. A failure before it leaves only unreferenced message objects.
  defp execute({:put_new_with_message, record, message}, state) do
    meta =
      seg_conversation_meta(state.group_id, state.conversation_id, record)
      |> Map.put("log_start_seq", 0)

    reply =
      with {:ok, published, staged} <-
             seg_stage_first_message(state.group_id, state.conversation_id, meta, message) do
        case seg_put_new_json_record(state.meta_key, published) do
          {:ok, status} when status in [:inserted, :ambiguous_landed] -> {:ok, published, staged}
          {:ok, :preexisting} -> {:error, :exists}
          {:error, :record_conflict} -> {:error, :exists}
          {:error, reason} -> {:error, reason}
        end
      end

    case reply do
      {:ok, created, _staged} ->
        case seg_put_conversation_list_index(state.group_id, nil, created) do
          :ok -> {reply, cache_source(state, created)}
          {:error, _reason} -> {reply, mark_list_index_dirty(state, nil, created)}
        end

      _ ->
        {reply, %{state | source_cache: nil}}
    end
  end

  # Without a meta object, message objects are leftovers of a failed create
  # of this same identity. Remove them so a retry can stage its first message.
  defp execute(:discard_uncommitted_messages, state) do
    dir = Keys.ctl_group_conversation_dir(state.group_id, state.conversation_id)

    reply =
      with :ok <- seg_require_new_conversation_slot(state.meta_key) do
        Enum.reduce_while(["messages/", "idempotency/messages/"], :ok, fn prefix, :ok ->
          case seg_delete_prefix(dir <> prefix, @seg_uncommitted_cleanup_pages) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      end

    {reply, state}
  end

  defp execute({:update, fun}, state) do
    retry_precondition(fn ->
      seg_update_conversation(
        state.group_id,
        state.conversation_id,
        state.meta_key,
        fun
      )
    end)
    |> settle_update_result(state)
  end

  defp execute({:update_with_previous, fun}, state) do
    retry_precondition(fn ->
      seg_update_conversation_meta_with_previous(
        state.group_id,
        state.conversation_id,
        state.meta_key,
        fun
      )
    end)
    |> settle_update_with_previous_result(state)
  end

  defp execute({:tombstone, record}, state),
    do: {seg_tombstone_conversation(state.meta_key, record), state}

  defp execute({:repair_list_index, previous, record}, state),
    do: {seg_put_conversation_list_index(state.group_id, previous, record), state}

  defp execute({:prefetch_message, message}, state) do
    reply =
      with {:ok, conversation} <- seg_get_conversation(state.meta_key) do
        seq = (conversation["message_tail_seq"] || 0) + 1
        segment = conversation["current_message_segment"] || seg_segment_id(seq)

        keys = [
          Keys.ctl_group_conversation_message_segment(
            state.group_id,
            state.conversation_id,
            segment
          ),
          Keys.ctl_group_conversation_message_segment_index(
            state.group_id,
            state.conversation_id,
            segment
          ),
          Keys.ctl_group_conversation_message_seq_index(
            state.group_id,
            state.conversation_id,
            seq
          ),
          Keys.ctl_group_conversation_message_identity(
            state.group_id,
            state.conversation_id,
            Crypto.hex(message["message_id"])
          )
        ]

        keys =
          if message["request_identity"] in [nil, ""],
            do: keys,
            else: [
              Keys.ctl_group_conversation_message_idempotency(
                state.group_id,
                state.conversation_id,
                Crypto.hex(message["request_identity"])
              )
              | keys
            ]

        S3.prefetch(keys)
      end

    {reply, state}
  end

  defp execute({:reserve_message, message}, state),
    do: {seg_reserve_message_request(state.group_id, state.conversation_id, message), state}

  defp execute({:recover_log, {target, status_version}}, state) do
    with {:ok, conversation} <- seg_get_conversation(state.meta_key),
         {:ok, conversation, state} <- recover_status_version(state, conversation, status_version) do
      tail = conversation["message_tail_seq"] || 0

      if conversation["deleted_at"] || tail >= target do
        {{:ok, conversation, nil}, state}
      else
        # The index is marked only after the segment and all locators exist.
        # Complete the same append through the normal CAS publication path.
        key =
          Keys.ctl_group_conversation_message_seq_index(
            state.group_id,
            state.conversation_id,
            tail + 1
          )

        with {:ok, %{"segment_id" => segment, "message_id" => id}} <- seg_read_json(key),
             {:ok, message} <-
               seg_message_by_seq(state.group_id, state.conversation_id, tail + 1, segment, %{
                 "message_id" => id
               }),
             {{:ok, _, updated}, state} <- execute({:append_message, message}, state) do
          {{:ok, updated, message}, state}
        else
          {reply, %__MODULE__{} = state} -> {reply, state}
          error -> {error, state}
        end
      end
    else
      error -> {error, state}
    end
  end

  defp execute({:append_message, message}, state) do
    case seg_append_message(
           state.group_id,
           state.conversation_id,
           state.meta_key,
           message
         ) do
      {:ok, status, conversation, _previous, :ok} ->
        {{:ok, status, conversation}, cache_source(state, conversation)}

      {:ok, :exists, conversation} ->
        {{:ok, :exists, conversation},
         mark_list_index_dirty(cache_source(state, conversation), nil, conversation)}

      {:ok, status, conversation, previous, {:error, _reason}} ->
        {{:ok, status, conversation},
         mark_list_index_dirty(cache_source(state, conversation), previous, conversation)}

      other ->
        {other, state}
    end
  end

  defp execute({:message_by_id, message_id}, state),
    do: {seg_message_by_id(state.group_id, state.conversation_id, message_id), state}

  defp execute({:message_by_request_identity, request_identity}, state),
    do:
      {seg_message_by_request_identity(state.group_id, state.conversation_id, request_identity),
       state}

  defp execute({:list_participant_states_for_cleanup, limit}, state) do
    prefix =
      Keys.ctl_group_conversation_participant_states_prefix(
        state.group_id,
        state.conversation_id
      )

    reply =
      with {:ok, %{objects: objects}} <- S3.list(prefix, max_keys: limit) do
        case objects do
          [] ->
            :empty

          objects ->
            Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, acc} ->
              case seg_read_json(object.key) do
                {:ok, participant} ->
                  {:cont, {:ok, [participant | acc]}}

                # Participant cleanup deletes its state fact last. A state returned by
                # LIST may therefore disappear before GET; that participant has already
                # crossed its terminal cleanup fence.
                {:error, :not_found} ->
                  {:cont, {:ok, acc}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
            end)
            |> case do
              {:ok, []} -> :more
              {:ok, participants} -> {:ok, Enum.reverse(participants)}
              error -> error
            end
        end
      end

    {reply, state}
  end

  defp execute(:participant_objects_empty?, state) do
    prefix =
      Keys.ctl_group_conversation_participants_prefix(state.group_id, state.conversation_id)

    reply =
      case S3.list(prefix, max_keys: 1) do
        {:ok, %{objects: []}} -> :empty
        {:ok, %{objects: _objects}} -> :more
        {:error, reason} -> {:error, reason}
      end

    {reply, state}
  end

  defp execute({:cleanup_conversation_objects, limit}, state) do
    prefix = Keys.ctl_group_conversation_dir(state.group_id, state.conversation_id)

    reply =
      with {:ok, %{objects: objects}} <- S3.list(prefix, max_keys: limit) do
        objects
        |> Enum.reject(&(&1.key == state.meta_key))
        |> delete_object_page()
      end

    {reply, state}
  end

  defp execute({:cleanup_delivery_wakeups, limit}, state) do
    prefix =
      Keys.ctl_group_conversation_delivery_wakeups_prefix(
        state.group_id,
        state.conversation_id
      )

    reply =
      case S3.list(prefix, max_keys: limit) do
        {:ok, %{objects: objects}} -> delete_object_page(objects)
        {:error, reason} -> {:error, reason}
      end

    {reply, state}
  end

  defp execute({:finish_delete, tombstone}, state) do
    reply =
      with :ok <- delete_tombstone_list_index_keys(state, tombstone),
           :ok <- seg_delete_if_present(state.meta_key) do
        :ok
      end

    next_state = if reply == :ok, do: %{state | pending_list_repair: nil}, else: state
    {reply, next_state}
  end

  defp execute(_request, state), do: {{:error, :unsupported_store_operation}, state}

  defp delete_tombstone_list_index_keys(state, tombstone) do
    if tombstone["conversation_id"] == state.conversation_id do
      current_key = seg_conversation_list_index_key(state.group_id, tombstone)

      previous_key =
        previous_list_index_key(
          state.group_id,
          state.conversation_id,
          tombstone[@list_index_previous_updated_at_field]
        )

      pending_keys =
        case state.pending_list_repair do
          %{stale_keys: stale_keys} -> Enum.to_list(stale_keys)
          nil -> []
        end

      [current_key, previous_key | pending_keys]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn key, :ok ->
        case seg_delete_if_present(key) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_delete_tombstone}
    end
  end

  defp previous_list_index_key(group_id, conversation_id, timestamp)
       when is_integer(timestamp) and timestamp >= 0 do
    seg_conversation_list_index_key(group_id, %{
      "conversation_id" => conversation_id,
      "updated_at" => timestamp
    })
  end

  defp previous_list_index_key(_group_id, _conversation_id, _timestamp), do: nil

  defp cache_source(state, conversation) do
    key =
      Keys.ctl_group_conversation_message_segment(
        state.group_id,
        state.conversation_id,
        conversation["current_message_segment"]
      )

    with memo when is_map(memo) <- S3.capture(),
         {:ok, %{body: body}} <- memo[{key, []}],
         {:ok, rows} <- ConversationMessageCodec.decode_segment(body) do
      messages =
        rows |> Enum.filter(&(&1["seq"] <= conversation["message_tail_seq"])) |> Enum.take(-32)

      %{state | source_cache: %{conversation: conversation, messages: messages}}
    else
      _ -> %{state | source_cache: nil}
    end
  end

  defp settle_update_result({:ok, _previous, updated, :ok}, state),
    do: {{:ok, updated}, state}

  defp settle_update_result({:ok, previous, updated, {:error, _reason}}, state) do
    {{:ok, updated}, mark_list_index_dirty(state, previous, updated)}
  end

  defp settle_update_result(other, state), do: {other, state}

  defp settle_update_with_previous_result({:ok, previous, updated, :ok}, state),
    do: {{:ok, previous, updated}, state}

  defp settle_update_with_previous_result(
         {:ok, previous, updated, {:error, _reason}},
         state
       ) do
    {{:ok, previous, updated}, mark_list_index_dirty(state, previous, updated)}
  end

  defp settle_update_with_previous_result(other, state), do: {other, state}

  defp mark_list_index_dirty(state, previous, current) do
    current_key = seg_conversation_list_index_key(state.group_id, current)

    previous_key =
      if is_map(previous), do: seg_conversation_list_index_key(state.group_id, previous)

    pending =
      state.pending_list_repair ||
        %{
          retry_ms: @repair_retry_ms,
          stale_keys: MapSet.new()
        }

    stale_keys =
      if is_binary(previous_key) and previous_key != current_key do
        MapSet.put(pending.stale_keys, previous_key)
      else
        pending.stale_keys
      end
      |> cap_stale_keys()

    if is_nil(state.pending_list_repair), do: send(self(), :repair_list_index)
    %{state | pending_list_repair: %{pending | stale_keys: stale_keys}}
  end

  defp cap_stale_keys(stale_keys) do
    if MapSet.size(stale_keys) <= @repair_stale_key_limit do
      stale_keys
    else
      stale_keys
      |> Enum.take(@repair_stale_key_limit)
      |> MapSet.new()
    end
  end

  defp repair_pending_list_index(state, pending) do
    case seg_get_conversation_raw(state.meta_key) do
      {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) ->
        delete_pending_stale_keys(pending, nil)

      {:ok, current} ->
        current_key = seg_conversation_list_index_key(state.group_id, current)

        with :ok <- seg_put_conversation_list_index(state.group_id, nil, current),
             :ok <- delete_pending_stale_keys(pending, current_key) do
          observe_projection_lag(current)
          :ok
        end

      {:error, :not_found} ->
        delete_pending_stale_keys(pending, nil)

      {:error, _reason} = error ->
        error
    end
  end

  defp observe_projection_lag(%{"log_start_seq" => _, "updated_at" => updated})
       when is_integer(updated) do
    :telemetry.execute(
      [:salix, :conversation_log, :projection],
      %{lag: max(System.system_time(:millisecond) - updated, 0)},
      %{}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe_projection_lag(_), do: :ok

  defp delete_pending_stale_keys(nil, _current_key), do: :ok

  defp delete_pending_stale_keys(pending, current_key) do
    pending.stale_keys
    |> Enum.reject(&(&1 == current_key))
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case seg_delete_if_present(key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp retry_precondition(fun, retries \\ 5)
  defp retry_precondition(fun, 0), do: fun.()

  defp retry_precondition(fun, retries) do
    case fun.() do
      {:error, :precondition_failed} -> retry_precondition(fun, retries - 1)
      result -> result
    end
  end

  # One failed create leaves at most a few message objects per prefix. The
  # bound fails closed instead of sweeping an unexpected large directory.
  defp seg_delete_prefix(_prefix, 0), do: {:error, :uncommitted_message_cleanup_incomplete}

  defp seg_delete_prefix(prefix, pages_left) do
    with {:ok, %{objects: objects}} <- S3.list(prefix, max_keys: 100) do
      case delete_object_page(objects) do
        :empty -> :ok
        :more -> seg_delete_prefix(prefix, pages_left - 1)
        {:error, _reason} = error -> error
      end
    end
  end

  defp delete_object_page([]), do: :empty

  defp delete_object_page(objects) do
    Enum.reduce_while(objects, :more, fn object, :more ->
      case seg_delete_once(object.key) do
        :ok -> {:cont, :more}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @seg_message_segment_max_messages 1_000
  @seg_message_segment_max_bytes 1_000_000
  @seg_message_record_max_bytes @seg_message_segment_max_bytes
  @seg_conversation_list_index_max_timestamp 9_999_999_999_999_999_999
  @seg_conversation_list_index_width 19
  @seg_idempotency_write_attempts 5
  @seg_jsonl_append_attempts 5
  @seg_list_index_write_attempts 5

  defp seg_require_new_conversation_slot(key) do
    case S3.get(key) do
      {:error, :not_found} -> :ok
      {:ok, _object} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_get_conversation(key) do
    with {:ok, meta} <- seg_get_conversation_raw(key),
         false <- not is_nil(meta["deleted_at"]) do
      {:ok, meta}
    else
      true -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp seg_get_conversation_raw(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, meta} when is_map(meta) <- Jason.decode(body) do
      {:ok, meta}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp seg_tombstone_conversation(key, conversation, attempts_left \\ 5)

  defp seg_tombstone_conversation(_key, %{"deleted_at" => deleted_at} = conversation, _attempts)
       when not is_nil(deleted_at),
       do: {:ok, conversation}

  defp seg_tombstone_conversation(key, _conversation, attempts_left) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, current} when is_map(current) <- Jason.decode(body) do
      tombstone = Map.put_new(current, "deleted_at", now())

      case seg_put_json_verifying_ambiguous(key, tombstone, if_match: etag) do
        {:ok, _status} ->
          {:ok, tombstone}

        {:error, :precondition_failed} when attempts_left > 1 ->
          seg_tombstone_conversation(key, current, attempts_left - 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp recover_status_version(state, conversation, target) do
    if (conversation["provider_status_version"] || 0) >= target do
      {:ok, conversation, state}
    else
      # Supersede an interrupted, unacknowledged metadata CAS. Keep all product
      # facts and its business version; only reserve a fresh publication version.
      # A late write against the old ETag can no longer land after index cleanup.
      case execute(
             {:update,
              fn current ->
                Map.put(
                  current,
                  "provider_status_version",
                  max(current["provider_status_version"] || 0, target)
                )
              end},
             state
           ) do
        {{:ok, updated}, state} -> {:ok, updated, state}
        {error, _state} -> error
      end
    end
  end

  defp seg_update_conversation(group_id, conversation_id, key, fun)
       when is_function(fun, 1) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, meta} when is_map(meta) <- Jason.decode(body),
         {:ok, updated} <- conversation_update_result(fun.(meta)),
         updated_meta <-
           seg_conversation_meta(group_id, conversation_id, status_version(updated, meta), meta) do
      seg_commit_conversation_meta_after_list_index(key, group_id, meta, updated_meta, etag)
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp status_version(updated, previous) do
    fields = ~w(status title kind source_refs)

    if Map.take(updated, fields) == Map.take(previous, fields),
      do: updated,
      else:
        Map.put(
          updated,
          "provider_status_version",
          (previous["provider_status_version"] || 0) + 1
        )
  end

  defp conversation_update_result({:error, reason}), do: {:error, reason}
  defp conversation_update_result(updated) when is_map(updated), do: {:ok, updated}
  defp conversation_update_result(other), do: {:error, other}

  defp seg_update_conversation_meta_with_previous(group_id, conversation_id, key, fun)
       when is_function(fun, 1) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, previous_meta} when is_map(previous_meta) <- Jason.decode(body),
         updated when is_map(updated) <- fun.(previous_meta),
         updated_meta <-
           seg_conversation_meta(
             group_id,
             conversation_id,
             status_version(updated, previous_meta),
             previous_meta
           ) do
      seg_commit_conversation_meta_after_list_index(
        key,
        group_id,
        previous_meta,
        updated_meta,
        etag
      )
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :precondition_failed} -> {:error, :precondition_failed}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp seg_commit_conversation_meta_after_list_index(
         _meta_key,
         _group_id,
         previous,
         previous,
         _etag
       ),
       do: {:ok, previous, previous, :ok}

  defp seg_commit_conversation_meta_after_list_index(
         meta_key,
         group_id,
         previous,
         updated,
         etag
       ) do
    updated = seg_put_previous_list_index_timestamp(updated, previous)
    current_key = seg_conversation_list_index_key(group_id, updated)

    with :ok <- seg_put_current_conversation_list_index(group_id, updated),
         :ok <- mark_status_publication(group_id, previous, updated) do
      case seg_put_json_verifying_ambiguous(meta_key, updated, if_match: etag) do
        {:ok, _status} ->
          {:ok, previous, updated,
           seg_delete_previous_conversation_list_index(group_id, previous, updated)}

        {:error, _reason} = error ->
          seg_cleanup_uncommitted_list_index(meta_key, group_id, current_key)
          error
      end
    end
  end

  defp mark_status_publication(group_id, previous, updated) do
    version = updated["provider_status_version"] || 0

    if version > (previous["provider_status_version"] || 0),
      do:
        SalixStore.ConversationLogRecovery.mark(
          group_id,
          updated["conversation_id"],
          updated["message_tail_seq"] || 0,
          version
        ),
      else: :ok
  end

  defp seg_put_previous_list_index_timestamp(updated, previous) do
    Map.put(
      updated,
      @list_index_previous_updated_at_field,
      seg_conversation_list_timestamp(previous)
    )
  end

  defp seg_conversation_list_timestamp(conversation) when is_map(conversation),
    do: SalixIM.TaskArchive.list_timestamp(conversation)

  defp seg_put_current_conversation_list_index(group_id, conversation) do
    seg_put_conversation_list_index_record(
      seg_conversation_list_index_key(group_id, conversation),
      seg_conversation_list_index_entry(group_id, conversation),
      @seg_list_index_write_attempts
    )
  end

  defp seg_delete_previous_conversation_list_index(group_id, previous, current) do
    previous_key = if is_map(previous), do: seg_conversation_list_index_key(group_id, previous)
    current_key = seg_conversation_list_index_key(group_id, current)
    seg_delete_stale_conversation_list_index(previous_key, current_key)
  end

  defp seg_cleanup_uncommitted_list_index(meta_key, group_id, candidate_key) do
    case seg_get_conversation_raw(meta_key) do
      {:ok, current} ->
        if seg_conversation_list_index_key(group_id, current) == candidate_key,
          do: :ok,
          else: seg_delete_if_present(candidate_key)

      {:error, :not_found} ->
        seg_delete_if_present(candidate_key)

      {:error, _reason} ->
        :ok
    end
  end

  defp seg_put_conversation_list_index(group_id, previous, conversation)
       when is_map(conversation) do
    key = seg_conversation_list_index_key(group_id, conversation)
    previous_key = if is_map(previous), do: seg_conversation_list_index_key(group_id, previous)

    with :ok <-
           seg_put_conversation_list_index_record(
             key,
             seg_conversation_list_index_entry(group_id, conversation),
             @seg_list_index_write_attempts
           ),
         :ok <- seg_delete_stale_conversation_list_index(previous_key, key) do
      :ok
    end
  end

  defp seg_conversation_list_index_key(group_id, conversation) when is_map(conversation) do
    Keys.ctl_group_conversation_list_entry(
      group_id,
      seg_conversation_list_sort_key(seg_conversation_list_timestamp(conversation)),
      conversation["conversation_id"] || ""
    )
  end

  defp seg_delete_stale_conversation_list_index(nil, _current_key), do: :ok
  defp seg_delete_stale_conversation_list_index(current_key, current_key), do: :ok

  defp seg_delete_stale_conversation_list_index(previous_key, _current_key),
    do: seg_delete_if_present(previous_key)

  defp seg_put_conversation_list_index_record(key, entry, attempts_left) do
    case seg_put_json_verifying_ambiguous(key, entry) do
      {:ok, _} ->
        :ok

      {:error, _reason} when attempts_left > 1 ->
        seg_put_conversation_list_index_record(key, entry, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seg_delete_if_present(key), do: seg_delete_if_present(key, @seg_list_index_write_attempts)

  defp seg_delete_once(key) do
    case S3.delete(key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_delete_if_present(key, attempts_left) do
    case S3.delete(key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} when attempts_left > 1 -> seg_delete_if_present(key, attempts_left - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_conversation_list_index_entry(group_id, conversation) do
    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation["conversation_id"] || "",
      "updated_at" => seg_conversation_list_timestamp(conversation)
    }
  end

  defp seg_conversation_list_sort_key(value) do
    timestamp =
      value
      |> seg_normalize_non_negative_integer()
      |> min(@seg_conversation_list_index_max_timestamp)

    (@seg_conversation_list_index_max_timestamp - timestamp)
    |> Integer.to_string()
    |> String.pad_leading(@seg_conversation_list_index_width, "0")
  end

  defp seg_normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp seg_normalize_non_negative_integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp seg_put_new_json_record(key, record),
    do: seg_put_new_json_record(key, record, @seg_idempotency_write_attempts, :new)

  defp seg_put_new_json_record(key, record, attempts_left, ownership) do
    body = Jason.encode!(record)

    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} ->
        {:ok, seg_create_once_status(ownership)}

      {:error, :precondition_failed} ->
        seg_verify_create_once_result(
          key,
          record,
          if(ownership == :ambiguous, do: :ambiguous_landed, else: :preexisting),
          attempts_left,
          ownership
        )

      {:error, {:ambiguous, _reason}} ->
        seg_verify_create_once_result(
          key,
          record,
          :ambiguous_landed,
          attempts_left,
          :ambiguous
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seg_create_once_status(:new), do: :inserted
  defp seg_create_once_status(:ambiguous), do: :ambiguous_landed

  defp seg_verify_create_once_result(key, record, status, attempts_left, ownership) do
    case seg_verify_existing_json_record(key, record, status) do
      {:error, reason} when reason != :record_conflict and attempts_left > 1 ->
        Process.sleep(5)
        seg_put_new_json_record(key, record, attempts_left - 1, ownership)

      result ->
        result
    end
  end

  defp seg_verify_existing_json_record(key, expected, status) do
    case seg_read_json(key) do
      {:ok, ^expected} -> {:ok, status}
      {:ok, _other} -> {:error, :record_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_put_json_verifying_ambiguous(key, record, opts \\ []),
    do: seg_put_json_verifying_ambiguous(key, record, opts, @seg_idempotency_write_attempts)

  defp seg_put_json_verifying_ambiguous(key, record, opts, attempts_left) do
    case S3.put(key, Jason.encode!(record), opts) do
      {:error, :precondition_failed} ->
        seg_verify_json_write(key, record, opts, attempts_left, :precondition_failed)

      {:error, {:ambiguous, _reason}} ->
        seg_verify_json_write(key, record, opts, attempts_left, :ambiguous)

      result ->
        result
    end
  end

  defp seg_verify_json_write(key, record, opts, attempts_left, failure_kind) do
    case seg_read_json(key) do
      {:ok, ^record} ->
        {:ok, seg_verified_write_status(failure_kind)}

      _other when attempts_left > 1 ->
        Process.sleep(5)
        seg_put_json_verifying_ambiguous(key, record, opts, attempts_left - 1)

      {:ok, _other} when failure_kind == :precondition_failed ->
        {:error, :precondition_failed}

      {:ok, _other} ->
        {:error, :ambiguous_write_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seg_verified_write_status(:precondition_failed), do: :precondition_verified
  defp seg_verified_write_status(:ambiguous), do: :ambiguous_verified

  # Explicit migration only. Each owner call converts at most 32 rows in one
  # bounded segment. Keep the original bytes before the additive rewrite.
  defp seg_backfill_message_threads(state, after_seq)
       when is_integer(after_seq) and after_seq >= 0 do
    with {:ok, meta} <- seg_get_conversation(state.meta_key) do
      tail = meta["message_tail_seq"] || 0

      if after_seq >= tail do
        {:ok, %{after_seq: after_seq, updated: 0, done: true}}
      else
        seg_backfill_message_thread_batch(state, after_seq, tail)
      end
    end
  end

  defp seg_backfill_message_threads(_state, _after_seq), do: {:error, :invalid_message_sequence}

  defp seg_backfill_message_thread_batch(state, after_seq, tail) do
    group_id = state.group_id
    conversation_id = state.conversation_id

    pointer_key =
      Keys.ctl_group_conversation_message_seq_index(group_id, conversation_id, after_seq + 1)

    with {:ok, %{"segment_id" => segment_id}} <-
           seg_read_message_pointer(pointer_key, %{"seq" => after_seq + 1}),
         segment_key =
           Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id),
         {:ok, %{body: body, etag: etag}} <- S3.get(segment_key),
         {:ok, rows} <- ConversationMessageCodec.decode_segment(body),
         {:ok, index} <- seg_get_message_segment_index(group_id, conversation_id, segment_id),
         batch = rows |> Enum.filter(&(&1["seq"] > after_seq)) |> Enum.take(32),
         {:ok, replacements} <- seg_message_thread_roots(group_id, conversation_id, batch),
         updated_rows = Enum.map(rows, &Map.get(replacements, &1["message_id"], &1)),
         {:ok, updated_body} <-
           seg_write_message_thread_batch(
             group_id,
             conversation_id,
             segment_id,
             segment_key,
             body,
             etag,
             rows,
             updated_rows
           ),
         :ok <-
           seg_put_message_segment_index(
             group_id,
             conversation_id,
             Map.merge(index, ConversationMessageCodec.segment_facts(updated_rows, updated_body))
           ) do
      next_seq = List.last(batch)["seq"]
      updated = Enum.count(batch, &is_nil(&1["thread_root_message_id"]))
      {:ok, %{after_seq: next_seq, updated: updated, done: next_seq >= tail}}
    end
  end

  defp seg_message_thread_roots(group_id, conversation_id, rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, resolved} ->
      parent_id = row["reply_to_message_id"]

      result =
        cond do
          is_binary(row["thread_root_message_id"]) ->
            {:ok, row["thread_root_message_id"]}

          is_nil(parent_id) ->
            {:ok, row["message_id"]}

          true ->
            parent =
              case Map.fetch(resolved, parent_id) do
                {:ok, parent} -> {:ok, parent}
                :error -> seg_message_by_id(group_id, conversation_id, parent_id)
              end

            with {:ok, parent} <- parent,
                 true <- parent["seq"] < row["seq"] do
              case parent["thread_root_message_id"] do
                root when is_binary(root) -> {:ok, root}
                _ -> {:error, :message_thread_backfill_requires_earlier_batch}
              end
            else
              false -> {:error, :invalid_reply_target}
              error -> error
            end
        end

      case result do
        {:ok, root} ->
          {:cont,
           {:ok,
            Map.put(resolved, row["message_id"], Map.put(row, "thread_root_message_id", root))}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp seg_write_message_thread_batch(
         _group_id,
         _conversation_id,
         _segment_id,
         _key,
         body,
         _etag,
         rows,
         rows
       ),
       do: {:ok, body}

  defp seg_write_message_thread_batch(
         group_id,
         conversation_id,
         segment_id,
         key,
         body,
         etag,
         _rows,
         updated
       ) do
    backup_key =
      Keys.ctl_group_conversation_message_thread_backup(group_id, conversation_id, segment_id)

    updated_body = Enum.map_join(updated, &(Jason.encode!(&1) <> "\n"))

    with :ok <- seg_backup_message_thread_segment(backup_key, body),
         :ok <- ConversationMessageCodec.validate_rows(updated),
         {:ok, _} <- S3.put(key, updated_body, if_match: etag) do
      {:ok, updated_body}
    end
  end

  defp seg_backup_message_thread_segment(key, body) do
    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> :ok
      error -> error
    end
  end

  defp seg_message_by_id(group_id, conversation_id, message_id) do
    if Ids.valid_group_id?(group_id) and Ids.valid_conversation_id?(conversation_id) and
         Ids.valid_message_id?(message_id) do
      message_hash = Crypto.hex(message_id)
      key = Keys.ctl_group_conversation_message_identity(group_id, conversation_id, message_hash)

      with {:ok, %{"seq" => seq, "segment_id" => segment_id} = pointer} <-
             seg_read_message_pointer(key, %{"message_id" => message_id}) do
        seg_message_by_seq(group_id, conversation_id, seq, segment_id, %{
          "message_id" => pointer["message_id"]
        })
      end
    else
      {:error, :invalid_message_identity}
    end
  end

  defp seg_message_by_request_identity(group_id, conversation_id, request_identity) do
    case seg_normalize_id_part(request_identity) do
      "" ->
        {:error, :invalid_message_identity}

      request_identity ->
        source_hash = Crypto.hex(request_identity)

        key =
          Keys.ctl_group_conversation_message_idempotency(group_id, conversation_id, source_hash)

        with {:ok, pointer} <-
               seg_read_message_pointer(key, %{"request_identity" => request_identity}) do
          case pointer do
            %{"status" => "reserved"} ->
              {:ok, pointer}

            %{"seq" => seq, "segment_id" => segment_id} ->
              seg_message_by_seq(group_id, conversation_id, seq, segment_id, %{
                "message_id" => pointer["message_id"],
                "request_identity" => request_identity
              })

            _invalid_pointer ->
              {:error, :invalid_message_pointer}
          end
        end
    end
  end

  defp seg_reserve_message_request(group_id, conversation_id, message) when is_map(message) do
    case seg_normalize_id_part(message["request_identity"]) do
      "" ->
        {:ok, message}

      request_identity ->
        reservation =
          message
          |> Map.take(~w(message_id request_identity request_fingerprint created_at))
          |> Map.put("status", "reserved")

        key =
          Keys.ctl_group_conversation_message_idempotency(
            group_id,
            conversation_id,
            Crypto.hex(request_identity)
          )

        case S3.put(key, Jason.encode!(reservation), if_none_match: "*") do
          {:ok, _} -> seg_reuse_reserved_message_identity(message, reservation)
          {:error, :precondition_failed} -> seg_reuse_message_request_reservation(key, message)
          {:error, {:ambiguous, _reason}} -> seg_reuse_message_request_reservation(key, message)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp seg_reuse_message_request_reservation(key, message) do
    with {:ok, actual} <- seg_read_json(key),
         true <- seg_same_message_request_identity?(actual, message) do
      seg_reuse_reserved_message_identity(message, actual)
    else
      false -> {:error, :idempotency_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_reuse_reserved_message_identity(message, reservation) do
    case reservation do
      %{"message_id" => message_id, "created_at" => created_at}
      when is_binary(message_id) and is_integer(created_at) ->
        if Ids.valid_message_id?(message_id) do
          {:ok,
           message
           |> Map.put("message_id", message_id)
           |> Map.put("created_at", created_at)}
        else
          {:error, :invalid_message_pointer}
        end

      _ ->
        {:error, :invalid_message_pointer}
    end
  end

  defp seg_same_message_request_identity?(left, right) do
    left["request_identity"] == right["request_identity"] and
      left["request_fingerprint"] == right["request_fingerprint"]
  end

  defp seg_append_message(group_id, conversation_id, key, message) do
    with true <- Ids.valid_message_id?(message["message_id"]),
         {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, meta} when is_map(meta) <- Jason.decode(body) do
      case seg_committed_message(group_id, conversation_id, meta, message) do
        {:ok, existing} ->
          if seg_same_request?(existing, message),
            do: {:ok, :exists, meta},
            else: message_conflict(existing, message)

        :not_found ->
          seg_append_uncommitted_message(
            key,
            group_id,
            conversation_id,
            meta,
            etag,
            message
          )

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      false -> {:error, {:bad_request, "invalid message_id"}}
      other -> {:error, other}
    end
  end

  defp seg_committed_message(group_id, conversation_id, meta, message) do
    with {:ok, request_pointer} <-
           seg_optional_request_pointer(
             group_id,
             conversation_id,
             message["request_identity"]
           ),
         {:ok, message_pointer} <-
           seg_optional_message_pointer(
             Keys.ctl_group_conversation_message_identity(
               group_id,
               conversation_id,
               Crypto.hex(message["message_id"])
             ),
             %{"message_id" => message["message_id"]}
           ) do
      case Enum.find(
             [request_pointer, message_pointer],
             &(is_map(&1) and is_integer(&1["seq"]) and is_binary(&1["segment_id"]))
           ) do
        nil ->
          seg_repair_landed_message(group_id, conversation_id, meta, message)

        pointer ->
          expected =
            %{"message_id" => pointer["message_id"]}
            |> seg_put_expected_request_identity(message["request_identity"])

          if pointer["seq"] > (meta["message_tail_seq"] || 0) do
            :not_found
          else
            case seg_message_by_seq(
                   group_id,
                   conversation_id,
                   pointer["seq"],
                   pointer["segment_id"],
                   expected
                 ) do
              {:ok, existing} -> {:ok, existing}
              {:error, :not_found} -> {:error, :message_pointer_target_missing}
              {:error, _reason} = error -> error
            end
          end
      end
    end
  end

  defp seg_optional_request_pointer(_group_id, _conversation_id, request_identity)
       when request_identity in [nil, ""],
       do: {:ok, nil}

  defp seg_optional_request_pointer(group_id, conversation_id, request_identity) do
    Keys.ctl_group_conversation_message_idempotency(
      group_id,
      conversation_id,
      Crypto.hex(seg_normalize_id_part(request_identity))
    )
    |> seg_optional_message_pointer(%{"request_identity" => request_identity})
  end

  defp seg_optional_message_pointer(key, expected) do
    case seg_read_message_pointer(key, expected) do
      {:ok, pointer} -> {:ok, pointer}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp seg_repair_landed_message(group_id, conversation_id, meta, incoming) do
    case seg_normalize_id_part(meta["current_message_segment"]) do
      "" ->
        :not_found

      segment_id ->
        key = Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

        with {:ok, rows} <- seg_read_jsonl_segment(key) do
          case Enum.find(rows, fn row ->
                 row["message_id"] == incoming["message_id"] or
                   (seg_normalize_id_part(incoming["request_identity"]) != "" and
                      row["request_identity"] == incoming["request_identity"])
               end) do
            nil ->
              :not_found

            landed ->
              if landed["seq"] > (meta["message_tail_seq"] || 0) do
                :not_found
              else
                if seg_same_request?(landed, incoming) do
                  with :ok <-
                         seg_put_message_seq_index(
                           group_id,
                           conversation_id,
                           landed,
                           segment_id
                         ),
                       :ok <-
                         seg_put_message_indexes(
                           group_id,
                           conversation_id,
                           landed,
                           segment_id
                         ) do
                    {:ok, landed}
                  end
                else
                  message_conflict(landed, incoming)
                end
              end
          end
        else
          {:error, :not_found} -> :not_found
          {:error, _reason} = error -> error
        end
    end
  end

  defp seg_put_expected_request_identity(expected, request_identity)
       when request_identity in [nil, ""],
       do: expected

  defp seg_put_expected_request_identity(expected, request_identity),
    do: Map.put(expected, "request_identity", request_identity)

  defp seg_append_uncommitted_message(
         key,
         group_id,
         conversation_id,
         meta,
         etag,
         incoming
       ) do
    seq = (meta["message_tail_seq"] || meta["message_count"] || 0) + 1
    incoming = Map.put(incoming, "seq", seq)

    with {:ok, encoded_line} <- seg_encode_message_segment_line(incoming),
         {:ok, segment_id, segment_meta, previous_segment_meta} <-
           seg_message_segment_for_append(
             group_id,
             conversation_id,
             meta,
             seq,
             encoded_line
           ),
         {:ok, status, message} <-
           seg_landed_or_incoming_message(
             group_id,
             conversation_id,
             segment_id,
             seq,
             incoming
           ),
         true <- status == :occupied or seg_same_request?(message, incoming),
         {:ok, _updated, _write_status, list_index_result} <-
           seg_commit_message(
             key,
             group_id,
             conversation_id,
             meta,
             etag,
             message,
             segment_id,
             segment_meta,
             previous_segment_meta
           ) do
      if status == :occupied do
        {:error, :precondition_failed}
      else
        with {:ok, conversation} <- seg_get_conversation(key),
             do: {:ok, status, conversation, meta, list_index_result}
      end
    else
      false -> {:error, :message_id_collision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_stage_first_message(group_id, conversation_id, meta, incoming) do
    incoming = Map.put(incoming, "seq", 1)

    with :ok <-
           if(Ids.valid_message_id?(incoming["message_id"]),
             do: :ok,
             else: {:error, {:bad_request, "invalid message_id"}}
           ),
         {:ok, encoded_line} <- seg_encode_message_segment_line(incoming),
         {:ok, segment_id, segment_meta, previous_segment_meta} <-
           seg_message_segment_for_append(group_id, conversation_id, meta, 1, encoded_line),
         {:ok, status, message} <-
           seg_landed_or_incoming_message(group_id, conversation_id, segment_id, 1, incoming),
         true <- status != :occupied,
         {:ok, published} <-
           seg_stage_message(
             group_id,
             conversation_id,
             meta,
             message,
             segment_id,
             segment_meta,
             previous_segment_meta
           ) do
      {:ok, published, message}
    else
      false -> {:error, :uncommitted_message_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_landed_or_incoming_message(
         group_id,
         conversation_id,
         segment_id,
         seq,
         incoming
       ) do
    key = Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    case seg_read_jsonl_segment(key) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1["seq"] == seq)) do
          nil ->
            {:ok, :inserted, incoming}

          landed ->
            if seg_same_request?(landed, incoming),
              do: {:ok, :exists, landed},
              else: {:ok, :occupied, landed}
        end

      {:error, :not_found} ->
        {:ok, :inserted, incoming}

      {:error, _reason} = error ->
        error
    end
  end

  defp seg_commit_message(
         key,
         group_id,
         conversation_id,
         meta,
         etag,
         message,
         segment_id,
         segment_meta,
         previous_segment_meta
       ) do
    with {:ok, updated_meta} <-
           seg_stage_message(
             group_id,
             conversation_id,
             meta,
             message,
             segment_id,
             segment_meta,
             previous_segment_meta
           ),
         {:ok, write_status} <-
           seg_publish_message_meta(key, group_id, meta, updated_meta, etag) do
      projection =
        if is_integer(meta["log_start_seq"]),
          do: {:error, :projection_deferred},
          else: seg_delete_previous_conversation_list_index(group_id, meta, updated_meta)

      {:ok, updated_meta, write_status, projection}
    end
  end

  # Writes the segment row, every locator and the recovery mark for one
  # message, then returns the meta that publishes it. Nothing is visible until
  # the caller writes that meta: readers ignore rows above message_tail_seq.
  defp seg_stage_message(
         group_id,
         conversation_id,
         meta,
         message,
         segment_id,
         segment_meta,
         previous_segment_meta
       ) do
    seq = message["seq"]

    segment_key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    with updated_meta =
           meta
           |> Map.put("message_count", max(meta["message_count"] || 0, seq))
           |> Map.put("target_message_count", max(meta["target_message_count"] || 0, seq))
           |> Map.put("message_tail_seq", max(meta["message_tail_seq"] || 0, seq))
           |> Map.put_new("message_head_seq", seq)
           |> Map.put("current_message_segment", segment_id)
           |> Map.put("current_message_segment_start_seq", segment_meta["start_seq"] || seq)
           |> seg_project_task_message(message)
           |> Map.put(
             "updated_at",
             if(is_map(message["provider_status"]) or is_map(message["provider_effect"]),
               do: meta["updated_at"],
               else: max((meta["updated_at"] || 0) + 1, message["created_at"] || 0)
             )
           ),
         {:ok, appended_segment} <-
           seg_append_jsonl_bounded(
             segment_key,
             message,
             @seg_message_segment_max_messages,
             @seg_message_segment_max_bytes
           ),
         :ok <-
           parallel_indexes([
             fn ->
               seg_put_message_segment_index_after_append(
                 group_id,
                 conversation_id,
                 segment_id,
                 segment_meta,
                 message,
                 appended_segment
               )
             end,
             fn ->
               seg_put_previous_message_segment_index(
                 group_id,
                 conversation_id,
                 previous_segment_meta
               )
             end,
             fn -> seg_put_message_seq_index(group_id, conversation_id, message, segment_id) end,
             fn -> seg_put_message_indexes(group_id, conversation_id, message, segment_id) end
           ]),
         :ok <- SalixStore.ConversationLogRecovery.mark(group_id, conversation_id, seq) do
      {:ok, updated_meta}
    end
  end

  defp seg_publish_message_meta(key, group_id, previous, updated, etag) do
    updated = seg_put_previous_list_index_timestamp(updated, previous)

    if is_integer(previous["log_start_seq"]) do
      seg_put_json_verifying_ambiguous(key, updated, if_match: etag)
    else
      with :ok <- seg_put_current_conversation_list_index(group_id, updated) do
        case seg_put_json_verifying_ambiguous(key, updated, if_match: etag) do
          {:ok, _} = result ->
            result

          {:error, _} = error ->
            seg_cleanup_uncommitted_list_index(
              key,
              group_id,
              seg_conversation_list_index_key(group_id, updated)
            )

            error
        end
      end
    end
  end

  defp seg_project_task_message(%{"kind" => "agent_task"} = meta, message) do
    if task_public_output?(meta, message),
      do: Map.put(meta, "task_public_output_message_id", message["message_id"]),
      else: meta
  end

  defp seg_project_task_message(meta, _message), do: meta

  defp task_public_output?(_meta, message), do: SlackTaskCard.output_message?(message)

  defp message_conflict(existing, incoming) do
    if seg_normalize_id_part(incoming["request_identity"]) != "" and
         existing["request_identity"] == incoming["request_identity"] do
      {:error, :idempotency_conflict}
    else
      {:error, :message_id_collision}
    end
  end

  defp seg_same_request?(existing, incoming) do
    same_identity? =
      case seg_normalize_id_part(incoming["request_identity"]) do
        "" -> existing["message_id"] == incoming["message_id"]
        request_identity -> existing["request_identity"] == request_identity
      end

    same_identity? and existing["request_fingerprint"] == incoming["request_fingerprint"]
  end

  defp seg_conversation_meta(group_id, conversation_id, rec, previous_meta \\ %{}) do
    message_count = rec["message_count"] || previous_meta["message_count"] || 0

    now = System.system_time(:millisecond)

    rec
    |> Map.drop(["participants", "messages", "participant_count"])
    |> Map.put("conversation_id", conversation_id)
    |> Map.put("agent_group_id", group_id)
    |> Map.put("message_count", message_count)
    |> Map.put(
      "target_message_count",
      rec["target_message_count"] || previous_meta["target_message_count"] || message_count
    )
    |> Map.put_new(
      "message_head_seq",
      previous_meta["message_head_seq"] || if(message_count > 0, do: 1)
    )
    |> Map.put_new("message_tail_seq", previous_meta["message_tail_seq"] || message_count)
    |> Map.put_new("current_message_segment", previous_meta["current_message_segment"])
    |> Map.put_new(
      "current_message_segment_start_seq",
      previous_meta["current_message_segment_start_seq"]
    )
    |> Map.put_new("created_at", previous_meta["created_at"] || now)
    |> Map.put_new("updated_at", previous_meta["updated_at"] || now)
    |> seg_drop_nil_values()
  end

  defp seg_encode_message_segment_line(message) do
    ConversationMessageCodec.encode_row(message,
      max_bytes: @seg_message_record_max_bytes,
      oversize_error: {:bad_request, "message is too large"}
    )
  end

  defp seg_message_segment_for_append(group_id, conversation_id, meta, seq, encoded_line) do
    current_segment_id =
      case seg_normalize_id_part(meta["current_message_segment"]) do
        "" -> seg_segment_id(seq)
        value -> value
      end

    key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, current_segment_id)

    case S3.get(key) do
      {:ok, %{body: body}} ->
        with {:ok, rows} <- ConversationMessageCodec.decode_segment(body),
             {:ok, segment_meta} <-
               seg_message_segment_index_or_default(
                 group_id,
                 conversation_id,
                 current_segment_id,
                 rows,
                 body,
                 meta,
                 seq
               ) do
          if seg_message_segment_accepts?(body, rows, encoded_line) do
            {:ok, current_segment_id, segment_meta, nil}
          else
            seg_plan_next_message_segment(
              group_id,
              conversation_id,
              current_segment_id,
              segment_meta,
              rows,
              body,
              seq
            )
          end
        end

      {:error, :not_found} ->
        segment_meta = seg_new_message_segment_index(current_segment_id, seq, nil)
        {:ok, current_segment_id, segment_meta, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seg_message_segment_accepts?(body, rows, encoded_line) do
    length(rows) < @seg_message_segment_max_messages and
      byte_size(body) + byte_size(encoded_line) <= @seg_message_segment_max_bytes
  end

  defp seg_plan_next_message_segment(
         _group_id,
         _conversation_id,
         current_segment_id,
         current_segment_meta,
         current_rows,
         current_body,
         seq
       ) do
    next_segment_id = seg_segment_id(seq)

    if next_segment_id == current_segment_id do
      {:error, :segment_full}
    else
      facts = ConversationMessageCodec.segment_facts(current_rows, current_body)

      sealed_meta =
        current_segment_meta
        |> Map.put("status", "sealed")
        |> Map.merge(facts)
        |> Map.put("next_segment_id", next_segment_id)
        |> Map.put("updated_at", System.system_time(:millisecond))

      next_meta = seg_new_message_segment_index(next_segment_id, seq, current_segment_id)

      {:ok, next_segment_id, next_meta, sealed_meta}
    end
  end

  defp seg_put_previous_message_segment_index(_group_id, _conversation_id, nil), do: :ok

  defp seg_put_previous_message_segment_index(group_id, conversation_id, segment_meta)
       when is_map(segment_meta),
       do: seg_put_message_segment_index(group_id, conversation_id, segment_meta)

  # The index is derived from the append's settled rows/body, not a read-back
  # of the segment: the conversation owner is the segment's only writer, so the
  # bytes this append landed (or found already landed on the duplicate path)
  # are the segment's current content. `validate_rows/1` keeps the same row
  # validation the former read-back's `decode_segment/1` applied.
  defp seg_put_message_segment_index_after_append(
         group_id,
         conversation_id,
         segment_id,
         segment_meta,
         message,
         %{rows: rows, body: body}
       ) do
    with :ok <- ConversationMessageCodec.validate_rows(rows) do
      status = if seg_message_segment_full?(body, rows), do: "sealed", else: "open"

      segment_meta =
        segment_meta
        |> Map.put("segment_id", segment_id)
        |> Map.put_new("start_seq", message["seq"])
        |> Map.merge(ConversationMessageCodec.segment_facts(rows, body))
        |> Map.put("status", status)
        |> Map.put("updated_at", System.system_time(:millisecond))
        |> seg_drop_nil_values()

      seg_put_message_segment_index(group_id, conversation_id, segment_meta)
    end
  end

  defp seg_message_segment_full?(body, rows) do
    length(rows) >= @seg_message_segment_max_messages or
      byte_size(body) >= @seg_message_segment_max_bytes
  end

  defp seg_message_segment_index_or_default(
         group_id,
         conversation_id,
         segment_id,
         rows,
         body,
         meta,
         seq
       ) do
    case seg_get_message_segment_index(group_id, conversation_id, segment_id) do
      {:ok, rec} ->
        # The index is a projection of the canonical rows. Derive its current
        # facts directly, including after an interrupted append.
        {:ok,
         rec
         |> Map.put("segment_id", segment_id)
         |> Map.merge(ConversationMessageCodec.segment_facts(rows, body))
         |> Map.put(
           "status",
           if(seg_message_segment_full?(body, rows), do: "sealed", else: "open")
         )}

      {:error, :not_found} ->
        facts = ConversationMessageCodec.segment_facts(rows, body)
        start_seq = facts["start_seq"] || meta["current_message_segment_start_seq"] || seq

        {:ok,
         seg_new_message_segment_index(segment_id, start_seq, nil)
         |> Map.merge(facts)
         |> Map.put(
           "status",
           if(seg_message_segment_full?(body, rows), do: "sealed", else: "open")
         )
         |> seg_drop_nil_values()}

      {:error, _reason} = error ->
        error
    end
  end

  defp seg_new_message_segment_index(segment_id, start_seq, previous_segment_id) do
    now = System.system_time(:millisecond)

    %{
      "segment_id" => segment_id,
      "start_seq" => start_seq,
      "previous_segment_id" => previous_segment_id,
      "message_count" => 0,
      "byte_size" => 0,
      "status" => "open",
      "created_at" => now,
      "updated_at" => now
    }
    |> seg_drop_nil_values()
  end

  defp seg_get_message_segment_index(group_id, conversation_id, segment_id) do
    group_id
    |> Keys.ctl_group_conversation_message_segment_index(conversation_id, segment_id)
    |> seg_read_json()
  end

  defp seg_put_message_segment_index(group_id, conversation_id, segment_meta) do
    segment_id = segment_meta["segment_id"]
    key = Keys.ctl_group_conversation_message_segment_index(group_id, conversation_id, segment_id)

    case seg_put_json_verifying_ambiguous(key, segment_meta) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_put_message_indexes(group_id, conversation_id, message, segment_id) do
    rec =
      %{
        "message_id" => message["message_id"],
        "request_identity" => message["request_identity"],
        "request_fingerprint" => message["request_fingerprint"],
        "seq" => message["seq"],
        "segment_id" => segment_id,
        "created_at" => message["created_at"]
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    identity_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        Crypto.hex(message["message_id"])
      )

    request_write = fn ->
      case seg_normalize_id_part(message["request_identity"]) do
        "" ->
          :ok

        request_identity ->
          request_key =
            Keys.ctl_group_conversation_message_idempotency(
              group_id,
              conversation_id,
              Crypto.hex(request_identity)
            )

          seg_put_final_message_index(request_key, rec, :idempotency_conflict)
      end
    end

    parallel_indexes([
      fn -> seg_put_final_message_index(identity_key, rec, :message_id_collision) end,
      request_write
    ])
  end

  # Independent locators settle before publication of the authoritative tail.
  defp parallel_indexes(writes) do
    memo = S3.capture()

    results =
      Task.async_stream(
        writes,
        fn write ->
          {result, updated} = S3.run(memo, write)

          changes =
            if updated,
              do: Map.reject(updated, fn {key, value} -> (memo || %{})[key] == value end)

          {result, changes}
        end,
        max_concurrency: 4,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    case Enum.find(results, fn result -> not match?({:ok, {:ok, _}}, result) end) do
      nil ->
        Enum.each(results, fn {:ok, {:ok, changes}} -> S3.merge(changes) end)

      {:ok, {{:error, _} = error, _}} ->
        S3.reset()
        error

      {:exit, reason} ->
        S3.reset()
        {:error, {:index_write_failed, reason}}
    end
  end

  defp seg_put_message_seq_index(group_id, conversation_id, message, segment_id),
    do:
      group_id
      |> Keys.ctl_group_conversation_message_seq_index(conversation_id, message["seq"])
      |> seg_put_final_message_index(
        %{
          "message_id" => message["message_id"],
          "seq" => message["seq"],
          "segment_id" => segment_id,
          "created_at" => message["created_at"]
        },
        :message_sequence_conflict
      )

  defp seg_put_final_message_index(key, expected, conflict) do
    case CasRecord.update(
           key,
           fn
             nil ->
               expected

             ^expected ->
               {:unchanged, expected}

             actual ->
               if seg_compatible_message_index?(actual, expected),
                 do: expected,
                 else: {:error, conflict}
           end,
           store: S3
         ) do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seg_compatible_message_index?(actual, expected) do
    Enum.all?(~w(message_id seq segment_id), fn field ->
      actual[field] in [nil, "", expected[field]]
    end) and
      (is_nil(actual["request_identity"]) or
         seg_same_message_request_identity?(actual, expected))
  end

  defp seg_append_jsonl_bounded(key, rec, max_lines, max_bytes) do
    BoundedJsonl.append(
      key,
      rec,
      store: S3,
      max_lines: max_lines,
      max_bytes: max_bytes,
      attempts: @seg_jsonl_append_attempts,
      identity_fields: ~w(delivery_id message_id),
      conflict_fields: [{"seq", "message_id"}],
      oversize_error: {:bad_request, "message is too large"}
    )
  end

  defp seg_read_message_pointer(key, expected) do
    case CasRecord.get(key, :invalid_record, store: S3) do
      {:ok, rec} ->
        with :ok <-
               ConversationMessageCodec.validate_pointer(rec, expected, allow_reservation: true) do
          {:ok, rec}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp seg_message_by_seq(group_id, conversation_id, seq, segment_id, expected)
       when is_integer(seq) do
    key = Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    with {:ok, rows} <- seg_read_jsonl_segment(key) do
      pointer =
        expected
        |> Map.new()
        |> Map.put("seq", seq)
        |> Map.put("segment_id", segment_id)

      ConversationMessageCodec.target_row(rows, pointer, expected)
    end
  end

  defp seg_message_by_seq(_group_id, _conversation_id, _seq, _segment_id, _expected),
    do: {:error, :invalid_message_pointer}

  defp seg_read_jsonl_segment(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> ConversationMessageCodec.decode_segment(body)
      {:error, _reason} = error -> error
    end
  end

  defp seg_segment_id(seq), do: seq |> Integer.to_string() |> String.pad_leading(18, "0")

  defp seg_normalize_id_part(value) when is_binary(value), do: String.trim(value)
  defp seg_normalize_id_part(value) when is_integer(value), do: Integer.to_string(value)
  defp seg_normalize_id_part(_value), do: ""

  defp seg_read_json(key), do: CasRecord.get(key, :invalid_record, store: S3)

  defp seg_drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp now, do: System.system_time(:millisecond)
end
