defmodule SalixIM.ConversationParticipantActor do
  @moduledoc """
  Owner of one Conversation Participant, its provider log cursor and receipts.

  Conversation messages are shared facts. Agent owners admit them into Sessions;
  this owner consumes provider targets and performs platform I/O outside its mailbox.
  Receipt claims precede I/O. Receipt settlement precedes cursor advancement.
  Task-thread fences stop new sends and wait for unresolved requests to settle.
  Runtime subscription state remains local to this Participant.
  """
  use GenServer

  alias SalixIM.{
    ConversationDelivery,
    ConversationMessage,
    ConversationParticipantActivity,
    ConversationParticipantStore,
    Conversations,
    SlackTaskCard
  }

  alias SalixIM.Ports.SessionActivity

  @delivery_lease_ms 120_000
  @max_delivery_attempts 3
  @delivery_retry_backoff_ms 5_000
  @provider_verify_grace_ms 1_000
  @task_thread_binding_type "task"
  @delete_batch_size 50
  @delete_retry_ms 50
  @call_timeout :infinity
  @legacy_delivery_fact_fields ~w(
    delivery_id delivery_kind notification_kind request_identity request_fingerprint
    message_id message_seq source_participant_id source_actor_type source_user_id
    source_agent_id source_role_label message_content message_metadata message_created_at
    delivery_session_name delivery_billing_context
  )

  defstruct group_id: nil,
            conversation_id: nil,
            participant_id: nil,
            store_pid: nil,
            participant: nil,
            participant_load_error: :not_loaded,
            drain_pid: nil,
            active_delivery: nil,
            drain_requested?: false,
            realtime_status: nil,
            realtime_status_ref: nil,
            realtime_refresh: nil,
            realtime_subscribers: %{},
            session_ref: nil,
            deleted?: false

  def child_spec(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    participant_id = Keyword.fetch!(opts, :participant_id)

    %{
      id: key(group_id, conversation_id, participant_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    participant_id = Keyword.fetch!(opts, :participant_id)
    GenServer.start_link(__MODULE__, opts, name: via(group_id, conversation_id, participant_id))
  end

  def key(group_id, conversation_id, participant_id),
    do: {:conversation_participant, group_id, conversation_id, participant_id}

  def advance_delivery_cursor(pid, seq) when is_integer(seq) and seq >= 0,
    do: call(pid, {:advance_delivery_cursor, seq})

  def put_new(pid, participant) when is_map(participant),
    do: call(pid, {:put_new, participant})

  def ensure_reserved(pid, participant) when is_map(participant),
    do: call(pid, {:ensure_reserved, participant})

  def ensure_reserved_incarnation(pid, participant, contract)
      when is_map(participant) and is_map(contract),
      do: call(pid, {:ensure_reserved_incarnation, participant, contract})

  def deactivate(pid, updated_at),
    do: call(pid, {:deactivate, updated_at})

  def deactivate_if_payload(pid, expected_payload, updated_at) when is_map(expected_payload),
    do: call(pid, {:deactivate_if_payload, expected_payload, updated_at})

  def fence_incarnation(pid, expected_payload, fence_token, cutoff_seq, updated_at)
      when is_map(expected_payload) and is_binary(fence_token) and fence_token != "" and
             is_integer(cutoff_seq) and cutoff_seq >= 0,
      do:
        call(
          pid,
          {:fence_incarnation, expected_payload, fence_token, cutoff_seq, updated_at}
        )

  def activate(pid, attrs) when is_map(attrs),
    do: call(pid, {:activate, attrs})

  def delete(pid) do
    call(pid, :delete)
  catch
    :exit, {:normal, _call} -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  def import_legacy_delivery(pid, conversation, facts)
      when is_map(conversation) and is_map(facts),
      do: call(pid, {:import_legacy_delivery, conversation, facts})

  def migrate_legacy_delivery_participant_fields(pid, delivery_id),
    do: call(pid, {:migrate_legacy_delivery_participant_fields, delivery_id})

  def migrate_notification_filter(pid), do: call(pid, :migrate_notification_filter)

  def accept_slack_task_card_event(pid, event) when is_map(event) do
    call(pid, {:accept_slack_task_card_event, event})
  catch
    :exit, reason -> {:error, {:task_card_event_owner_exit, reason}}
  end

  def provider_receipt(pid, message_id), do: call(pid, {:provider_receipt, message_id})

  def provider_target(pid), do: call(pid, :provider_target)

  def get_realtime_status(pid), do: call(pid, :get_realtime_status)

  def worker_memory_target(pid), do: call(pid, :worker_memory_target)

  def subscribe_realtime_status(pid, subscriber) when is_pid(subscriber),
    do: call(pid, {:subscribe_realtime_status, subscriber})

  defp call(pid, request), do: GenServer.call(pid, request, @call_timeout)

  def wake(group_id, conversation_id, participant_id) do
    case Registry.lookup(
           SalixIM.ConversationRegistry,
           key(group_id, conversation_id, participant_id)
         ) do
      [{pid, _}] -> GenServer.cast(pid, :drain)
      [] -> :ok
    end

    :ok
  end

  defp via(group_id, conversation_id, participant_id),
    do:
      {:via, Registry,
       {SalixIM.ConversationRegistry, key(group_id, conversation_id, participant_id)}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    group_id = Keyword.fetch!(opts, :group_id)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    participant_id = Keyword.fetch!(opts, :participant_id)

    {:ok, store_pid} =
      ConversationParticipantStore.start_link(
        owner: self(),
        group_id: group_id,
        conversation_id: conversation_id,
        participant_id: participant_id
      )

    state = %__MODULE__{
      group_id: group_id,
      conversation_id: conversation_id,
      participant_id: participant_id,
      store_pid: store_pid
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    case load_participant(state.store_pid) do
      {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) ->
        send(self(), :cleanup_deleted_participant)
        {:noreply, %{state | deleted?: true, participant_load_error: nil}}

      {:ok, participant} ->
        state = %{state | participant: participant, participant_load_error: nil}

        if legacy_triage_slack_thread_participant?(participant) do
          GenServer.cast(self(), :drain)
        end

        {:noreply, reconcile_realtime_state(state)}

      {:error, reason} ->
        {:noreply, %{state | participant: nil, participant_load_error: reason}}
    end
  end

  @impl true
  def handle_call(:delete, _from, %{deleted?: true} = state) do
    send(self(), :cleanup_deleted_participant)
    {:reply, :ok, state}
  end

  def handle_call(_request, _from, %{deleted?: true} = state),
    do: {:reply, {:error, :not_found}, state}

  # ParticipantDelivery.ColdDeleteSpec models the tombstone and best-effort
  # cleanup operations when this actor starts cold. Its no-new-provider-IO
  # guarantee and safety config do not cover this active-worker branch.
  def handle_call(:delete, _from, state) do
    if is_pid(state.drain_pid), do: Process.exit(state.drain_pid, :kill)

    case ConversationParticipantStore.tombstone(state.store_pid) do
      :ok ->
        send(self(), :cleanup_deleted_participant)

        state = retire_realtime_state(state)

        {:reply, :ok,
         %{
           state
           | participant: nil,
             drain_pid: nil,
             active_delivery: nil,
             drain_requested?: false,
             deleted?: true
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_new, participant}, _from, state) do
    participant =
      participant
      |> Map.put("participant_id", state.participant_id)
      |> Map.put("conversation_id", state.conversation_id)
      |> Map.put_new("source_start_seq", participant["delivery_cursor_seq"] || 0)

    reply =
      if state.participant_load_error in [nil, :not_found] do
        ConversationParticipantStore.put_new(state.store_pid, participant)
      else
        {:error, {:participant_state_unavailable, state.participant_load_error}}
      end

    {reply, next_state} = participant_result(reply, state)
    {:reply, reply, next_state}
  end

  def handle_call({:ensure_reserved, participant}, _from, state) do
    participant =
      Map.put_new(participant, "source_start_seq", participant["delivery_cursor_seq"] || 0)

    participant =
      participant
      |> Map.put("participant_id", state.participant_id)
      |> Map.put("conversation_id", state.conversation_id)

    {reply, next_state} = ensure_reserved_participant(state, participant)
    {:reply, reply, next_state}
  end

  def handle_call({:ensure_reserved_incarnation, participant, contract}, _from, state) do
    participant =
      Map.put_new(participant, "source_start_seq", participant["delivery_cursor_seq"] || 0)

    participant =
      participant
      |> Map.put("participant_id", state.participant_id)
      |> Map.put("conversation_id", state.conversation_id)

    {reply, next_state} = do_ensure_reserved_incarnation(state, participant, contract)
    {:reply, reply, next_state}
  end

  def handle_call({:deactivate, updated_at}, _from, state) do
    reply =
      ConversationParticipantStore.update(
        state.store_pid,
        fn participant ->
          participant
          |> Map.put("state", "inactive")
          |> Map.put("notification_filter", %{
            "messages" => "none",
            "statuses" => "none"
          })
          |> Map.put("updated_at", updated_at)
        end
      )

    {reply, next_state} = participant_result(reply, state)
    request_deactivation_drain(reply)
    {:reply, reply, next_state}
  end

  def handle_call({:deactivate_if_payload, expected_payload, updated_at}, _from, state) do
    reply =
      ConversationParticipantStore.update(state.store_pid, fn participant ->
        if payload_matches?(participant["payload"], expected_payload) do
          deactivate_participant(participant, updated_at)
        else
          {:error, :participant_payload_mismatch}
        end
      end)

    {reply, next_state} = participant_result(reply, state)
    request_deactivation_drain(reply)
    {:reply, reply, next_state}
  end

  def handle_call(
        {:fence_incarnation, expected_payload, fence_token, cutoff_seq, updated_at},
        _from,
        state
      ) do
    reply =
      ConversationParticipantStore.update(state.store_pid, fn participant ->
        fence_participant_incarnation(
          participant,
          expected_payload,
          fence_token,
          cutoff_seq,
          updated_at
        )
      end)

    case reply do
      {:ok, participant} ->
        state = update_realtime_participant(state, participant)

        case participant_delivery_barrier_status(state) do
          {:ok, barrier_status, state} ->
            result = %{
              "barrier_status" => barrier_status,
              "delivery_fence" => fence_token,
              "cutoff_seq" => get_in(participant, ["task_thread_delivery_fence", "cutoff_seq"]),
              "participant" => participant
            }

            {:reply, {:ok, result}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:activate, attrs}, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        participant = state.participant
        desired = activate_participant(participant, attrs)

        cond do
          is_map(participant["task_thread_delivery_fence"]) ->
            {{:error, :participant_binding_generation_mismatch}, state}

          not Map.has_key?(attrs, "updated_at") and
              Map.delete(desired, "updated_at") == Map.delete(participant, "updated_at") ->
            {{:ok, participant}, state}

          true ->
            reply =
              ConversationParticipantStore.update(state.store_pid, fn current ->
                if is_map(current["task_thread_delivery_fence"]),
                  do: {:error, :participant_binding_generation_mismatch},
                  else: activate_participant(current, attrs)
              end)

            participant_result(reply, state)
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:provider_receipt, message_id}, _from, state) do
    id = Enum.join([state.group_id, state.conversation_id, message_id, state.participant_id], ":")
    {:reply, ConversationParticipantStore.read_delivery(state.store_pid, id), state}
  end

  def handle_call(:provider_target, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        case state.participant do
          %{"actor_type" => "provider", "state" => "active"} = participant ->
            {{:ok, participant}, state}

          _ ->
            {{:error, {:bad_request, "provider participant is inactive or missing"}}, state}
        end
      end)

    {:reply, reply, state}
  end

  def handle_call(:get_realtime_status, _from, state) do
    {reply, state} = current_realtime_status(state)
    {:reply, reply, state}
  end

  def handle_call(:worker_memory_target, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        participant = state.participant
        agent_id = participant["agent_id"]
        session_id = get_in(participant, ["payload", "session_id"])

        cond do
          participant["actor_type"] != "agent" ->
            {{:error, :not_worker_participant}, state}

          participant["state"] == "inactive" ->
            {{:error, :not_found}, state}

          not (is_binary(agent_id) and agent_id != "") ->
            {{:error, :not_found}, state}

          not (is_binary(session_id) and session_id != "") ->
            {{:error, :not_found}, state}

          true ->
            {{:ok,
              %{
                "participant_id" => participant["participant_id"],
                "agent_id" => agent_id,
                "session_id" => session_id,
                "worker_role" => participant["role_label"] || "worker"
              }}, state}
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:subscribe_realtime_status, subscriber}, _from, state) do
    state = put_realtime_subscriber(state, subscriber)
    {reply, state} = current_realtime_status(state)

    reply =
      case reply do
        {:ok, status} -> {:ok, %{"owner_pid" => self(), "status" => status}}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:accept_slack_task_card_event, event}, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        do_accept_slack_task_card_event(state, event)
      end)

    {:reply, reply, state}
  end

  def handle_call({:advance_delivery_cursor, seq}, _from, state) do
    reply =
      ConversationParticipantStore.update(
        state.store_pid,
        fn participant ->
          participant
          |> Map.put("delivery_cursor_seq", max(participant_cursor_seq(participant), seq))
          |> Map.put("updated_at", System.system_time(:millisecond))
        end
      )

    state =
      case reply do
        {:ok, participant} -> %{state | participant: participant}
        {:error, _reason} -> state
      end

    {:reply, reply, state}
  end

  def handle_call({:import_legacy_delivery, conversation, facts}, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        reply =
          with {:ok, delivery} <-
                 canonical_legacy_delivery(conversation, state.participant, facts) do
            ConversationParticipantStore.put_delivery(state.store_pid, delivery)
          end

        {reply, state}
      end)

    {:reply, reply, state}
  end

  def handle_call({:migrate_legacy_delivery_participant_fields, delivery_id}, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        reply =
          with {:ok, rec, etag} <-
                 ConversationParticipantStore.read_delivery(state.store_pid, delivery_id) do
            case canonicalize_legacy_delivery_participant(rec, state.participant) do
              :skip ->
                :skipped

              replacement ->
                case ConversationParticipantStore.put_delivery_state(
                       state.store_pid,
                       delivery_id,
                       replacement,
                       etag
                     ) do
                  {:ok, _result} -> :migrated
                  {:error, :precondition_failed} -> :skipped
                  {:error, reason} -> {:error, reason}
                end
            end
          end

        {reply, state}
      end)

    {:reply, reply, state}
  end

  def handle_call(:migrate_notification_filter, _from, state) do
    {reply, state} =
      with_loaded_participant(state, fn state ->
        canonical = canonical_notification_filter(state.participant)

        if canonical == state.participant do
          {:skipped, state}
        else
          case ConversationParticipantStore.update(state.store_pid, fn _current -> canonical end) do
            {:ok, participant} ->
              {:migrated, %{state | participant: participant, participant_load_error: nil}}

            {:error, reason} ->
              {{:error, reason}, state}
          end
        end
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(_message, %{deleted?: true} = state), do: {:noreply, state}

  def handle_cast(:drain, %{drain_pid: nil} = initial_state) do
    state = initial_state

    with {:ok, state} <- ensure_participant_loaded(state),
         {:ok, conversation} <- ConversationParticipantStore.load_conversation(state.store_pid),
         {:ok, false} <-
           notify_agent_source(conversation, state.participant) do
      {:noreply, start_next_delivery(state)}
    else
      {:ok, true} ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state |> refresh_participant() |> retry_drain_later()}

      {:error, _reason, state} ->
        {:noreply, retry_drain_later(state)}
    end
  end

  def handle_cast(:drain, state),
    do: {:noreply, %{state | drain_requested?: true}}

  defp notify_agent_source(conversation, %{"actor_type" => "agent"} = participant) do
    if participant["state"] != "inactive" do
      SalixIM.ConversationSource.notify(participant["agent_id"], %{
        group_id: conversation["agent_group_id"],
        conversation_id: conversation["conversation_id"],
        participant_id: participant["participant_id"]
      })
    end

    {:ok, true}
  end

  defp notify_agent_source(_, _), do: {:ok, false}

  @impl true
  def handle_info(:cleanup_deleted_participant, %{deleted?: true} = state) do
    case ConversationParticipantStore.cleanup(state.store_pid, @delete_batch_size) do
      :done ->
        {:stop, :normal, state}

      _more_or_error ->
        Process.send_after(self(), :cleanup_deleted_participant, @delete_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, store_pid, reason}, %{store_pid: store_pid} = state),
    do: {:stop, {:participant_store_exit, reason}, %{state | store_pid: nil}}

  def handle_info(_message, %{deleted?: true} = state), do: {:noreply, state}

  def handle_info({:session_activity_updated, agent_id, session_id}, state) do
    if state.session_ref == {agent_id, session_id} and is_nil(state.realtime_refresh) do
      # Invalidation hints carry no state. One mailbox marker reads the latest
      # snapshot after the queued burst, without a read for every notification.
      token = make_ref()
      send(self(), {:refresh_realtime_status, token})
      {:noreply, %{state | realtime_refresh: token}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:refresh_realtime_status, token}, %{realtime_refresh: token} = state) do
    # Notifications received during this read remain queued and schedule one
    # follow-up refresh. Never discard them after reading an older snapshot.
    {state, changed?} = refresh_realtime_status(%{state | realtime_refresh: nil})
    if changed?, do: notify_realtime_subscribers(state)
    {:noreply, state}
  end

  def handle_info({:refresh_realtime_status, _stale_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, subscriber, _reason}, state) do
    case state.realtime_subscribers[subscriber] do
      ^ref ->
        state = %{
          state
          | realtime_subscribers: Map.delete(state.realtime_subscribers, subscriber)
        }

        state =
          if map_size(state.realtime_subscribers) == 0,
            do: retire_realtime_subscription(state),
            else: state

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:participant_delivery_complete, worker, result},
        %{drain_pid: worker, active_delivery: active_delivery} = state
      ) do
    {result, state} = prepare_delivery_completion(state, active_delivery, result)
    settle_delivery_result(active_delivery, result)

    state = %{state | drain_pid: nil, active_delivery: nil}
    {:noreply, continue_or_finish_drain(state)}
  end

  def handle_info(
        {:EXIT, pid, reason},
        %{drain_pid: pid, active_delivery: active_delivery} = state
      )
      when reason != :normal do
    result = delivery_worker_exit_result(active_delivery, reason)

    settle_delivery_result(
      active_delivery,
      result
    )

    state = %{state | drain_pid: nil, active_delivery: nil}
    {:noreply, continue_or_finish_drain(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:retry_drain, state) do
    GenServer.cast(self(), :drain)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.drain_pid), do: Process.exit(state.drain_pid, :kill)
    unsubscribe_session(state.session_ref)
  end

  defp start_next_delivery(state) do
    if is_map(state.participant) do
      case next_delivery(state) do
        {:ok, nil, state} ->
          finish_idle_drain(state)

        {:ok, active_delivery, state} ->
          case prepare_active_delivery(state, active_delivery) do
            {:ok, state, active_delivery} ->
              owner = self()

              pid =
                spawn_link(fn ->
                  result =
                    measured_delivery_io(active_delivery)
                    |> append_provider_notice(active_delivery.record)

                  send(owner, {:participant_delivery_complete, self(), result})
                end)

              %{
                state
                | drain_pid: pid,
                  active_delivery: active_delivery,
                  drain_requested?: false
              }

            {:skip, state} ->
              start_next_delivery(state)

            {:error, state} ->
              retry_drain_later(state)
          end

        {:blocked, delay_ms, state} ->
          retry_drain_later(state, delay_ms)

        {:error, _reason, state} ->
          retry_drain_later(state)
      end
    else
      retry_drain_later(state)
    end
  end

  defp continue_or_finish_drain(state) do
    if state.drain_requested? do
      GenServer.cast(self(), :drain)
      %{state | drain_requested?: false}
    else
      start_next_delivery(state)
    end
  end

  defp finish_idle_drain(state), do: %{state | drain_requested?: false}

  defp retry_drain_later(state), do: retry_drain_later(state, 1_000)

  defp retry_drain_later(state, delay_ms) do
    Process.send_after(self(), :retry_drain, max(delay_ms, 10))
    %{state | drain_pid: nil, active_delivery: nil}
  end

  defp next_delivery(state) do
    state = refresh_participant(state)

    with {:ok, conversation} <- ConversationParticipantStore.load_conversation(state.store_pid),
         {:ok, state} <- initialize_provider_cursor(state, conversation),
         {:ok, messages} <-
           Conversations.list_group_conversation_messages(
             state.group_id,
             state.conversation_id,
             after_seq: state.participant["delivery_log_cursor_seq"],
             limit: 32
           ) do
      first = List.first(messages)

      age =
        if first,
          do: max(System.system_time(:millisecond) - (first["created_at"] || 0), 0),
          else: 0

      Salix.Telemetry.emit_conversation_log_sample(
        max(
          conversation_tail_seq(conversation) - state.participant["delivery_log_cursor_seq"],
          0
        ),
        age
      )

      case next_provider_record(state, conversation, messages) do
        {:ok, nil} ->
          case List.last(messages) do
            nil -> {:ok, nil, state}
            message -> advance_provider_cursor(state, message["seq"])
          end

        {:ok, {message, record, revision}} ->
          if record["status"] in ~w(delivered failed cancelled unknown) do
            advance_provider_cursor(state, message["seq"])
          else
            case select_delivery(
                   [{record["delivery_id"], record, revision}],
                   System.system_time(:millisecond),
                   state.store_pid,
                   state.participant
                 ) do
              {:ok, nil} -> {:blocked, 10, state}
              {:ok, delivery} -> {:ok, delivery, state}
              {:blocked, delay} -> {:blocked, delay, state}
              {:error, reason} -> {:error, reason, state}
            end
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp next_provider_record(state, conversation, messages) do
    Enum.reduce_while(messages, {:ok, nil}, fn message, _ ->
      id = provider_receipt_id(conversation, message, state.participant)

      case ConversationParticipantStore.read_delivery(state.store_pid, id) do
        {:ok, record, revision} ->
          # A changed subscription or fence cannot hide an unresolved platform call.
          record = retry_source_record(record, message)
          {:halt, {:ok, {message, record, revision}}}

        {:error, :not_found} ->
          if message["delivery_log_skip"] != true and
               message["seq"] > (state.participant["source_start_seq"] || 0) and
               targets_participant?(state.participant, message) do
            case provider_source_record(conversation, message, state.participant) do
              {:ok, record} -> {:halt, {:ok, {message, Map.put(record, "delivery_id", id), nil}}}
              error -> {:halt, error}
            end
          else
            {:cont, {:ok, nil}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp retry_source_record(record, message) do
    if record["status"] == "failed" and
         get_in(message, ["provider_effect", "retry_of"]) == record["message_id"] and
         message["seq"] > record["message_seq"] do
      record
      |> Map.drop(
        ~w(delivery_result delivered_at delivery_started_at retry_after_at last_error provider_outcome_ambiguous_at)
      )
      |> Map.merge(%{
        "status" => "pending",
        "attempts" => 0,
        "verification_attempts" => 0,
        "message_seq" => message["seq"],
        "updated_at" => now()
      })
    else
      record
    end
  end

  defp provider_receipt_id(conversation, message, participant) do
    message_id = get_in(message, ["provider_effect", "retry_of"]) || message["message_id"]

    Enum.join(
      [
        conversation["agent_group_id"],
        conversation["conversation_id"],
        message_id,
        participant["participant_id"]
      ],
      ":"
    )
  end

  defp initialize_provider_cursor(state, conversation) do
    if is_integer(state.participant["delivery_log_cursor_seq"]) do
      {:ok, state}
    else
      # The owner permits discarding old unprocessed inputs and provider output.
      # New appends stamp the Conversation floor before publishing their hint.
      floor =
        max(
          conversation["log_start_seq"] || conversation_tail_seq(conversation),
          state.participant["source_start_seq"] || 0
        )

      case ConversationParticipantStore.update(state.store_pid, fn participant ->
             Map.put_new(participant, "delivery_log_cursor_seq", floor)
           end) do
        {:ok, participant} -> {:ok, %{state | participant: participant}}
        error -> error
      end
    end
  end

  defp advance_provider_cursor(state, seq) do
    case ConversationParticipantStore.update(state.store_pid, fn participant ->
           Map.put(
             participant,
             "delivery_log_cursor_seq",
             max(participant["delivery_log_cursor_seq"] || 0, seq)
           )
         end) do
      {:ok, participant} -> {:blocked, 10, %{state | participant: participant}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp provider_source_record(conversation, %{"provider_effect" => effect} = message, participant) do
    attrs = effect["attrs"]

    with {:ok, notification} <-
           ConversationMessage.participant_notification(
             message["message_id"],
             attrs,
             attrs["metadata"] || %{},
             message["created_at"]
           ) do
      {:ok,
       provider_delivery_record(
         conversation,
         Map.put(notification, "seq", message["seq"]),
         participant,
         delivery_kind: effect["kind"]
       )}
    end
  end

  defp provider_source_record(
         _conversation,
         %{"provider_status" => snapshot} = message,
         participant
       ) do
    with {:ok, record} <- status_delivery_record(snapshot, participant) do
      {:ok,
       Map.merge(record, %{"message_id" => message["message_id"], "message_seq" => message["seq"]})}
    end
  end

  defp provider_source_record(conversation, message, participant),
    do: {:ok, provider_delivery_record(conversation, message, participant)}

  defp select_delivery([], _now_ms, _store_pid, _participant), do: {:ok, nil}

  defp select_delivery(
         [{delivery_id, rec, revision} | rest],
         now_ms,
         store_pid,
         participant
       ) do
    case delivery_action(rec, now_ms, participant) do
      {:wait, delay_ms} ->
        {:blocked, delay_ms}

      {:settle, status, result, reason} ->
        _ =
          put_delivery_state(
            store_pid,
            delivery_id,
            terminal_record(rec, status, result, reason),
            revision
          )

        select_delivery(rest, now_ms, store_pid, participant)

      :verify ->
        {:ok,
         %{
           store_pid: store_pid,
           delivery_id: delivery_id,
           record: rec,
           revision: revision,
           mode: :verify_stale_provider
         }}

      :verify_fenced ->
        {:ok,
         %{
           store_pid: store_pid,
           delivery_id: delivery_id,
           record: rec,
           revision: revision,
           mode: :verify_fenced_provider
         }}

      :claim ->
        case claim_delivery(store_pid, delivery_id, rec, revision) do
          {:ok, claimed, claim_revision} ->
            {:ok,
             %{
               store_pid: store_pid,
               delivery_id: delivery_id,
               record: claimed,
               revision: claim_revision,
               mode: :deliver
             }}

          {:skip, _reason} ->
            select_delivery(rest, now_ms, store_pid, participant)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp delivery_action(%{"status" => status} = rec, now, participant) do
    before_start? =
      is_integer(rec["message_seq"]) and
        rec["message_seq"] <= (participant["source_start_seq"] || 0)

    if before_start? or
         (task_thread_delivery?(rec, participant) and
            not task_thread_delivery_allowed?(rec, participant)) do
      cond do
        status == "delivering" and delivery_ready_at(rec) > now ->
          {:wait, delivery_ready_at(rec) - now}

        status == "delivering" ->
          :verify_fenced

        true ->
          {:settle, "cancelled", %{"status" => "participant_incarnation_fenced"},
           :participant_incarnation_fenced}
      end
    else
      if participant_inactive?(participant) do
        inactive_delivery_action(rec, status, now)
      else
        ordinary_delivery_action(rec, status, now)
      end
    end
  end

  defp inactive_delivery_action(rec, status, now) do
    cond do
      status == "delivering" and delivery_ready_at(rec) > now ->
        {:wait, delivery_ready_at(rec) - now}

      status == "delivering" ->
        :verify

      status in ["pending", "retry_waiting"] ->
        {:settle, "cancelled", %{"status" => "participant_inactive"}, :participant_inactive}

      true ->
        {:wait, 1_000}
    end
  end

  defp ordinary_delivery_action(rec, status, now) do
    cond do
      trim(rec["operation_ref"]) == "" ->
        {:settle, "unknown", %{"status" => "delivery_missing_operation_ref"},
         :missing_operation_ref}

      status == "pending" ->
        :claim

      status == "delivering" and delivery_ready_at(rec) > now ->
        {:wait, delivery_ready_at(rec) - now}

      status == "delivering" ->
        :verify

      status == "retry_waiting" and attempts(rec) >= @max_delivery_attempts ->
        {:settle, "failed", nil, rec["last_error"] || :retry_exhausted}

      status == "retry_waiting" and sortable_number(rec["retry_after_at"], 0) > now ->
        {:wait, sortable_number(rec["retry_after_at"], 0) - now}

      status == "retry_waiting" ->
        :claim

      true ->
        {:wait, 1_000}
    end
  end

  defp prepare_active_delivery(state, active_delivery) do
    state =
      if task_thread_delivery_record?(active_delivery.record) or
           task_thread_participant?(state.participant),
         do: refresh_participant(state),
         else: state

    cond do
      not is_map(state.participant) ->
        {:error, state}

      active_delivery.mode == :deliver and
        task_thread_delivery?(active_delivery.record, state.participant) and
          not task_thread_delivery_allowed?(active_delivery.record, state.participant) ->
        cancelled =
          terminal_record(
            active_delivery.record,
            "cancelled",
            %{"status" => "participant_incarnation_fenced"},
            :participant_incarnation_fenced
          )

        _ =
          put_delivery_state(
            active_delivery.store_pid,
            active_delivery.delivery_id,
            cancelled,
            active_delivery.revision
          )

        {:skip, state}

      active_delivery.mode == :verify_stale_provider and
        task_thread_delivery?(active_delivery.record, state.participant) and
          not task_thread_delivery_allowed?(active_delivery.record, state.participant) ->
        {:ok, state, %{active_delivery | mode: :verify_fenced_provider}}

      true ->
        {:ok, state, refresh_delivery_payload(active_delivery, state.participant)}
    end
  end

  defp claim_delivery(store_pid, delivery_id, rec, revision) do
    now = System.system_time(:millisecond)

    claimed =
      rec
      |> Map.delete("delivery_status")
      |> Map.merge(%{"status" => "delivering", "delivery_started_at" => now, "updated_at" => now})

    case ConversationParticipantStore.put_delivery_state(
           store_pid,
           delivery_id,
           claimed,
           revision
         ) do
      {:ok, %{etag: claim_revision}} ->
        {:ok, claimed, claim_revision}

      {:error, :precondition_failed} ->
        {:skip, :claimed_by_other}

      {:error, {:ambiguous, _reason}} ->
        case ConversationParticipantStore.read_delivery(store_pid, delivery_id) do
          {:ok, %{"status" => "delivering"} = current, current_revision} ->
            {:ok, current, current_revision}

          {:ok, _current, _current_revision} ->
            {:skip, :claim_not_landed}

          {:error, reason} ->
            {:error, {:claim_ambiguous_unverified, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp measured_delivery_io(delivery) do
    started = System.monotonic_time()
    result = perform_delivery_io(delivery)

    Salix.Telemetry.emit_operation(
      "salix_im",
      "provider_log_delivery",
      "system",
      if(match?({:ok, _}, result), do: "ok", else: "error"),
      System.monotonic_time() - started
    )

    result
  end

  defp perform_delivery_io(%{mode: :deliver, record: rec, revision: revision}),
    do: ConversationDelivery.deliver(Map.put(rec, "delivery_claim_revision", revision))

  defp perform_delivery_io(%{mode: :verify_stale_provider, record: rec}) do
    case ConversationDelivery.verify(rec) do
      {:ok, status} ->
        {:ok, status}

      {:missing, reason} ->
        if provider_verification_pending?(rec) or SalixIM.Triage.Investigation.delivery?(rec) do
          {:resend, reason}
        else
          {:unknown, %{"status" => "stale_provider_delivery_unverified"},
           :stale_provider_delivery_unverified}
        end

      {:unknown, reason} ->
        cond do
          SalixIM.Triage.Investigation.delivery?(rec) ->
            # Retry through the existing bounded claim path. Its adapter first
            # recovers the provider receipt and completes only the local handoff.
            {:resend, reason}

          provider_verification_pending?(rec) ->
            case reason do
              {:retry_after, delay_ms, detail} when is_integer(delay_ms) and delay_ms > 0 ->
                {:verify_later, detail, delay_ms}

              _ ->
                {:verify_later, reason}
            end

          true ->
            {:unknown, %{"status" => "stale_provider_delivery_unverified"}, reason}
        end
    end
  end

  defp perform_delivery_io(%{mode: :verify_fenced_provider, record: rec}) do
    case ConversationDelivery.verify(rec) do
      {:ok, status} ->
        {:ok, status}

      {:missing, reason} ->
        {:cancelled, {:fenced_provider_delivery_missing, reason}}

      {:unknown, {:retry_after, delay_ms, detail}}
      when is_integer(delay_ms) and delay_ms > 0 ->
        {:verify_later, detail, delay_ms}

      {:unknown, reason} ->
        {:verify_later, reason}
    end
  end

  defp append_provider_notice({:error, reason, retryable?, {:provider_notice, attrs}}, record) do
    result =
      SalixIM.ConversationServer.send_provider_participant_message(
        record["agent_group_id"],
        record["conversation_id"],
        record["participant_id"],
        attrs
      )

    {:error, {reason, result}, retryable?}
  end

  defp append_provider_notice(result, _record), do: result

  defp delivery_worker_exit_result(%{record: rec}, reason) do
    cond do
      rec["participant_provider"] == "slack" ->
        {:unknown, %{"status" => "provider_outcome_ambiguous"}, {:delivery_worker_exit, reason}}

      true ->
        {:unknown, %{"status" => "delivery_worker_exit"}, reason}
    end
  end

  defp refresh_delivery_payload(%{record: rec} = delivery, participant)
       when is_map(participant) do
    if task_thread_delivery?(rec, participant) do
      delivery
    else
      %{delivery | record: Map.put(rec, "participant_payload", participant["payload"] || %{})}
    end
  end

  defp refresh_delivery_payload(delivery, _participant), do: delivery

  defp prepare_delivery_completion(state, active_delivery, result) do
    if task_thread_delivery?(active_delivery.record, state.participant) do
      state = refresh_participant(state)

      if is_map(state.participant) and
           task_thread_delivery_allowed?(active_delivery.record, state.participant) do
        persist_participant_receipt(state, result)
      else
        {result, state}
      end
    else
      persist_participant_receipt(state, result)
    end
  end

  defp persist_participant_receipt(state, {:ok, %{"participant_receipt" => receipt} = result})
       when is_map(receipt) do
    allowed = Map.take(receipt, ~w(payload notification_filter state))

    case ConversationParticipantStore.update(state.store_pid, fn participant ->
           participant
           |> SlackTaskCard.merge_participant_receipt(allowed)
           |> Map.put("updated_at", System.system_time(:millisecond))
         end) do
      {:ok, participant} ->
        emit_receipt_telemetry(receipt)
        {{:ok, Map.delete(result, "participant_receipt")}, %{state | participant: participant}}

      {:error, reason} ->
        {{:verify_later, {:participant_receipt_persist_failed, reason}},
         refresh_participant(state)}
    end
  end

  defp persist_participant_receipt(state, result), do: {result, state}

  defp do_accept_slack_task_card_event(state, event) do
    participant = state.participant
    payload = participant["payload"] || %{}

    with true <- SlackTaskCard.delivery?(%{"participant_payload" => payload}),
         true <- payload["connect_id"] == event["connect_id"],
         true <- payload["channel_id"] == event["channel_id"] do
      cond do
        SlackTaskCard.current_deletion?(payload, event) ->
          queue_slack_task_card_repair(state, event)

        event["kind"] == "message_metadata_deleted" ->
          case accept_slack_task_card_receipt(state, payload, event) do
            {:ok, state} -> queue_slack_task_card_repair(state, event)
            other -> other
          end

        true ->
          accept_slack_task_card_receipt(state, payload, event)
      end
    else
      false -> {{:error, :invalid_task_card_metadata_route}, state}
    end
  end

  defp accept_slack_task_card_receipt(state, payload, event) do
    case ConversationParticipantStore.read_delivery(state.store_pid, event["delivery_id"]) do
      {:ok, %{"status" => "delivered"}, _revision} ->
        {:ignored, state}

      {:ok, rec, revision} ->
        if rec["operation_ref"] == event["operation_ref"] do
          case SlackTaskCard.accept_event(payload, rec, event) do
            :ignore ->
              {:ignored, state}

            result ->
              {result, state} = persist_participant_receipt(state, result)

              reply =
                case result do
                  {:ok, status} ->
                    put_delivery_state(
                      state.store_pid,
                      event["delivery_id"],
                      delivered_record(rec, status),
                      revision
                    )

                  _ ->
                    {:error, :task_card_metadata_receipt_not_persisted}
                end

              {reply, state}
          end
        else
          {:ignored, state}
        end

      {:error, :not_found} ->
        {:ignored, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp queue_slack_task_card_repair(state, event) do
    {{:provider_effect,
      %{
        "idempotency_key" => "slack-task-card-repair:" <> event["event_id"],
        "content" => get_in(state.participant, ["payload", "task_id"]),
        "metadata" => %{"slack_task_card_repair" => event["message_ts"]}
      }, [delivery_kind: "slack_task_card_repair"]}, state}
  end

  defp emit_receipt_telemetry(%{"telemetry_operation" => "slack_task_card"}) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: 0},
      %{
        component: "salix_im",
        operation: "slack_task_card",
        surface: "system",
        outcome: "conflict"
      }
    )
  end

  defp emit_receipt_telemetry(_receipt), do: :ok

  defp settle_delivery_result(
         %{
           store_pid: store_pid,
           delivery_id: delivery_id,
           record: rec,
           revision: revision
         },
         {:ok, status}
       ) do
    case put_delivery_state(store_pid, delivery_id, delivered_record(rec, status), revision) do
      :ok -> :ok
      {:skip, reason} -> settle_unknown_after_success(store_pid, delivery_id, status, reason)
      {:error, reason} -> settle_unknown_after_success(store_pid, delivery_id, status, reason)
    end
  end

  defp settle_delivery_result(
         %{store_pid: store_pid, delivery_id: id, record: rec, revision: revision},
         result
       ) do
    case result_record(rec, result) do
      :ignore -> :ok
      updated -> put_delivery_state(store_pid, id, updated, revision)
    end
  end

  defp result_record(
         %{"participant_provider" => "slack"} = rec,
         {:unknown, %{"status" => "provider_outcome_ambiguous"} = result, reason}
       ),
       do: verification_record(rec, result, reason, provider_verify_grace_ms())

  defp result_record(rec, {:unknown, result, reason}),
    do: terminal_record(rec, "unknown", result, reason)

  defp result_record(rec, {:verify_later, reason}),
    do: result_record(rec, {:verify_later, reason, provider_verify_grace_ms()})

  defp result_record(rec, {:verify_later, reason, delay_ms}),
    do:
      verification_record(rec, %{"status" => "provider_verification_deferred"}, reason, delay_ms)

  defp result_record(rec, {:cancelled, reason}),
    do:
      terminal_record(
        rec,
        "cancelled",
        %{"status" => "participant_incarnation_fenced"},
        reason
      )

  defp result_record(rec, {:resend, reason}),
    do: retry_record(rec, attempts(rec) + 1, reason, 0)

  defp result_record(rec, {:error, reason, retryable?}) do
    delay = retry_delay(reason)
    next_attempt = attempts(rec) + 1

    if retryable? and next_attempt < @max_delivery_attempts do
      retry_record(
        rec,
        next_attempt,
        reason,
        delay || delivery_retry_backoff_ms() * max(next_attempt, 1)
      )
    else
      rec
      |> Map.put("attempts", next_attempt)
      |> terminal_record("failed", nil, reason)
    end
  end

  defp result_record(_rec, _result), do: :ignore

  defp settle_unknown_after_success(store_pid, delivery_id, status, reason) do
    case ConversationParticipantStore.read_delivery(store_pid, delivery_id) do
      {:ok, %{"status" => "delivered"}, _revision} ->
        :ok

      {:ok, current, current_revision} ->
        put_delivery_state(
          store_pid,
          delivery_id,
          terminal_record(
            current,
            "unknown",
            %{"status" => "delivery_acknowledgement_unknown", "side_effect_result" => status},
            reason
          ),
          current_revision
        )

      {:error, read_reason} ->
        {:error, {:delivery_status_unknown_unrecorded, reason, read_reason}}
    end
  end

  defp put_delivery_state(store_pid, delivery_id, rec, revision) do
    case ConversationParticipantStore.put_delivery_state(
           store_pid,
           delivery_id,
           rec,
           revision
         ) do
      {:ok, _result} ->
        emit_task_card_settlement_telemetry(rec)
        :ok

      {:error, :precondition_failed} ->
        {:skip, :ownership_lost}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  @task_card_settlement_outcomes %{
    "delivered" => "ok",
    "failed" => "failed",
    "unknown" => "in_doubt",
    "cancelled" => "cancelled"
  }

  # One counter per persisted terminal Task-card delivery state. This seam
  # sees every settlement path — success, retry exhaustion, receipt admission,
  # incarnation fencing, and unknown-outcome terminalization — so a missing
  # card is visible in telemetry instead of only in the delivery record.
  defp emit_task_card_settlement_telemetry(rec) do
    outcome = @task_card_settlement_outcomes[rec["status"]]

    if is_binary(outcome) and SlackTaskCard.delivery?(rec) do
      :telemetry.execute(
        [:salix, :operation, :stop],
        %{duration: 0},
        %{
          component: "salix_im",
          operation: "slack_task_card",
          surface: "system",
          outcome: outcome
        }
      )
    end

    :ok
  end

  defp delivered_record(rec, status) do
    {delivery_status, result} =
      cond do
        is_atom(status) -> {Atom.to_string(status), nil}
        is_binary(status) -> {status, nil}
        true -> {"delivered", status}
      end

    now = System.system_time(:millisecond)

    rec
    |> Map.drop(~w(delivery_started_at retry_after_at provider_outcome_ambiguous_at last_error))
    |> Map.merge(%{
      "status" => "delivered",
      "delivery_status" => delivery_status,
      "delivered_at" => now,
      "updated_at" => now
    })
    |> put_delivery_result(result)
  end

  defp terminal_record(rec, status, result, reason) do
    rec
    |> Map.drop(~w(delivery_started_at retry_after_at))
    |> Map.merge(%{
      "status" => status,
      "last_error" => inspect(reason),
      "updated_at" => System.system_time(:millisecond)
    })
    |> put_delivery_result(result)
  end

  defp verification_record(rec, result, reason, delay_ms) do
    now = System.system_time(:millisecond)
    delay_ms = max(delay_ms, 10)

    attempts = (rec["verification_attempts"] || 0) + 1
    rec = Map.put(rec, "verification_attempts", attempts)

    if attempts >= @max_delivery_attempts do
      terminal_record(rec, "unknown", result, {:provider_verification_exhausted, reason})
    else
      rec
      |> Map.merge(%{
        "status" => "delivering",
        "retry_after_at" => now + delay_ms,
        "last_error" => inspect(reason),
        "updated_at" => now
      })
      |> Map.put_new("provider_outcome_ambiguous_at", now)
      |> put_delivery_result(result)
    end
  end

  defp retry_record(rec, next_attempt, reason, delay_ms) do
    now = System.system_time(:millisecond)

    if next_attempt < @max_delivery_attempts do
      rec
      |> Map.drop(~w(delivery_result delivery_started_at))
      |> Map.merge(%{
        "status" => "retry_waiting",
        "attempts" => next_attempt,
        "last_error" => inspect(reason),
        "retry_after_at" => now + max(delay_ms, 0),
        "updated_at" => now
      })
    else
      rec
      |> Map.put("attempts", next_attempt)
      |> terminal_record("failed", nil, reason)
    end
  end

  defp delivery_ready_at(rec),
    do:
      sortable_number(
        rec["retry_after_at"],
        sortable_number(rec["delivery_started_at"], 0) + delivery_lease_ms()
      )

  defp sortable_number(value, fallback),
    do: integer(value, fallback)

  defp attempts(rec), do: max(integer(rec["attempts"], 0), 0)
  defp provider_verification_pending?(rec), do: is_integer(rec["provider_outcome_ambiguous_at"])

  defp retry_delay({:retry_after, delay_ms, _reason}) when is_integer(delay_ms), do: delay_ms
  defp retry_delay(_reason), do: nil

  defp delivery_lease_ms do
    case Application.get_env(:salix_im, :conversation_delivery_lease_ms, @delivery_lease_ms) do
      value when is_integer(value) and value in 10..@delivery_lease_ms -> value
      _ -> @delivery_lease_ms
    end
  end

  defp delivery_retry_backoff_ms do
    case Application.get_env(
           :salix_im,
           :conversation_delivery_retry_backoff_ms,
           @delivery_retry_backoff_ms
         ) do
      value when is_integer(value) and value in 10..@delivery_retry_backoff_ms -> value
      _ -> @delivery_retry_backoff_ms
    end
  end

  defp provider_verify_grace_ms do
    case Application.get_env(:salix_im, :provider_verify_grace_ms, @provider_verify_grace_ms) do
      value when is_integer(value) and value in 10..10_000 -> value
      _ -> @provider_verify_grace_ms
    end
  end

  defp put_delivery_result(rec, nil), do: rec
  defp put_delivery_result(rec, result), do: Map.put(rec, "delivery_result", result)

  defp integer(value, fallback) do
    case Integer.parse(to_string(value || "")) do
      {number, ""} -> number
      _ -> fallback
    end
  end

  defp ensure_reserved_participant(state, desired) do
    case ConversationParticipantStore.load_conversation(state.store_pid) do
      {:ok, _conversation} ->
        ensure_reserved_participant_in_active_conversation(state, desired)

      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, reason} ->
        {{:error, {:participant_state_unavailable, reason}}, state}
    end
  end

  defp ensure_reserved_participant_in_active_conversation(state, desired) do
    case ensure_participant_loaded(state) do
      {:ok, state} ->
        existing = state.participant

        cond do
          not same_participant_identity?(existing, desired) ->
            {{:error, :participant_identity_conflict}, state}

          existing["state"] == "inactive" ->
            case ConversationParticipantStore.update(
                   state.store_pid,
                   fn participant ->
                     if is_map(participant["task_thread_delivery_fence"]),
                       do: {:error, :participant_binding_generation_mismatch},
                       else: activate_participant(participant, desired)
                   end
                 ) do
              {:ok, participant} -> participant_result({:ok, :activated, participant}, state)
              {:error, _reason} = error -> {error, state}
            end

          true ->
            {{:ok, :exists, existing}, state}
        end

      {:error, :not_found, state} ->
        state.store_pid
        |> ConversationParticipantStore.put_new(desired)
        |> participant_result(state)

      {:error, reason, state} ->
        {{:error, {:participant_state_unavailable, reason}}, state}
    end
  end

  defp do_ensure_reserved_incarnation(state, desired, contract) do
    case ConversationParticipantStore.load_conversation(state.store_pid) do
      {:ok, _conversation} ->
        run_incarnation_transition(state, desired, contract)

      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, reason} ->
        {{:error, {:participant_state_unavailable, reason}}, state}
    end
  end

  defp run_incarnation_transition(state, desired, contract) do
    with {:ok, field, desired_incarnation, required_payload, allow_create?, allow_reactivation?,
          guard} <-
           validate_incarnation_contract(desired, contract) do
      transition = fn current ->
        transition_participant_incarnation(
          current,
          desired,
          field,
          desired_incarnation,
          required_payload,
          allow_create?,
          allow_reactivation?
        )
      end

      reply =
        state.store_pid
        |> ConversationParticipantStore.guarded_upsert(guard, transition)
        |> normalize_incarnation_result()

      participant_result(reply, state)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp validate_incarnation_contract(desired, %{
         "payload_field" => field,
         "required_payload" => required_payload,
         "allow_create" => allow_create?,
         "allow_reactivation" => allow_reactivation?,
         "record_guard" => guard
       })
       when is_binary(field) and field != "" and is_boolean(allow_create?) and
              is_boolean(allow_reactivation?) and is_map(required_payload) and is_map(guard) do
    payload = desired["payload"]
    desired_incarnation = if is_map(payload), do: Map.get(payload, field), else: :invalid

    cond do
      not is_map(payload) ->
        {:error, :invalid_participant_incarnation}

      not payload_matches?(payload, required_payload) ->
        {:error, :invalid_participant_incarnation}

      desired_incarnation == nil ->
        {:ok, field, nil, required_payload, allow_create?, allow_reactivation?, guard}

      is_binary(desired_incarnation) and String.trim(desired_incarnation) != "" ->
        {:ok, field, desired_incarnation, required_payload, allow_create?, allow_reactivation?,
         guard}

      true ->
        {:error, :invalid_participant_incarnation}
    end
  end

  defp validate_incarnation_contract(_desired, _contract),
    do: {:error, :invalid_participant_incarnation_contract}

  defp transition_participant_incarnation(
         :not_found,
         desired,
         _field,
         _desired_incarnation,
         _required_payload,
         true,
         _allow_reactivation?
       ),
       do: {:ok, :inserted, desired}

  defp transition_participant_incarnation(
         :not_found,
         _desired,
         _field,
         _desired_incarnation,
         _required_payload,
         false,
         _allow_reactivation?
       ),
       do: {:error, :participant_binding_generation_mismatch}

  defp transition_participant_incarnation(
         current,
         desired,
         field,
         desired_incarnation,
         required_payload,
         _allow_create?,
         allow_reactivation?
       )
       when is_map(current) do
    current_payload = if is_map(current["payload"]), do: current["payload"], else: %{}
    current_incarnation = Map.get(current_payload, field)
    current_provenance = Map.take(current_payload, Map.keys(required_payload))

    cond do
      not same_participant_identity?(current, desired) ->
        {:error, :participant_identity_conflict}

      not is_nil(current["deleted_at"]) ->
        {:error, :not_found}

      current_provenance != %{} and current_provenance != required_payload ->
        {:error, :participant_binding_generation_mismatch}

      current["state"] == "active" and current_incarnation == desired_incarnation and
          current_provenance == required_payload ->
        {:ok, :exists, current}

      current["state"] == "active" and
          (current_incarnation == desired_incarnation or
             (is_nil(current_incarnation) and is_binary(desired_incarnation))) ->
        {:ok, :repaired,
         current
         |> Map.put(
           "payload",
           current_payload
           |> Map.merge(required_payload)
           |> put_optional_payload_field(field, desired_incarnation)
         )
         |> Map.put("updated_at", desired["updated_at"] || System.system_time(:millisecond))}

      current["state"] == "inactive" and allow_reactivation? and
        is_binary(desired_incarnation) and current_incarnation != desired_incarnation ->
        {:ok, :activated, activate_participant(current, desired)}

      current["state"] == "inactive" and allow_reactivation? and
        is_nil(desired_incarnation) and is_nil(current_incarnation) ->
        {:ok, :activated, activate_participant(current, desired)}

      true ->
        {:error, :participant_binding_generation_mismatch}
    end
  end

  defp normalize_incarnation_result({:error, :guard_record_mismatch}),
    do: {:error, :participant_binding_generation_mismatch}

  defp normalize_incarnation_result(result), do: result

  defp put_optional_payload_field(payload, field, nil), do: Map.delete(payload, field)
  defp put_optional_payload_field(payload, field, value), do: Map.put(payload, field, value)

  defp participant_result({:ok, _status, participant} = reply, state),
    do: {reply, update_realtime_participant(state, participant)}

  defp participant_result({:ok, participant} = reply, state),
    do: {reply, update_realtime_participant(state, participant)}

  defp participant_result(reply, state), do: {reply, state}

  defp request_deactivation_drain({:ok, _participant}),
    do: GenServer.cast(self(), :drain)

  defp request_deactivation_drain({:ok, _status, _participant}),
    do: GenServer.cast(self(), :drain)

  defp request_deactivation_drain(_reply), do: :ok

  defp update_realtime_participant(state, participant) do
    next_state =
      state
      |> Map.merge(%{participant: participant, participant_load_error: nil})
      |> reconcile_realtime_state()

    if next_state.session_ref != state.session_ref or
         next_state.realtime_status_ref != state.realtime_status_ref or
         next_state.realtime_status != state.realtime_status do
      notify_realtime_subscribers(next_state)
    end

    next_state
  end

  defp current_realtime_status(state) do
    case ensure_participant_loaded(state) do
      {:ok, state} ->
        state =
          if map_size(state.realtime_subscribers) > 0 do
            reconcile_realtime_state(state, true)
          else
            desired_ref = ConversationParticipantActivity.session_ref(state.participant)

            state =
              state
              |> retire_realtime_subscription()
              |> retain_realtime_status_for(desired_ref)

            case read_realtime_status(state, desired_ref) do
              {:ok, status} -> cache_realtime_status(state, desired_ref, status)
              {:error, _reason} -> state
            end
          end

        desired_ref = ConversationParticipantActivity.session_ref(state.participant)

        case {state.realtime_status_ref, state.realtime_status} do
          {^desired_ref, %{} = status} when not is_nil(desired_ref) ->
            {{:ok, status}, state}

          _other ->
            {{:error, :participant_status_unavailable}, state}
        end

      {:error, reason, state} ->
        {{:error, {:participant_state_unavailable, reason}}, state}
    end
  end

  defp reconcile_realtime_state(state), do: reconcile_realtime_state(state, false)

  defp reconcile_realtime_state(%{participant: participant} = state, force?)
       when is_map(participant) do
    desired_ref = ConversationParticipantActivity.session_ref(participant)

    cond do
      is_nil(desired_ref) ->
        retire_realtime_state(state)

      not force? and map_size(state.realtime_subscribers) == 0 ->
        state
        |> retire_realtime_subscription()
        |> retain_realtime_status_for(desired_ref)

      not force? and desired_ref == state.session_ref and
        state.realtime_status_ref == desired_ref and
          is_map(state.realtime_status) ->
        state

      desired_ref == state.session_ref ->
        {state, _changed?} = refresh_realtime_status(state)
        state

      true ->
        state =
          state
          |> retire_realtime_subscription()
          |> retain_realtime_status_for(desired_ref)

        {agent_id, session_id} = desired_ref

        case SessionActivity.subscribe(agent_id, session_id) do
          :ok ->
            {state, _changed?} =
              state
              |> Map.put(:session_ref, desired_ref)
              |> refresh_realtime_status()

            state

          {:error, _reason} ->
            state
        end
    end
  end

  defp reconcile_realtime_state(state, _force?), do: retire_realtime_state(state)

  defp refresh_realtime_status(%{session_ref: {agent_id, session_id}} = state) do
    ref = {agent_id, session_id}

    case read_realtime_status(state, ref) do
      {:ok, next_status} ->
        changed? =
          state.realtime_status_ref != ref or next_status != state.realtime_status

        {cache_realtime_status(state, ref, next_status), changed?}

      {:error, _reason} ->
        # SessionActivity notifications are invalidation hints. A transient
        # read failure carries no newer semantic status and must not erase the
        # Participant owner's last reliable snapshot.
        {retain_realtime_status_for(state, ref), false}
    end
  end

  defp refresh_realtime_status(state), do: {state, false}

  defp read_realtime_status(state, {agent_id, session_id}) do
    case SessionActivity.get(agent_id, session_id) do
      {:ok, activity} when is_map(activity) ->
        {:ok,
         ConversationParticipantActivity.status_result(
           state.group_id,
           state.conversation_id,
           state.participant_id,
           activity
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_realtime_status(_state, _session_ref), do: {:error, :invalid_session_ref}

  defp retire_realtime_state(state) do
    state = retire_realtime_subscription(state)
    %{state | realtime_status: nil, realtime_status_ref: nil}
  end

  defp retire_realtime_subscription(state) do
    unsubscribe_session(state.session_ref)
    %{state | session_ref: nil, realtime_refresh: nil}
  end

  defp retain_realtime_status_for(state, ref) do
    if state.realtime_status_ref == ref and is_map(state.realtime_status) do
      state
    else
      %{state | realtime_status: nil, realtime_status_ref: nil}
    end
  end

  defp cache_realtime_status(state, ref, status),
    do: %{state | realtime_status: status, realtime_status_ref: ref}

  defp unsubscribe_session({agent_id, session_id}) do
    _ = SessionActivity.unsubscribe(agent_id, session_id)
    :ok
  end

  defp unsubscribe_session(_session_ref), do: :ok

  defp put_realtime_subscriber(state, subscriber) do
    if Map.has_key?(state.realtime_subscribers, subscriber) do
      state
    else
      %{
        state
        | realtime_subscribers:
            Map.put(state.realtime_subscribers, subscriber, Process.monitor(subscriber))
      }
    end
  end

  defp notify_realtime_subscribers(state) do
    event =
      {:conversation_participant_status_changed, state.group_id, state.conversation_id,
       state.participant_id}

    Enum.each(Map.keys(state.realtime_subscribers), &send(&1, event))
  end

  defp activate_participant(participant, attrs) do
    cursor_seq =
      if is_integer(attrs[:triage_join_cursor]) and
           get_in(participant, ["notification_filter", "messages"]) == "none" do
        # The muted cursor counted ignored messages, not delivered messages.
        # Only the Conversation owner's first Triage join can replay this suffix.
        attrs[:triage_join_cursor]
      else
        max(
          participant_cursor_seq(participant),
          nonnegative_integer(attrs["delivery_cursor_seq"])
        )
      end

    participant =
      if participant["actor_type"] in ["agent", "provider"] and
           (participant["state"] == "inactive" or is_nil(participant["source_start_seq"]) or
              (is_integer(attrs[:triage_join_cursor]) and
                 get_in(participant, ["notification_filter", "messages"]) == "none")) do
        Map.put(participant, "source_start_seq", cursor_seq)
      else
        participant
      end

    participant
    |> Map.merge(
      Map.take(
        attrs,
        ~w(role_label notification_filter payload agent_name delivery_session_name delivery_billing_context)
      )
    )
    |> Map.put("state", "active")
    |> Map.put("notification_filter", activation_notification_filter(participant, attrs))
    |> Map.put("delivery_cursor_seq", cursor_seq)
    |> Map.delete("task_thread_delivery_fence")
    |> Map.put("updated_at", attrs["updated_at"] || System.system_time(:millisecond))
  end

  defp deactivate_participant(participant, updated_at) do
    participant
    |> Map.put("state", "inactive")
    |> Map.put("notification_filter", %{
      "messages" => "none",
      "statuses" => "none"
    })
    |> Map.put("updated_at", updated_at)
  end

  defp fence_participant_incarnation(
         participant,
         expected_payload,
         fence_token,
         cutoff_seq,
         updated_at
       ) do
    expected_generation = Map.get(expected_payload, "task_thread_binding_token", :missing)
    payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}
    current_generation = Map.get(payload, "task_thread_binding_token")
    existing_fence = participant["task_thread_delivery_fence"]

    cond do
      not task_thread_participant?(participant) ->
        {:error, :task_thread_participant_required}

      not valid_task_thread_generation?(expected_generation) ->
        {:error, :invalid_participant_incarnation}

      current_generation != expected_generation ->
        {:error, :participant_binding_generation_mismatch}

      is_map(existing_fence) and existing_fence["fence_token"] != fence_token ->
        {:error, :participant_delivery_fence_mismatch}

      is_map(existing_fence) and
          (participant["state"] != "inactive" or
             existing_fence["binding_token"] != expected_generation or
             not is_integer(existing_fence["cutoff_seq"]) or
             participant_cursor_seq(participant) < existing_fence["cutoff_seq"]) ->
        {:error, :participant_delivery_fence_corrupt}

      is_map(existing_fence) ->
        participant

      true ->
        participant
        |> Map.put("state", "inactive")
        |> Map.put("notification_filter", %{
          "messages" => "none",
          "statuses" => "none"
        })
        |> Map.put(
          "delivery_cursor_seq",
          max(participant_cursor_seq(participant), cutoff_seq)
        )
        |> Map.put("task_thread_delivery_fence", %{
          "fence_token" => fence_token,
          "binding_token" => expected_generation,
          "cutoff_seq" => cutoff_seq,
          "fenced_at" => updated_at
        })
        |> Map.put("updated_at", updated_at)
    end
  end

  defp participant_delivery_barrier_status(state) do
    cutoff = get_in(state.participant, ["task_thread_delivery_fence", "cutoff_seq"]) || 0

    settled =
      not is_pid(state.drain_pid) and
        (state.participant["delivery_log_cursor_seq"] || 0) >= cutoff

    unless settled, do: GenServer.cast(self(), :drain)
    {:ok, if(settled, do: "settled", else: "pending"), state}
  end

  defp payload_matches?(payload, expected) when is_map(expected) do
    payload = if is_map(payload), do: payload, else: %{}
    Enum.all?(expected, fn {key, value} -> Map.get(payload, key) == value end)
  end

  defp task_thread_participant?(participant) when is_map(participant) do
    participant["actor_type"] == "provider" and participant["provider"] == "slack" and
      participant["role_label"] == "slack_thread" and
      get_in(participant, ["payload", "task_thread_binding_type"]) == @task_thread_binding_type
  end

  defp task_thread_participant?(_participant), do: false

  defp task_thread_delivery?(rec, participant) when is_map(rec) do
    task_thread_participant?(participant) or task_thread_delivery_record?(rec)
  end

  defp task_thread_delivery?(_rec, _participant), do: false

  defp task_thread_delivery_allowed?(rec, participant)
       when is_map(rec) and is_map(participant) do
    if task_thread_delivery_record?(rec) do
      delivery_generation = Map.get(rec, "task_thread_binding_token")
      payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}
      participant_generation = Map.get(payload, "task_thread_binding_token")

      task_thread_participant?(participant) and participant["state"] == "active" and
        not legacy_triage_slack_thread_participant?(participant) and
        not is_map(participant["task_thread_delivery_fence"]) and
        valid_task_thread_generation?(delivery_generation) and
        valid_task_thread_generation?(participant_generation) and
        delivery_generation == participant_generation
    else
      false
    end
  end

  defp task_thread_delivery_allowed?(_rec, _participant), do: false

  defp valid_task_thread_generation?(nil), do: true

  defp valid_task_thread_generation?(generation) when is_binary(generation),
    do: String.trim(generation) != ""

  defp valid_task_thread_generation?(_generation), do: false

  defp activation_notification_filter(participant, attrs) do
    case attrs["notification_filter"] do
      %{} = filter ->
        filter

      _ ->
        default_notification_filter(participant)
    end
  end

  defp canonical_notification_filter(participant) do
    filter =
      case participant["notification_filter"] do
        %{} = current ->
          current

        _ ->
          messages =
            if Map.get(participant, "wake_on_message", default_messages?(participant)),
              do: "all",
              else: "none"

          %{"messages" => messages, "statuses" => "none"}
      end

    participant
    |> Map.put("notification_filter", filter)
    |> Map.delete("wake_on_message")
  end

  defp default_messages?(%{"actor_type" => "agent"}), do: true
  defp default_messages?(_participant), do: false

  defp default_notification_filter(participant) do
    %{
      "messages" => if(default_messages?(participant), do: "all", else: "none"),
      "statuses" => "none"
    }
  end

  defp same_participant_identity?(existing, desired) do
    fields =
      case existing["actor_type"] do
        "user" -> ~w(participant_id conversation_id actor_type user_id)
        "agent" -> ~w(participant_id conversation_id actor_type agent_id)
        "provider" -> ~w(participant_id conversation_id actor_type provider target_key)
        _ -> []
      end

    fields != [] and Map.take(existing, fields) == Map.take(desired, fields)
  end

  # Before direct Slack reply delivery, Triage attached a provider Participant to
  # the long-lived Router Conversation. Those records are not a supported
  # subscription: on recovery they could replay the whole internal IM history.
  # Keep the provenance marker as a permanent fence so a rolling-deploy race or
  # a stale writer cannot make the retired Participant provider-eligible again.
  defp load_participant(store_pid) do
    case ConversationParticipantStore.load(store_pid) do
      {:ok, %{"deleted_at" => deleted_at} = participant} when not is_nil(deleted_at) ->
        {:ok, participant}

      {:ok, participant} ->
        retire_legacy_triage_slack_thread_participant(store_pid, participant)

      {:error, _reason} = error ->
        error
    end
  end

  defp retire_legacy_triage_slack_thread_participant(store_pid, participant) do
    if legacy_triage_slack_thread_participant?(participant) and
         not canonical_inactive_participant?(participant) do
      ConversationParticipantStore.update(store_pid, fn current ->
        if legacy_triage_slack_thread_participant?(current) do
          deactivate_participant(current, System.system_time(:millisecond))
        else
          current
        end
      end)
    else
      {:ok, participant}
    end
  end

  defp legacy_triage_slack_thread_participant?(participant) when is_map(participant) do
    participant["actor_type"] == "provider" and participant["provider"] == "slack" and
      participant["role_label"] == "slack_thread" and is_nil(participant["deleted_at"]) and
      trim(get_in(participant, ["payload", "triage_authority_generation"])) != ""
  end

  defp legacy_triage_slack_thread_participant?(_participant), do: false

  defp participant_inactive?(participant) when is_map(participant),
    do:
      participant["state"] == "inactive" or
        legacy_triage_slack_thread_participant?(participant)

  defp participant_inactive?(_participant), do: true

  defp canonical_inactive_participant?(participant) do
    participant["state"] == "inactive" and
      get_in(participant, ["notification_filter", "messages"]) == "none" and
      get_in(participant, ["notification_filter", "statuses"]) == "none"
  end

  defp refresh_participant(state) do
    case load_participant(state.store_pid) do
      {:ok, participant} ->
        %{state | participant: participant, participant_load_error: nil}

      {:error, reason} ->
        %{state | participant: nil, participant_load_error: reason}
    end
  end

  defp task_thread_delivery_record?(rec) when is_map(rec),
    do: rec["task_thread_binding_type"] == @task_thread_binding_type

  defp task_thread_delivery_record?(_rec), do: false

  defp ensure_participant_loaded(%{participant: participant} = state)
       when is_map(participant),
       do: {:ok, state}

  defp ensure_participant_loaded(state) do
    state = refresh_participant(state)

    cond do
      is_map(state.participant) -> {:ok, state}
      state.participant_load_error == :not_found -> {:error, :not_found, state}
      true -> {:error, state.participant_load_error, state}
    end
  end

  defp with_loaded_participant(state, fun) do
    case ensure_participant_loaded(state) do
      {:ok, state} -> fun.(state)
      {:error, reason, state} -> {participant_load_error(reason), state}
    end
  end

  defp participant_load_error(:not_found), do: {:error, :not_found}

  defp participant_load_error(reason),
    do: {:error, {:participant_state_unavailable, reason}}

  defp participant_cursor_seq(participant),
    do: nonnegative_integer(participant["delivery_cursor_seq"]) || 0

  defp targets_participant?(participant, %{"provider_effect" => _} = message),
    do:
      participant["participant_id"] in (get_in(message, ["delivery_filter", "participant_ids"]) ||
                                          [])

  defp targets_participant?(participant, %{"provider_status" => snapshot} = message),
    do:
      participant["participant_id"] in (get_in(message, ["delivery_filter", "participant_ids"]) ||
                                          []) and
        status_subscribed?(participant, snapshot["status"])

  defp targets_participant?(participant, message) do
    not participant_inactive?(participant) and
      (ConversationMessage.targets_participant?(participant, message) or
         (SlackTaskCard.participant?(participant) and
            get_in(participant, ["notification_filter", "messages"]) == "all" and
            get_in(participant, ["payload", "projection"]) == "slack_task_card" and
            SlackTaskCard.timeline_message?(message)))
  end

  defp conversation_tail_seq(conversation) do
    nonnegative_integer(conversation["message_tail_seq"] || conversation["message_count"])
  end

  defp nonnegative_integer(value), do: max(integer(value, 0), 0)

  defp status_delivery_record(conversation, participant) do
    participant_id = participant_storage_id(participant)
    payload = participant["payload"]
    status = trim(conversation["status"])
    updated_at = conversation["updated_at"]

    with {:ok, target} <- status_delivery_target(participant),
         true <-
           participant_id != "" and is_map(payload) and status != "" and
             is_integer(updated_at) do
      recorded_at = now()

      rec =
        %{
          "delivery_id" =>
            Enum.join(
              [
                conversation["agent_group_id"],
                conversation["conversation_id"],
                "status",
                updated_at,
                status,
                participant_id
              ],
              ":"
            ),
          "delivery_kind" => "conversation_status",
          "notification_kind" => "conversation_status",
          "status" => "pending",
          "agent_group_id" => conversation["agent_group_id"],
          "conversation_id" => conversation["conversation_id"],
          "conversation_kind" => conversation["kind"],
          "conversation_source_refs" => conversation["source_refs"] || %{},
          "conversation_title" => conversation["title"],
          "conversation_message_tail_seq" => conversation_tail_seq(conversation),
          "conversation_updated_at" => updated_at,
          "participant_id" => participant_id,
          "participant_role_label" => participant["role_label"],
          "participant_payload" => payload,
          "conversation_status" => status,
          "message_created_at" => updated_at,
          "attempts" => 0,
          "created_at" => recorded_at,
          "updated_at" => recorded_at
        }
        |> Map.merge(target)
        |> put_task_thread_delivery_generation(participant)
        |> put_operation_ref()
        |> strip_empty_values()

      {:ok, rec}
    else
      _ -> {:error, :invalid_conversation_status_notification}
    end
  end

  defp status_delivery_target(%{"actor_type" => "provider", "provider" => provider})
       when is_binary(provider) and provider != "" do
    {:ok, %{"participant_actor_type" => "provider", "participant_provider" => provider}}
  end

  defp status_delivery_target(_participant), do: {:error, :invalid_status_target}

  defp status_subscribed?(participant, status)
       when is_map(participant) and is_binary(status) and status != "" do
    supported? = participant["actor_type"] == "provider"

    subscription = get_in(participant, ["notification_filter", "statuses"]) || "none"

    not participant_inactive?(participant) and supported? and
      (subscription == "all" or (is_list(subscription) and status in subscription))
  end

  defp status_subscribed?(_participant, _status), do: false

  defp provider_delivery_record(conversation, message, participant, opts \\ []) do
    # The receipt keeps one operation reference across platform verification
    # and retries. The Conversation log remains the only source of pending work.
    group_id = conversation["agent_group_id"]
    conversation_id = conversation["conversation_id"]
    delivery_identity = message["message_id"]
    participant_id = participant_storage_id(participant)

    {delivery_kind, notification_kind} =
      canonical_provider_delivery_kind(Keyword.get(opts, :delivery_kind, "group_conversation"))

    rec =
      conversation
      |> ConversationMessage.delivery_record(message, participant, now())
      |> Map.merge(%{
        "delivery_id" =>
          Enum.join([group_id, conversation_id, delivery_identity, participant_id], ":"),
        "delivery_kind" => delivery_kind,
        "request_identity" => message["request_identity"],
        "request_fingerprint" => message["request_fingerprint"],
        "participant_actor_type" => "provider",
        "participant_provider" => participant["provider"],
        "notification_kind" => notification_kind
      })
      |> put_task_thread_delivery_generation(participant)
      |> put_operation_ref()
      |> strip_empty_values()

    rec
  end

  defp put_operation_ref(rec) do
    ref = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    Map.put(rec, "operation_ref", "groupconv-delivery-" <> ref)
  end

  defp canonical_provider_delivery_kind("group_conversation"), do: {"group_conversation", nil}

  defp canonical_provider_delivery_kind(kind),
    do:
      {"participant_notification",
       if(is_binary(kind) and kind not in ["", "participant_notification"], do: kind)}

  defp participant_storage_id(participant), do: trim(participant["participant_id"])

  defp put_task_thread_delivery_generation(rec, participant) do
    if task_thread_participant?(participant) do
      generation = get_in(participant, ["payload", "task_thread_binding_token"])

      if valid_task_thread_generation?(generation) do
        rec
        |> Map.put("task_thread_binding_type", @task_thread_binding_type)
        |> Map.put("task_thread_binding_token", generation)
      else
        rec
      end
    else
      rec
    end
  end

  defp canonical_legacy_delivery(conversation, participant, facts) do
    facts = Map.take(facts, @legacy_delivery_fact_fields)
    delivery_id = trim(facts["delivery_id"])
    now = System.system_time(:millisecond)

    if delivery_id == "" do
      {:error, {:bad_request, "delivery_id is required"}}
    else
      {:ok,
       facts
       |> Map.merge(%{
         "delivery_id" => delivery_id,
         "agent_group_id" => conversation["agent_group_id"],
         "conversation_id" => conversation["conversation_id"],
         "conversation_kind" => conversation["kind"],
         "conversation_source_refs" => conversation["source_refs"] || %{},
         "conversation_title" => conversation["title"],
         "participant_id" => participant["participant_id"],
         "participant_actor_type" => participant["actor_type"],
         "participant_agent_id" => participant["agent_id"],
         "participant_provider" => participant["provider"],
         "participant_role_label" => participant["role_label"],
         "participant_payload" => participant["payload"] || %{},
         "status" => "pending",
         "attempts" => 0,
         "created_at" => now,
         "updated_at" => now
       })
       |> put_task_thread_delivery_generation(participant)
       |> strip_empty_values()}
    end
  end

  defp canonicalize_legacy_delivery_participant(rec, participant) do
    legacy_fields =
      ~w(target_participant_id target_agent_id target_role_label target_session_id target_provider target_connect_id target_channel_id target_thread_ts target_session_name target_billing_context target_actor_type)

    if Enum.any?(legacy_fields, &Map.has_key?(rec, &1)) do
      payload =
        (participant["payload"] || %{})
        |> put_if_blank("session_id", rec["target_session_id"])
        |> put_if_blank("connect_id", rec["target_connect_id"])
        |> put_if_blank("channel_id", rec["target_channel_id"])
        |> put_if_blank("thread_ts", rec["target_thread_ts"])

      rec
      |> Map.drop(legacy_fields)
      |> Map.put("participant_id", participant["participant_id"])
      |> put_if_blank("participant_agent_id", participant["agent_id"])
      |> put_if_blank("participant_role_label", participant["role_label"])
      |> put_if_blank("participant_provider", participant["provider"])
      |> put_if_blank("delivery_session_name", rec["target_session_name"])
      |> put_if_blank("delivery_billing_context", rec["target_billing_context"])
      |> Map.put("participant_payload", payload)
      |> Map.put("participant_actor_type", participant["actor_type"])
    else
      :skip
    end
  end

  defp put_if_blank(map, key, value) do
    if map[key] in [nil, ""], do: put_present(map, key, value), else: map
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp strip_empty_values(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, "", %{}] end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp now, do: System.system_time(:millisecond)
end
