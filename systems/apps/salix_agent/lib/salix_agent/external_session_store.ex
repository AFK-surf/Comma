defmodule SalixAgent.ExternalSessionStore do
  @moduledoc """
  Persistence boundary for one external agent session.

  `state.json` owns the exact runtime binding, pending input, permanent
  delivery deduplication, Session metadata, Salix tool state, and the nullable
  migration phase. Native identity and execution belong to the Connector.
  The ordered `SessionRecord` stream contains the work history. Runtime events
  provide fenced evidence; they do not grant dispatch or retry authority.
  `tla/salix/ExternalRuntime.tla` models exact-prefix acceptance and lifecycle
  identity fencing. Its mapping and limits are in `tla/salix/README.md`.
  Native transfer, migration recovery, and projection repair use runtime
  regressions; no retained model proves end-to-end provider progress.
  """

  require Logger

  alias SalixAgent.{
    AgentActor,
    AgentControl,
    ContextProviders,
    ExternalSessionActor,
    ExternalSessionLifecycleObservation,
    ExternalSessionRecords,
    ExternalSessionStatus,
    RuntimeEnvironment,
    SessionActivity,
    SessionWorkIndex,
    Waits
  }

  alias SalixStore.{Compute, Ids, Keys, RuntimeIds, S3, SegmentLog, ULID}

  @llm_capability_ttl_seconds 72 * 60 * 60
  @trace_limit_default 100
  @trace_limit_max 500
  @stable_binding_fields ~w(kind provider device_id runtime_id device_runtime_id workload_id runtime_spec owner_scope)
  @session_config_fields ~w(model model_provider reasoning_effort)
  @metadata_fields ~w(name hidden platform billing_context source_session_id source_schedule_id task_origin)
  @external_runtime_providers RuntimeIds.external_runtime_providers()
  @terminal_issues ~w(quota_exhausted rate_limited authentication_required model_unavailable recovery_exhausted runtime_failed)

  @delivery_role_required {:error, {:bad_request, "external delivery role is required"}}
  @runtime_identity_required {:error,
                              {:bad_request,
                               "external runtime delivery requires source_message_id or runtime_message_id"}}
  @runtime_kind_invalid {:error,
                         {:bad_request,
                          "external runtime delivery kind must be runtime_message when provided"}}
  @runtime_type_required {:error,
                          {:bad_request,
                           "external runtime delivery requires runtime message type"}}

  @type records :: ExternalSessionRecords.cache()

  def load_records(agent_id, session_id), do: ExternalSessionRecords.load(agent_id, session_id)

  def stage_delivery(agent_id, delivery, %SegmentLog{} = records)
      when is_binary(agent_id) and is_map(delivery) do
    with {:ok, agent} <- AgentControl.get_record(agent_id) do
      with_group_provider_admission(agent, fn ->
        do_stage_delivery(agent_id, delivery, records)
      end)
    end
  end

  defp do_stage_delivery(
         agent_id,
         %{conversation_source: source} = delivery,
         %SegmentLog{} = records
       )
       when is_binary(agent_id) and is_map(source) do
    delivery = normalize_delivery(delivery)
    scan? = delivery[:conversation_scan_only] == true

    with :ok <- AgentControl.ensure_not_stopped(agent_id),
         {:ok, agent} <- AgentControl.get_record(agent_id),
         {:ok, session_id} <- delivery_session_id(delivery),
         true <- external_delivery_target?(agent, agent_id, session_id),
         :ok <- if(scan?, do: :ok, else: validate_delivery_payloads(delivery_payloads(delivery))),
         {:ok, source_id} <- if(scan?, do: {:ok, nil}, else: require_ledger_source_id(delivery)),
         runtime = agent["runtime_config"] || %{"kind" => "internal"},
         {:ok, _state} <- admit_session(agent, session_id, runtime, delivery) do
      case update_state(agent_id, session_id, fn current ->
             with {:ok, sources} <- advance_conversation_source(current, source),
                  :ok <- ensure_admissible(current, runtime, delivery) do
               cond do
                 scan? or dedupe_member?(current, source_id) ->
                   {:ok, Map.put(current, "conversation_sources", sources)}

                 input_queue_saturated?(current, delivery) ->
                   {:skip, :saturated}

                 true ->
                   {:ok,
                    current
                    |> canonicalize_runtime(runtime)
                    |> enqueue(delivery, records.last_id)
                    |> record_dedupe(source_id)
                    |> put_metadata(delivery_payload(delivery))
                    |> Map.put("conversation_sources", sources)
                    |> Map.put("updated_at", now())}
               end
             end
           end) do
        {:ok, state} -> {:ok, :external, state, records}
        {:skip, :duplicate} -> {:ok, :duplicate}
        {:skip, :saturated} -> {:error, :saturated}
        {:error, _} = error -> error
      end
    else
      false -> {:ok, :internal, nil, records}
      {:error, :session_born_internal} -> {:ok, :internal, nil, records}
      {:error, _} = error -> error
    end
  end

  defp do_stage_delivery(agent_id, delivery, %SegmentLog{} = records)
       when is_binary(agent_id) and is_map(delivery) do
    delivery = normalize_delivery(delivery)

    with :ok <- AgentControl.ensure_not_stopped(agent_id),
         {:ok, agent} <- AgentControl.get_record(agent_id),
         {:ok, session_id} <- delivery_session_id(delivery),
         true <- external_delivery_target?(agent, agent_id, session_id),
         :ok <- validate_delivery_payloads(delivery_payloads(delivery)),
         {:ok, source_id} <- require_ledger_source_id(delivery),
         runtime = agent["runtime_config"] || %{"kind" => "internal"},
         {:ok, state} <- admit_session(agent, session_id, runtime, delivery) do
      # Dedupe and admission are decided inside the same single-object CAS
      # that appends the queue items, so a duplicate or saturated answer is
      # authoritative with zero writes, and an accepted delivery persists its
      # ledger entry atomically with the enqueue (issue #870: this ledger is
      # the delivery dedupe authority; the inbox create-once object was the
      # only external dedupe before and it is deleted at absorb, so a
      # same-id redelivery after absorb duplicated). The ledger is permanent
      # — same commitment as the internal session's `input_dedupe`.
      #
      # Ordering matters: the ledger lookup is READ-ONLY and answers before
      # writability is required, so a committed id keeps acking as duplicate
      # even after the exact runtime binding changed (review finding: the
      # response-loss/same-id ack contract must survive a binding change);
      # writability gates only NEW ids.
      if dedupe_member?(state, source_id) do
        {:ok, :duplicate}
      else
        case update_state(agent_id, session_id, fn current ->
               cond do
                 dedupe_member?(current, source_id) ->
                   {:skip, :duplicate}

                 true ->
                   with :ok <- ensure_admissible(current, runtime, delivery) do
                     if input_queue_saturated?(current, delivery) do
                       {:skip, :saturated}
                     else
                       {:ok,
                        current
                        |> canonicalize_runtime(runtime)
                        |> enqueue(delivery, records.last_id)
                        |> record_dedupe(source_id)
                        |> put_metadata(delivery_payload(delivery))
                        |> Map.put("updated_at", now())}
                     end
                   end
               end
             end) do
          {:ok, state} -> {:ok, :external, state, records}
          {:skip, :duplicate} -> {:ok, :duplicate}
          {:skip, :saturated} -> {:error, :saturated}
          {:error, _} = error -> error
        end
      end
    else
      false -> {:ok, :internal, nil, records}
      # The birth marker records this id as internally born: same answer as
      # the runtime gate — the delivery belongs to the internal side.
      {:error, :session_born_internal} -> {:ok, :internal, nil, records}
      {:error, _} = error -> error
    end
  end

  # Session-grain runtime authority (#873 round 5, owner ruling 2026-08-15):
  # an external-BORN session keeps answering through this store even after
  # the agent record flipped internal — the dedupe ledger still acks its
  # committed ids as duplicates, and ensure_writable answers the comma-31
  # read_only contract for new ids (the birth binding is gone, so new input
  # is refused, never rerouted into a fabricated internal session with the
  # same id). Only when the session does not exist yet does the agent
  # record decide: {:ok, :internal} tells the caller a new session on an
  # internal agent belongs to the internal store.
  defp external_delivery_target?(agent, agent_id, session_id) do
    AgentControl.external_runtime?(agent) or exists?(agent_id, session_id)
  end

  defp advance_conversation_source(state, source) do
    sources = state["conversation_sources"] || %{}
    key = source["participant_id"]
    previous = sources[key] || %{}
    floor = source["start_seq"] || 0
    seq = source["seq"]

    cond do
      not is_binary(key) or not is_binary(source["conversation_id"]) or
        source["generation"] != state["session_id"] or
        not is_integer(floor) or floor < 0 or not is_integer(seq) or
          (previous != %{} and previous["conversation_id"] != source["conversation_id"]) ->
        {:error, :conversation_source_gap}

      seq <= max(previous["seq"] || 0, floor) ->
        {:skip, :duplicate}

      seq != max(previous["seq"] || 0, floor) + 1 ->
        {:error, :conversation_source_gap}

      true ->
        source = Map.put_new(source, "last_rejection", previous["last_rejection"])
        {:ok, Map.put(sources, key, source)}
    end
  end

  def begin_session(agent_id, session_id, tenant_id, runtime, %SegmentLog{} = records)
      when is_map(runtime) do
    with :ok <- AgentControl.ensure_not_stopped(agent_id),
         {:ok, agent} <- AgentControl.get(agent_id, tenant_id),
         {:ok, state} <- get_session_record(agent_id, session_id),
         :ok <- migration_dispatch_allowed(state),
         :ok <- ensure_writable(state, runtime),
         binding = get_in(state, ["runtime", "binding"]),
         {:ok, resolved} <-
           RuntimeEnvironment.resolve_external_runtime_binding(
             binding,
             tenant_id,
             agent["group_id"]
           ),
         {:ok, resolved} <- resolve_compute_runtime_model(agent_id, resolved),
         {:ok, state} <- clear_runtime_wait(agent_id, session_id, state),
         {:ok, capability, state} <-
           session_runtime_capability(agent, session_id, runtime, resolved, state) do
      dispatch_binding =
        resolved
        |> Map.merge(Map.take(binding, @session_config_fields))
        |> Map.put("runtime_capability", capability)

      {:ok, dispatch_binding, state, records}
    end
  end

  defp resolve_compute_runtime_model(
         agent_id,
         %{"kind" => "compute_workload", "runtime_spec" => runtime_spec} = resolved
       )
       when is_map(runtime_spec) do
    if present?(runtime_spec["model"]) do
      {:ok, resolved}
    else
      with {:ok, llm} <- SalixAgent.LlmResolver.resolve_runtime(agent_id) do
        defaults =
          %{}
          |> maybe_put("model", value(llm, "model"))
          |> maybe_put("model_provider", value(llm, "provider"))
          |> maybe_put("reasoning_effort", value(llm, "reasoning_effort"))

        {:ok, Map.put(resolved, "runtime_spec", Map.merge(defaults, runtime_spec))}
      end
    end
  end

  defp resolve_compute_runtime_model(_agent_id, resolved), do: {:ok, resolved}

  # Freeze the complete request context on the selected, not-yet-adopted queue
  # prefix. A lost Connector ACK or actor restart must retry the same clock and
  # provider versions under the same dispatch id. This does not adopt them.
  def prepare_activation_context(agent_id, session_id, snapshot, delta, system_prompt, records) do
    count = length(snapshot)

    with {:ok, state} <-
           update_state(agent_id, session_id, fn current ->
             with :ok <- validate_snapshot(current["input_message_queue"], snapshot) do
               queue = current["input_message_queue"]
               last = Enum.at(queue, count - 1)

               if is_map(get_in(last, ["do_not_send_to_llm", "prepared_activation"])) do
                 {:ok, current}
               else
                 floor = record_floor(current, records)

                 {messages, _floor} =
                   Enum.map_reduce((delta && delta.messages) || [], floor, fn payload, floor ->
                     id = ULID.generate(floor)

                     message =
                       input_message(
                         Map.merge(payload, %{"role" => "runtime", "no_wake" => true}),
                         id
                       )

                     {Map.put(message, "content_kind", payload["content_kind"]), id}
                   end)

                 prepared = %{
                   "messages" => messages,
                   "provider_state" => ContextProviders.adopted_provider_state(delta),
                   "system_prompt" => system_prompt
                 }

                 queue =
                   List.update_at(
                     queue,
                     count - 1,
                     &Map.put(&1, "do_not_send_to_llm", %{"prepared_activation" => prepared})
                   )

                 {:ok, Map.put(current, "input_message_queue", queue)}
               end
             end
           end) do
      selected = Enum.take(state["input_message_queue"], count)
      {:ok, selected, get_in(List.last(selected), ["do_not_send_to_llm", "prepared_activation"])}
    end
  end

  def accept_session(agent_id, session_id, attrs, %SegmentLog{} = records)
      when is_map(attrs) do
    token_hash = trim(value(attrs, "token_hash"))
    snapshot = List.wrap(value(attrs, "queue_snapshot"))

    provider_states =
      ContextProviders.normalize_provider_states(value(attrs, "context_provider_states"))

    with true <- token_hash != "",
         {:ok, state} <- get_session_record(agent_id, session_id),
         true <- state["runtime_capability_token_hash"] == token_hash,
         :ok <- validate_snapshot(state["input_message_queue"], snapshot),
         accepted_snapshot = Enum.take(state["input_message_queue"], length(snapshot)),
         context_messages =
           get_in(List.last(accepted_snapshot), [
             "do_not_send_to_llm",
             "prepared_activation",
             "messages"
           ]) || [],
         input_records =
           Enum.map(
             accepted_snapshot ++ context_messages,
             &input_record(agent_id, session_id, &1)
           ),
         {:ok, records, _statuses} <-
           ExternalSessionRecords.append(agent_id, session_id, records, input_records),
         {:ok, state} <-
           update_state(agent_id, session_id, fn current ->
             if current["runtime_capability_token_hash"] == token_hash and
                  snapshot_prefix?(current["input_message_queue"], snapshot) do
               accepted_snapshot =
                 Enum.take(current["input_message_queue"], length(snapshot))

               {:ok,
                current
                |> Map.put(
                  "input_message_queue",
                  Enum.drop(current["input_message_queue"], length(snapshot))
                )
                |> Map.update(
                  "message_count",
                  length(snapshot) + length(context_messages),
                  &(&1 + length(snapshot) + length(context_messages))
                )
                |> maybe_put(
                  "context_provider_states",
                  provider_states,
                  map_size(provider_states) > 0
                )
                |> maybe_put("system_prompt", value(attrs, "system_prompt"))
                |> maybe_put_sources(attrs, accepted_snapshot)
                |> Map.put("updated_at", now())}
             else
               {:error, :stale_external_runtime_session}
             end
           end) do
      notify_session_updated(agent_id, session_id)
      {:ok, :accepted, state, records}
    else
      false -> {:error, :stale_external_runtime_session}
      {:error, _} = error -> error
    end
  end

  def commit_session_events(agent_id, session_id, events, %SegmentLog{} = records)
      when is_list(events) do
    events = normalize_events(events)

    with :ok <- validate_wait_events(events),
         :ok <- validate_delivery_payloads(Enum.filter(events, &(&1["type"] == "delivery"))),
         {:ok, %{"runtime_config" => runtime}} <- AgentControl.get_record(agent_id),
         {:ok, state} <- get_session_record(agent_id, session_id),
         :ok <- ensure_writable(state, runtime),
         {event_records, next_floor} <-
           event_records(agent_id, session_id, events, record_floor(state, records)),
         {:ok, records, _statuses} <-
           ExternalSessionRecords.append(agent_id, session_id, records, event_records),
         status_record = status_projection_record(event_records),
         {:ok, state} <-
           update_state(agent_id, session_id, fn current ->
             with :ok <- ensure_writable(current, runtime) do
               {:ok,
                current
                |> apply_events(events, next_floor || records.last_id)
                |> Map.put("updated_at", now())
                |> put_status_projection_target(status_record)}
             end
           end) do
      if status_record do
        project_status(
          ExternalSessionStatus.apply_events(
            agent_id,
            session_id,
            events,
            now(),
            status_record["id"]
          ),
          agent_id,
          session_id
        )
      end

      notify_session_updated(agent_id, session_id)
      {:ok, state, records}
    end
  end

  def append_event(agent_id, session_id, attrs, %SegmentLog{} = records)
      when is_map(attrs) do
    case append_event_record(agent_id, session_id, attrs, records) do
      {:ok, _state, _record, _records} = result ->
        notify_session_updated(agent_id, session_id)
        result

      {:error, _} = error ->
        error
    end
  end

  defp append_event_record(agent_id, session_id, attrs, %SegmentLog{} = records)
       when is_map(attrs) do
    token_hash = trim(value(attrs, "token_hash"))

    with true <- token_hash != "",
         {:ok, state} <- get_session_record(agent_id, session_id),
         true <- state["runtime_capability_token_hash"] == token_hash,
         {:ok, %{"runtime_config" => runtime}} <- AgentControl.get_record(agent_id),
         :ok <- ensure_writable(state, runtime),
         record = runtime_event_record(agent_id, session_id, attrs, record_floor(state, records)),
         {:ok, records, _statuses} <-
           ExternalSessionRecords.append(agent_id, session_id, records, [record]) do
      {:ok, state, record, records}
    else
      false -> {:error, :stale_external_runtime_session}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end

  def update_session(agent_id, session_id, attrs, %SegmentLog{} = records)
      when is_map(attrs) do
    events =
      []
      |> maybe_add_status_event(attrs)
      |> maybe_add_error_event(attrs)

    with {:ok, state} <-
           update_state(agent_id, session_id, fn current ->
             {:ok,
              current
              |> maybe_put("system_prompt", value(attrs, "system_prompt"))
              |> maybe_put_sources(attrs, [])
              |> Map.put("updated_at", now())}
           end),
         {:ok, state, records} <-
           maybe_commit_events(agent_id, session_id, state, events, records) do
      {:ok, state, records}
    end
  end

  def complete_session(agent_id, session_id, attrs, %SegmentLog{} = records) do
    event =
      %{
        "type" => "status",
        "state" => value(attrs, "state") || "stopped",
        "created_at" => now()
      }
      |> maybe_put("dispatch_id", value(attrs, "dispatch_id"))
      |> maybe_put("execution_id", value(attrs, "execution_id"))

    case commit_status_record(agent_id, session_id, event, records, retire_triage: true) do
      {:ok, state, record, records} ->
        project_status_and_notify(
          ExternalSessionStatus.complete(
            agent_id,
            session_id,
            event["created_at"],
            record["id"]
          ),
          agent_id,
          session_id
        )

        {:ok, state, records}

      {:error, _} = error ->
        error
    end
  end

  def fail_session(agent_id, session_id, reason, attrs, %SegmentLog{} = records) do
    event =
      %{
        "type" => "error",
        "message" => format_error(reason),
        "error_class" => value(attrs, "error_class"),
        "dispatch_id" => value(attrs, "dispatch_id"),
        "terminal" => Map.get(attrs, "terminal", Map.get(attrs, :terminal)),
        "created_at" => now()
      }
      |> compact()

    case commit_status_record(agent_id, session_id, event, records,
           retire_triage: event["terminal"] != false
         ) do
      {:ok, state, record, records} ->
        projection =
          case event["dispatch_id"] do
            dispatch_id when is_binary(dispatch_id) ->
              ExternalSessionStatus.dispatch_failed(
                agent_id,
                session_id,
                dispatch_id,
                event["created_at"],
                record["id"],
                state["status_projection_target"],
                event["terminal"]
              )

            _other ->
              ExternalSessionStatus.fail(
                agent_id,
                session_id,
                event["created_at"],
                record["id"]
              )
          end

        project_status_and_notify(
          projection,
          agent_id,
          session_id
        )

        {:ok, state, records}

      {:error, _} = error ->
        error
    end
  end

  def commit_connector_event(
        capability,
        %{connector_event_batch: params_list},
        %SegmentLog{} = records
      )
      when is_list(params_list) and params_list != [],
      do: commit_connector_events(capability, params_list, records)

  def commit_connector_event(capability, params, %SegmentLog{} = records) do
    agent_id = capability["agent_id"]
    session_id = capability["session_id"]
    event = params["event"] || %{}

    with {:ok, state, record, records} <-
           append_event_record(
             agent_id,
             session_id,
             %{
               "event_id" => params["event_id"],
               "event" => event,
               "connector_run_id" => params["connector_run_id"],
               "model" => params["model"],
               "usage" => params["usage"],
               "token_hash" => capability["token_hash"]
             },
             records
           ),
         projection_results =
           project_connector_status_results(
             agent_id,
             session_id,
             state,
             records,
             [{params, record}],
             [:committed]
           ),
         result = Map.get(projection_results, 0, :ok) do
      notify_session_updated(agent_id, session_id)

      case result do
        :ok ->
          {:ok, %{"ok" => true}, records}

        {:error, reason} ->
          # ExternalRuntimeEventProjection's RetryProjection starts after the
          # event is durable. Preserve that post-append cache across a derived
          # status-projection failure so the identical event-id retry settles
          # as a replay instead of attempting a stale tail append.
          {:error, reason, records}
      end
    end
  end

  # Modeled in tla/salix/ExternalRuntimeEventBatch.tla and
  # tla/salix/ExternalRuntimeEventSegmentPartitions.tla. One Connector transport
  # batch is partitioned by exact session owner before reaching this function.
  # The owner appends the ordered new suffix with one object write per affected
  # segment. Replay records settle duplicate/conflict/missing results with one
  # read plus at most one conditional write per affected segment; independent
  # segments use SegmentLog's fixed-width settlement partition.
  defp commit_connector_events(capability, params_list, %SegmentLog{} = records) do
    agent_id = capability["agent_id"]
    session_id = capability["session_id"]

    with true <- is_binary(agent_id) and is_binary(session_id),
         {:ok, %{"runtime_config" => runtime}} <- AgentControl.get_record(agent_id),
         {:ok, state} <- get_session_record(agent_id, session_id),
         :ok <- ensure_writable(state, runtime),
         true <- capability["token_hash"] == state["runtime_capability_token_hash"],
         records_with_entries =
           Enum.map(params_list, fn params ->
             record =
               runtime_event_record(
                 agent_id,
                 session_id,
                 %{
                   "event_id" => params["event_id"],
                   "event" => params["event"] || %{},
                   "connector_run_id" => params["connector_run_id"],
                   "model" => params["model"],
                   "usage" => params["usage"],
                   "token_hash" => capability["token_hash"]
                 },
                 record_floor(state, records)
               )

             {params, record}
           end),
         {append_results, records} <-
           append_connector_event_records(
             agent_id,
             session_id,
             records_with_entries,
             records
           ) do
      projection_results =
        project_connector_status_results(
          agent_id,
          session_id,
          state,
          records,
          records_with_entries,
          append_results
        )

      results =
        records_with_entries
        |> Enum.zip(append_results)
        |> Enum.with_index()
        |> Enum.map(fn {{{_params, _record}, append_result}, index} ->
          case append_result do
            status when status in [:committed, :duplicate] ->
              case Map.get(projection_results, index, :ok) do
                :ok -> {:ok, %{"ok" => true}}
                {:error, _} = error -> error
              end

            {:error, _} = error ->
              error
          end
        end)

      if Enum.any?(append_results, &(&1 in [:committed, :duplicate])),
        do: notify_session_updated(agent_id, session_id)

      {:ok, %{"results" => results}, records}
    else
      false -> {:error, :stale_external_runtime_session}
      {:error, _} = error -> error
    end
  end

  defp append_connector_event_records(agent_id, session_id, records_with_entries, records) do
    {replay, tail} =
      Enum.split_while(records_with_entries, fn {_params, record} ->
        is_binary(records.last_id) and record["id"] <= records.last_id
      end)

    {replay_results, records} =
      case ExternalSessionRecords.settle_replay(
             agent_id,
             session_id,
             records,
             Enum.map(replay, &elem(&1, 1))
           ) do
        {:ok, records, statuses} ->
          records =
            if Enum.any?(statuses, &match?({:error, _}, &1)) do
              case ExternalSessionRecords.load(agent_id, session_id) do
                {:ok, refreshed} -> refreshed
                {:error, _} -> records
              end
            else
              records
            end

          {statuses, records}

        {:error, reason} ->
          refreshed =
            case ExternalSessionRecords.load(agent_id, session_id) do
              {:ok, refreshed} -> refreshed
              {:error, _} -> records
            end

          {List.duplicate({:error, reason}, length(replay)), refreshed}
      end

    case tail do
      [] ->
        {replay_results, records}

      [_first | _] ->
        tail_records = Enum.map(tail, &elem(&1, 1))

        case ExternalSessionRecords.append(
               agent_id,
               session_id,
               records,
               tail_records
             ) do
          {:ok, records, statuses} ->
            {replay_results ++ statuses, records}

          {:error, reason} ->
            refreshed =
              case ExternalSessionRecords.load(agent_id, session_id) do
                {:ok, refreshed} -> refreshed
                {:error, _} -> records
              end

            {replay_results ++ List.duplicate({:error, reason}, length(tail)), refreshed}
        end
    end
  end

  def start_dispatch(
        agent_id,
        session_id,
        dispatch_id,
        connector_run_id,
        timestamp,
        record_floor,
        source_message_ids
      ) do
    # FORMAL-SPEC: tla/salix/SlackRouterStatusScope.tla Activate. The dispatch
    # identity and its source scope move in one CAS snapshot.
    with {:ok, _state} <-
           update_state(agent_id, session_id, fn current ->
             target = %{
               "dispatch_id" => dispatch_id,
               "connector_run_id" => connector_run_id,
               "record_floor" => record_floor,
               "source_message_ids" => normalize_source_ids(source_message_ids),
               "updated_at" => timestamp,
               "watermark" => get_in(current, ["status_projection_target", "watermark"]),
               "wait_watermark" => get_in(current, ["status_projection_target", "wait_watermark"])
             }

             with :ok <- migration_dispatch_allowed(current) do
               {:ok, Map.put(current, "status_projection_target", target)}
             end
           end) do
      project_status_and_notify(
        ExternalSessionStatus.dispatch_started(
          agent_id,
          session_id,
          dispatch_id,
          connector_run_id,
          timestamp
        ),
        agent_id,
        session_id
      )
    end
  end

  def session_context(agent_id, session_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id) do
      {:ok,
       state
       |> Map.take(
         @metadata_fields ++
           ~w(session_id system_prompt runtime wait runtime_wait async_tool_calls active_external_source_message_ids context_provider_states created_at updated_at) ++
           ~w(active_external_trusted_origins)
       )
       |> Map.put("messages", [])
       |> Map.put("input_messages", state["input_message_queue"] || [])
       |> Map.put_new("context_provider_states", %{})}
    end
  end

  def get_session_record(agent_id, session_id) do
    case get_session_record_with_etag(agent_id, session_id) do
      {:ok, state, _etag} -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  @doc false
  def migration_command(agent_id, session_id, operation_id, action, attrs \\ %{}) do
    update_state(agent_id, session_id, fn state ->
      migration = state["migration"]

      cond do
        action == :begin and migration == nil ->
          if exact_binding(attrs["source"]) == get_in(state, ["runtime", "binding"]) do
            {:ok,
             Map.put(state, "migration", %{
               "operation_id" => operation_id,
               "source" => attrs["source"],
               "target" => attrs["target"],
               "phase" => "draining",
               "deadline" => System.system_time(:millisecond) + 600_000,
               "error" => nil
             })}
          else
            {:error, :migration_source_changed}
          end

        not is_map(migration) or migration["operation_id"] != operation_id ->
          {:error, :migration_operation_conflict}

        action == :begin ->
          if migration["source"] == attrs["source"] and migration["target"] == attrs["target"],
            do: {:ok, state},
            else: {:error, :migration_operation_conflict}

        action == :cancel and migration["phase"] in ~w(draining staged) ->
          {:ok, Map.delete(state, "migration")}

        action == :error ->
          {:ok, put_in(state, ["migration", "error"], attrs["error"])}

        action == :staged and migration["phase"] == "draining" ->
          with :ok <- migration_deadline(migration),
               :ok <- migration_obligations_settled(state) do
            {:ok,
             state
             |> put_in(["migration", "phase"], "staged")
             |> put_in(["migration", "error"], nil)
             |> put_in(["migration", "deadline"], System.system_time(:millisecond) + 1_800_000)}
          end

        action == :staged and migration["phase"] == "staged" ->
          {:ok, state}

        action == :retiring and migration["phase"] == "staged" ->
          with :ok <- migration_deadline(migration),
               :ok <- migration_obligations_settled(state) do
            {:ok,
             state
             |> put_in(["migration", "phase"], "retiring")
             |> put_in(["migration", "error"], nil)}
          end

        action == :commit and migration["phase"] == "retiring" ->
          if get_in(state, ["runtime", "binding"]) == exact_binding(migration["source"]) do
            {:ok,
             state
             |> put_in(["runtime", "binding"], exact_binding(migration["target"]))
             |> put_in(["migration", "phase"], "committed")
             |> put_in(["migration", "error"], nil)
             |> Map.drop(
               ~w(runtime_capability_token runtime_capability_token_hash status_projection_target)
             )}
          else
            {:error, :migration_source_changed}
          end

        action == :commit and migration["phase"] == "committed" ->
          {:ok, state}

        true ->
          {:error, :invalid_migration_transition}
      end
    end)
  end

  defp migration_dispatch_allowed(%{"migration" => %{"phase" => phase}})
       when phase != "committed", do: {:error, :session_migration_in_progress}

  defp migration_dispatch_allowed(%{
         "tenant_id" => tenant,
         "group_id" => group,
         "runtime" => %{"binding" => %{"kind" => "connected_runtime", "device_id" => device}}
       }),
       do: Compute.group_provider_mutation_admission(tenant, group, device)

  defp migration_dispatch_allowed(_), do: :ok

  defp migration_deadline(migration) do
    if System.system_time(:millisecond) < migration["deadline"],
      do: :ok,
      else: {:error, :migration_deadline_elapsed}
  end

  defp migration_obligations_settled(state) do
    busy =
      Enum.any?(state["async_tool_calls"] || %{}, fn {_id, call} ->
        call["status"] not in ~w(completed failed cancelled)
      end)

    if state["wait"] != nil or busy, do: {:error, :migration_obligations_pending}, else: :ok
  end

  @doc false
  @spec get_session_record_with_etag(String.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, :not_found} | {:error, term()}
  def get_session_record_with_etag(agent_id, session_id) do
    if Ids.valid_session_id?(session_id) do
      key = session_key(agent_id, session_id)

      with {:ok, %{body: body, etag: etag}} <- S3.get(key),
           {:ok, state} <- Jason.decode(body),
           :ok <- validate_state(agent_id, session_id, state) do
        {:ok, state, etag}
      end
    else
      {:error, :invalid_session_id}
    end
  end

  # Tri-state existence probe (one HEAD, no body read) — the session-grain
  # runtime resolution in SessionDelivery uses this to find a session's
  # birth store. `:absent` means CONFIRMED not-found; any other HEAD error
  # is surfaced so birth routing can fail closed instead of reading a
  # transient failure as absence (#873 round 7). Mirrors
  # InternalSessionStore.probe/2.
  @spec probe(String.t(), String.t()) :: :present | :absent | {:error, term()}
  def probe(agent_id, session_id) do
    if Ids.valid_session_id?(session_id) do
      case S3.head(session_key(agent_id, session_id)) do
        {:ok, _} -> :present
        {:error, :not_found} -> :absent
        {:error, reason} -> {:error, reason}
      end
    else
      :absent
    end
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(agent_id, session_id), do: probe(agent_id, session_id) == :present

  def get_async_tool_call(agent_id, session_id, tool_call_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id),
         %{} = call <- get_in(state, ["async_tool_calls", tool_call_id]) do
      {:ok, drop_trusted_origin(call)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def list_sessions(agent_id) do
    with {:ok, states} <- list_states(agent_id),
         do: {:ok, Enum.map(states, &public_state/1)}
  end

  @doc "One bounded page of canonical Session states for the Agent archive owner."
  def stop_page(agent_id, cursor) do
    session_page(agent_id, cursor, 2)
  end

  @doc false
  def migration_page(agent_id, cursor), do: session_page(agent_id, cursor, 100)

  defp session_page(agent_id, cursor, limit) do
    prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)
    # Two six-second transport attempts leave room inside the command deadline.
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(prefix, max_keys: limit, delimiter: "/", continuation_token: cursor) do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
        if state_key?(prefix, key) do
          session_id = key |> String.replace_prefix(prefix, "") |> String.trim_trailing(".json")

          case get_session_record(agent_id, session_id) do
            {:ok, state} -> {:cont, {:ok, [state | records]}}
            {:error, :not_found} -> {:cont, {:ok, records}}
            error -> {:halt, error}
          end
        else
          {:cont, {:ok, records}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, %{records: Enum.reverse(records), next: next}}
        error -> error
      end
    end
  end

  def get_session(agent_id, session_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id),
         {:ok, records} <- ExternalSessionRecords.load(agent_id, session_id),
         {:ok, events} <- ExternalSessionRecords.all(agent_id, session_id, records) do
      {:ok, state |> public_state() |> Map.put("events", events)}
    end
  end

  def list_session_summaries(%{"agent_id" => agent_id} = agent) do
    with {:ok, states} <- list_states(agent_id) do
      {:ok,
       states
       |> Enum.map(&session_summary(agent, &1))
       |> Enum.sort_by(&(&1["updated_at"] || &1["created_at"] || 0), :desc)}
    end
  end

  def get_session_summary(%{"agent_id" => agent_id} = agent, session_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id),
         do: {:ok, session_summary(agent, state)}
  end

  def get_session_activity(%{"agent_id" => agent_id} = agent, session_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id),
         {:ok, status} <- read_session_status(agent, state) do
      activity =
        status
        |> Map.put("runtime_kind", "external")
        |> Map.put("session_id", session_id)
        |> SessionActivity.project()

      {:ok,
       Map.put(
         activity,
         "_active_source_message_ids",
         List.wrap(get_in(state, ["status_projection_target", "source_message_ids"]))
       )}
    end
  end

  def get_session_status(%{"agent_id" => agent_id} = agent, session_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id) do
      {:ok, session_status(agent, state)}
    end
  end

  def get_session_messages(agent_id, session_id) when is_binary(agent_id) do
    with {:ok, agent} <- AgentControl.get_record(agent_id),
         do: get_session_messages(agent, session_id)
  end

  def get_session_messages(%{"agent_id" => agent_id} = agent, session_id) do
    with {:ok, state} <- get_session_record(agent_id, session_id),
         {:ok, records} <- ExternalSessionRecords.load(agent_id, session_id),
         {:ok, all} <- ExternalSessionRecords.all(agent_id, session_id, records) do
      {:ok,
       %{
         "session_id" => session_id,
         "status" => session_status(agent, state)["status"],
         "messages" => all |> message_records() |> ContextProviders.strip_llm_private_metadata()
       }}
    end
  end

  def session_records(%{"agent_id" => agent_id} = agent, session_id, opts \\ []) do
    with {:ok, limit} <- trace_limit(Keyword.get(opts, :limit)),
         {:ok, state} <- get_session_record(agent_id, session_id),
         {:ok, records} <- ExternalSessionRecords.load(agent_id, session_id),
         {:ok, page, has_more, next_before} <-
           ExternalSessionRecords.tail(
             agent_id,
             session_id,
             records,
             limit,
             Keyword.get(opts, :before)
           ) do
      {:ok,
       %{
         "runtime_kind" => "external",
         "session_id" => session_id,
         "status" => session_status(agent, state)["status"],
         "records" => page,
         "has_more" => has_more
       }
       |> maybe_put("next_before", next_before)}
    end
  end

  def session_trace(%{"agent_id" => agent_id} = agent, session_id, opts \\ []) do
    with {:ok, limit} <- trace_limit(Keyword.get(opts, :limit)),
         {:ok, state} <- get_session_record(agent_id, session_id),
         {:ok, records} <- ExternalSessionRecords.load(agent_id, session_id),
         {:ok, events, has_more, _next_before} <-
           ExternalSessionRecords.tail(agent_id, session_id, records, limit, nil) do
      binding = get_in(state, ["runtime", "binding"]) || %{}

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "runtime_kind" => "external",
         "runtime_provider" =>
           binding["provider"] || get_in(agent, ["runtime_config", "provider"]),
         "status" => session_status(agent, state)["status"],
         "model" => binding["model"],
         "model_provider" => binding["model_provider"],
         "reasoning_effort" => binding["reasoning_effort"],
         "event_count" => length(events),
         "has_more" => has_more,
         "events" => events
       }
       |> compact()}
    end
  end

  def search_messages(%{"agent_id" => agent_id}, query, limit \\ 20) do
    query = query |> to_string() |> String.downcase()
    limit = clamp(limit, 20, 100)

    with {:ok, states} <- list_states(agent_id) do
      results =
        states
        |> Enum.flat_map(fn state -> search_session(agent_id, state["session_id"], query) end)
        |> Enum.take(limit)

      # Same envelope as the internal runtime; external sessions have no
      # archive tier, so the full transcript is always searched.
      {:ok, %{"results" => results, "scope" => "full", "archived_not_searched" => false}}
    end
  end

  # This is a dispatch wait on the existing Session, not a replacement for
  # its model/tool wait. The queue and dispatch identity remain authoritative.
  def park_runtime(agent_id, session_id) do
    update_state(agent_id, session_id, fn state ->
      cond do
        not Enum.any?(List.wrap(state["input_message_queue"]), &wakeable_input?/1) ->
          {:skip, :no_pending_input}

        is_map(state["runtime_wait"]) ->
          # Marking again would publish another Postgres wake notification.
          {:skip, :already_waiting}

        true ->
          {:ok, Map.put(state, "runtime_wait", %{})}
      end
    end)
  end

  defp clear_runtime_wait(agent_id, session_id, state) do
    if is_map(state["runtime_wait"]) do
      update_state(agent_id, session_id, &{:ok, Map.delete(&1, "runtime_wait")})
    else
      {:ok, state}
    end
  end

  def recovery_wait(state), do: state["wait"]

  def work_reasons(state) when is_map(state) do
    []
    |> maybe_add_work_reason(
      Enum.any?(List.wrap(state["input_message_queue"]), &wakeable_input?/1),
      cond do
        get_in(state, ["migration", "phase"]) in ~w(provider_cutover_parked provider_cutover_committed) ->
          "provider_cutover_parked"

        is_map(state["runtime_wait"]) ->
          "runtime_wait"

        true ->
          "unacked_queue_item"
      end
    )
    |> maybe_add_work_reason(is_map(state["wait"]), "wait_deadline")
    |> Kernel.++(async_work_reasons(state["async_tool_calls"]))
    |> Enum.uniq()
  end

  def validate_runtime_capability(raw_token) when is_binary(raw_token) and raw_token != "" do
    case get_record(Keys.ctl_runtime_capability(token_hash(raw_token))) do
      {:ok, capability} ->
        if token_expired?(capability), do: {:error, :unauthorized}, else: {:ok, capability}

      {:error, :not_found} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, {:capability_lookup_failed, reason}}
    end
  end

  def validate_runtime_capability(_raw_token), do: {:error, :unauthorized}

  def runtime_capability_tools(%{"agent_id" => agent_id, "session_id" => session_id} = capability) do
    with :ok <- runtime_capability_current?(capability),
         :ok <- AgentControl.ensure_not_stopped(agent_id),
         {:ok, context} <- session_context(agent_id, session_id),
         {:ok, config} <-
           AgentActor.runtime_session_config(agent_id, %{
             platform: context["platform"],
             session_context: context,
             runtime_kind: :external
           }) do
      {:ok, config.external_tool_specs}
    end
  end

  def execute_runtime_capability_tool(
        %{"agent_id" => agent_id, "session_id" => session_id} = capability,
        tool_name,
        attrs
      )
      when is_map(attrs) do
    with :ok <- runtime_capability_current?(capability),
         :ok <- AgentControl.ensure_not_stopped(agent_id) do
      SalixAgent.execute_session_tool(agent_id, session_id, tool_name, attrs)
    end
  end

  def execute_session_tool(agent_id, session_id, tool_name, attrs) when is_map(attrs),
    do: SalixAgent.execute_session_tool(agent_id, session_id, tool_name, attrs)

  def validate_connector_event(connector_run_id, params, meta \\ %{})

  def validate_connector_event(connector_run_id, params, meta) when is_map(params) do
    with {:ok, capability} <- validate_runtime_capability(params["capability_token"]),
         :ok <- validate_runtime_capability_scope(capability, connector_run_id, meta),
         do: validate_connector_event_payload(capability, connector_run_id, params)
  end

  def validate_connector_event(_connector_run_id, _params, _meta),
    do: {:error, {:bad_request, "invalid external runtime event"}}

  def validate_connector_events(connector_run_id, params_list, meta)
      when is_list(params_list) and is_map(meta) do
    {results, _capabilities} =
      Enum.map_reduce(params_list, %{}, fn params, capabilities ->
        token = if is_map(params), do: params["capability_token"]

        {capability_result, capabilities} =
          case Map.fetch(capabilities, token) do
            {:ok, result} ->
              {result, capabilities}

            :error ->
              result =
                with {:ok, capability} <- validate_runtime_capability(token),
                     :ok <- validate_runtime_capability_scope(capability, connector_run_id, meta) do
                  {:ok, capability}
                end

              {result, Map.put(capabilities, token, result)}
          end

        result =
          with true <- is_map(params),
               {:ok, capability} <- capability_result do
            validate_connector_event_payload(capability, connector_run_id, params)
          else
            false -> {:error, {:bad_request, "invalid external runtime event"}}
            {:error, _} = error -> error
          end

        {result, capabilities}
      end)

    results
  end

  defp validate_connector_event_payload(capability, connector_run_id, params) do
    with %{"created_at" => created_at} = event when is_integer(created_at) and created_at >= 0 <-
           params["event"],
         true <- ULID.valid?(params["event_id"]),
         :ok <- validate_runtime_event(event) do
      {:ok, capability, Map.put(params, "connector_run_id", connector_run_id)}
    else
      nil ->
        {:error, :unauthorized}

      false ->
        {:error, {:bad_request, "event_id requires a valid ULID and integer event.created_at"}}

      {:error, _} = error ->
        error

      _ ->
        {:error, {:bad_request, "event must include integer created_at"}}
    end
  end

  def validate_runtime_capability_scope(capability, connector_run_id, meta)
      when is_map(capability) and is_map(meta) do
    with :ok <- validate_capability_metadata(capability, meta),
         do: validate_capability_transport(capability, connector_run_id)
  end

  def validate_runtime_capability_scope(_capability, _connector_run_id, _meta),
    do: {:error, :unauthorized}

  def mint_llm_capability(agent, session_id, connector_run_id, device_runtime_id)
      when is_map(agent) do
    create_runtime_capability(agent, session_id, %{
      "kind" => "connected_runtime",
      "stable_target_id" => device_runtime_id || connector_run_id,
      "connection_epoch" => 1,
      "connector_run_id" => connector_run_id,
      "device_runtime_id" => device_runtime_id,
      "llm_allowed" => true,
      "expires_in_seconds" => @llm_capability_ttl_seconds
    })
  end

  def mint_llm_capability(agent, session_id, connector_run_id) when is_map(agent) do
    create_runtime_capability(agent, session_id, %{
      "kind" => "connected_runtime",
      "stable_target_id" => connector_run_id,
      "connection_epoch" => 1,
      "connector_run_id" => connector_run_id,
      "llm_allowed" => true,
      "expires_in_seconds" => @llm_capability_ttl_seconds
    })
  end

  def revoke_runtime_capability_by_hash(token_hash)
      when is_binary(token_hash) and token_hash != "",
      do: S3.delete(Keys.ctl_runtime_capability(token_hash))

  def revoke_runtime_capability_by_hash(_), do: {:error, :invalid_token_hash}

  # Admission for a session that does not exist yet is decided BEFORE
  # creation: an oversized first batch would otherwise leave a durable empty
  # state/status pair behind its :saturated refusal (review finding — the
  # zero-write guarantee covers session creation too). For an existing
  # session the authoritative check runs inside the CAS closure.
  defp admit_session(agent, session_id, runtime, delivery) do
    if Ids.valid_session_id?(session_id) do
      case get_session_record(agent["agent_id"], session_id) do
        {:ok, state} ->
          case agent["session_admission"] do
            %{"kind" => "birth", "session_id" => ^session_id} ->
              with {:ok, _} <-
                     AgentControl.release_external_session(agent["agent_id"], session_id),
                   do: {:ok, state}

            _ ->
              {:ok, state}
          end

        {:error, :not_found} ->
          if input_queue_saturated?(%{}, delivery),
            do: {:error, :saturated},
            else: create_session(agent, session_id, runtime)

        {:error, _} = error ->
          error
      end
    else
      {:error, :invalid_session_id}
    end
  end

  @doc false
  def complete_reserved_birth(
        %{"session_admission" => %{"kind" => "birth", "session_id" => id, "binding" => binding}} =
          agent
      ) do
    create_session(agent, id, binding)
  end

  # STORE-LAYER birth authority (#873 round 8): the ONLY code path that
  # produces a first PUT of the external session object, so the birth
  # marker is claimed here, inside the store — whichever ingress reached it
  # (SessionDelivery routing, the direct ExternalAgentRuntime facade, the
  # session_command runtime path). A claim lost to :internal means this id
  # was born internally: refuse with zero writes; stage_delivery maps the
  # refusal to its established {:ok, :internal} decline ("this delivery
  # belongs to the internal side"). See the creation-point audit in
  # docs/salix/conversation-owner-actor.md clause 2b.
  # Marker ABSENCE is not birth authority for the markerless legacy
  # population (#873 round 9): an unmarked id reconciles the INTERNAL
  # store with tri-state/fail-closed semantics before claiming — a legacy
  # internal session found there refuses this create (and backfills its
  # truthful marker); a probe error refuses fail-closed. Creation-only.
  defp create_session(agent, session_id, runtime) do
    agent_id = agent["agent_id"]

    with :ok <- provider_cutover_birth_allowed(agent) do
      case SalixAgent.SessionBirth.side(agent_id, session_id) do
        {:ok, :external} ->
          do_create_session(agent, session_id, runtime)

        {:ok, :internal} ->
          {:error, :session_born_internal}

        {:error, :not_found} ->
          case SalixAgent.InternalSessionStore.probe(agent_id, session_id) do
            :present ->
              _ = SalixAgent.SessionBirth.claim(agent_id, session_id, :internal)
              {:error, :session_born_internal}

            :absent ->
              case SalixAgent.SessionBirth.claim(agent_id, session_id, :external) do
                {:ok, :external} -> do_create_session(agent, session_id, runtime)
                {:ok, :internal} -> {:error, :session_born_internal}
                {:error, _} = error -> error
              end

            {:error, reason} ->
              {:error, {:unavailable, {:session_probe, reason}}}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp do_create_session(agent, session_id, runtime) do
    with {:ok, reserved} <- AgentControl.reserve_external_session(agent["agent_id"], session_id),
         binding = get_in(reserved, ["session_admission", "binding"]),
         {:ok, state} <- put_new_session(reserved, session_id, binding || runtime),
         {:ok, _} <- AgentControl.release_external_session(agent["agent_id"], session_id) do
      {:ok, state}
    end
  end

  defp put_new_session(agent, session_id, runtime) do
    timestamp = now()

    state = %{
      "tenant_id" => agent["tenant_id"],
      "group_id" => agent["group_id"],
      "agent_id" => agent["agent_id"],
      "session_id" => session_id,
      "runtime" => %{"binding" => exact_binding(runtime)},
      "input_message_queue" => [],
      "message_count" => 0,
      "active_external_source_message_ids" => [],
      "active_external_trusted_origins" => %{},
      "context_provider_states" => %{},
      "wait" => nil,
      "async_tool_calls" => %{},
      "storage_revision" => SalixAgent.SessionStorageRevision.new(),
      "work_index_token" => nil,
      "created_at" => timestamp,
      "updated_at" => timestamp
    }

    state =
      case SalixAgent.OwnershipCell.fetch(agent["agent_id"]) do
        {:ok, epoch} -> stamp_runtime_epoch(state, epoch)
        _ -> state
      end

    case S3.put(session_key(agent["agent_id"], session_id), Jason.encode!(state),
           if_none_match: "*"
         ) do
      {:ok, _} ->
        project_status_and_notify(
          ExternalSessionStatus.create(agent["agent_id"], session_id, timestamp),
          agent["agent_id"],
          session_id
        )

        {:ok, state}

      {:error, :precondition_failed} ->
        get_session_record(agent["agent_id"], session_id)

      {:error, _} = error ->
        error
    end
  end

  defp update_state(agent_id, session_id, fun) do
    key = session_key(agent_id, session_id)

    # A fun may answer {:skip, reason} to refuse the update with zero writes
    # (delivery dedupe/admission); the bare with-chain passes it through.
    # The ownership fence runs AFTER the fun so those read-only decisions
    # (e.g. a committed source id acking as duplicate) still work on a node
    # whose runtime for this agent was fenced — only writes are refused.
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, current} <- Jason.decode(body),
         {:ok, next} <- fun.(current),
         {:ok, local_epoch} <- verify_runtime_epoch(agent_id, session_id, current),
         {:ok, next, cleanup} <-
           sync_work_index(agent_id, session_id, current, next,
             cas_base: etag,
             base_revision: current["storage_revision"]
           ) do
      next =
        next
        |> Map.put("storage_revision", SalixAgent.SessionStorageRevision.new())
        |> stamp_runtime_epoch(local_epoch)

      case S3.put(key, Jason.encode!(next), if_match: etag) do
        {:ok, _} ->
          cleanup_work_index(cleanup)
          {:ok, next}

        {:error, :precondition_failed} ->
          cleanup_uncommitted_work_index(agent_id, session_id, next)
          {:error, :stale_external_session_state}

        {:error, _} = error ->
          error
      end
    end
  end

  # ---- runtime ownership fence ----
  #
  # Same contract as the internal store (docs/salix/
  # rollout-concurrent-runner-fencing.md, D2; modeled in
  # tla/salix/SessionEpochFence.tla): check the freshly read record's
  # "runtime_epoch" against the node-local ownership cell and stamp the local
  # epoch into the CAS the update already performs. A regression is a
  # terminal :fenced; an absent cell stays unstamped and unfenced.

  defp fence_enforced?,
    do: Application.get_env(:salix_agent, :session_fence_enforce, true)

  # Same resolution contract as the internal store: the registered session
  # actor's own FROZEN epoch (its Registry value) wins over the mutable
  # node-wide cell, so a later same-node re-claim can never launder a stale
  # in-flight actor's writes as the new epoch's; an uncaptured actor freezes
  # the cell's claim at its first commit; non-actor seams use the cell.
  defp local_runtime_epoch(agent_id, session_id) do
    key = ExternalSessionActor.key(agent_id, session_id)

    case Registry.lookup(SalixAgent.Registry, key) do
      [{pid, %{runtime_epoch: captured}}] when pid == self() and is_integer(captured) ->
        actor_epoch_with_fence(agent_id, captured)

      [{pid, _}] when pid == self() ->
        # First ownership resolution: bind the actor's immutable generation
        # now, before its first durable write; an absent cell pins LEGACY
        # (epoch 0) permanently — same contract as the internal store.
        frozen =
          case SalixAgent.OwnershipCell.fetch(agent_id) do
            {:ok, epoch} -> epoch
            :fenced -> if fence_enforced?(), do: :fenced, else: 0
            :absent -> 0
          end

        case frozen do
          :fenced ->
            {:error, :fenced}

          frozen when is_integer(frozen) ->
            _ =
              Registry.update_value(SalixAgent.Registry, key, fn _ ->
                %{runtime_epoch: frozen}
              end)

            actor_epoch_with_fence(agent_id, frozen)
        end

      _ ->
        case SalixAgent.OwnershipCell.fetch(agent_id) do
          {:ok, epoch} ->
            {:ok, epoch}

          :fenced ->
            cond do
              not SalixAgent.Fleet.running?(agent_id) -> {:ok, nil}
              fence_enforced?() -> {:error, :fenced}
              true -> {:ok, nil}
            end

          :absent ->
            {:ok, nil}
        end
    end
  end

  # A fence at or above the actor's own epoch supersedes it; below it is
  # stale evidence about an earlier claim and is ignored.
  defp actor_epoch_with_fence(agent_id, captured) do
    case SalixAgent.OwnershipCell.entry(agent_id) do
      {:ok, fenced_epoch, :fenced} when fenced_epoch >= captured ->
        if fence_enforced?(), do: {:error, :fenced}, else: {:ok, captured}

      _ ->
        {:ok, captured}
    end
  end

  defp verify_runtime_epoch(agent_id, session_id, current) when is_map(current) do
    with {:ok, local_epoch} <- local_runtime_epoch(agent_id, session_id) do
      durable_epoch = normalize_runtime_epoch(current["runtime_epoch"])

      cond do
        not (is_integer(local_epoch) and durable_epoch > local_epoch) ->
          {:ok, local_epoch}

        fence_enforced?() ->
          already_fenced = SalixAgent.OwnershipCell.fetch(agent_id) == :fenced
          _ = SalixAgent.OwnershipCell.fence(agent_id, durable_epoch)

          unless already_fenced do
            _ =
              Task.Supervisor.start_child(SalixAgent.TaskSup, fn ->
                SalixAgent.Fleet.abort_agent_runtime(
                  agent_id,
                  durable_epoch,
                  :session_epoch_fenced
                )
              end)
          end

          {:error, :fenced}

        true ->
          CommaLog.log("session_fence_would_fence", %{
            agent_id: agent_id,
            durable_epoch: durable_epoch,
            local_epoch: local_epoch
          })

          {:ok, nil}
      end
    end
  end

  defp stamp_runtime_epoch(next, nil), do: next

  defp stamp_runtime_epoch(next, epoch) when is_map(next) and is_integer(epoch) do
    next
    |> Map.put("runtime_epoch", epoch)
    |> Map.put("runtime_node", to_string(node()))
  end

  defp normalize_runtime_epoch(epoch) when is_integer(epoch) and epoch >= 0, do: epoch
  defp normalize_runtime_epoch(_epoch), do: 0

  defp sync_work_index(agent_id, session_id, current, next, opts) do
    current_reasons = work_reasons(current)

    current_discovery =
      SessionWorkIndex.discovery_ref(
        agent_id,
        :external,
        session_id,
        current["work_index_token"],
        current_reasons,
        recovery_wait(current)
      )

    case work_reasons(next) do
      [] ->
        {:ok, Map.put(next, "work_index_token", nil),
         {:delete, agent_id, session_id, current["work_index_token"], current_discovery}}

      reasons ->
        workload_id =
          case get_in(next, ["runtime", "binding"]) do
            %{"kind" => "compute_workload", "workload_id" => id} -> id
            _ -> nil
          end

        with {:ok, %{"token" => token}} <-
               SessionWorkIndex.mark(agent_id, :external, session_id, reasons,
                 workload_id: workload_id,
                 device_runtime_id: get_in(next, ["runtime", "binding", "device_runtime_id"]),
                 cas_base: opts[:cas_base],
                 base_revision: opts[:base_revision],
                 recover_after_ms: SessionWorkIndex.recover_after_ms(reasons, recovery_wait(next))
               ) do
          {:ok, Map.put(next, "work_index_token", token), {:delete_discovery, current_discovery}}
        end
    end
  end

  defp cleanup_work_index({:delete, agent_id, session_id, token, discovery}) do
    case SessionWorkIndex.delete_if_token(agent_id, :external, session_id, token) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("external session work index cleanup failed: #{inspect(reason)}")
        :ok
    end

    cleanup_discovery(discovery, "external session #{agent_id}/#{session_id}")
  end

  defp cleanup_work_index({:delete_discovery, discovery}) do
    cleanup_discovery(discovery, "external session")
  end

  defp cleanup_work_index(:none), do: :ok

  defp cleanup_uncommitted_work_index(agent_id, session_id, state) do
    case SessionWorkIndex.discard_uncommitted(
           agent_id,
           :external,
           session_id,
           state["work_index_token"],
           work_reasons(state),
           recovery_wait(state)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "external session #{agent_id}/#{session_id} uncommitted work index cleanup failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp cleanup_discovery(discovery, label) do
    case SessionWorkIndex.delete_discovery(discovery) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("#{label} work discovery cleanup failed: #{inspect(reason)}")
        :ok
    end
  end

  # Lifecycle writability: the capability escape lets IN-FLIGHT connector
  # settlement and session lifecycle operations (begin/accept, event
  # commits, connector-event settlement — every caller below) finish their
  # work on a session whose agent-side binding has drifted; the minted
  # capability marks that attachment.
  defp ensure_writable(state, current_runtime) do
    stored = stable_binding(get_in(state, ["runtime", "binding"]) || %{})
    current = stable_binding(current_runtime)

    cond do
      stored == current -> :ok
      migration_committed_binding?(state, current_runtime) -> :ok
      present?(state["runtime_capability_token_hash"]) -> :ok
      true -> {:error, :external_session_read_only}
    end
  end

  # NEW-INPUT admission (#873 round 9, refined by the rollout contract):
  # the boundary between the two shipped contracts is the agent's CURRENT
  # runtime kind.
  #
  #   * ROLLOUT window (the agent still runs an EXTERNAL runtime, its
  #     record retargeted to a new binding): an ACTIVE pinned session —
  #     capability minted, still attached to its old binding — keeps
  #     accepting new input until it finishes there. This is the
  #     first-party rollout contract (SalixWeb.ExternalRuntimeTest:
  #     "rollout sends only new Sessions to the new target while an
  #     active Session stays pinned") and comma-31 principle 5.
  #   * The agent LEFT the external runtime entirely (flip to internal):
  #     no runtime will ever run this session's new input — only
  #     committed ids keep acking as duplicates (the ledger answers
  #     before this check); a NEW id refuses read_only (round-9 P1-2:
  #     the unscoped capability escape admitted these too).
  # Which admission contract applies is decided by what the delivery IS,
  # not by who called: a `wait_timeout` entry is the settlement of an
  # in-flight wait THIS session armed (`Waits.timeout_delivery/2`), so it
  # follows the lifecycle contract — refusing it would strand the wait and
  # leave the session waiting forever. Everything else is new input.
  defp ensure_admissible(state, current_runtime, delivery) do
    if value(delivery_payload(delivery), "kind") == "wait_timeout",
      do: ensure_writable(state, current_runtime),
      else: ensure_new_input_admissible(state, current_runtime)
  end

  defp ensure_new_input_admissible(state, current_runtime) do
    stored = stable_binding(get_in(state, ["runtime", "binding"]) || %{})

    with :ok <- provider_cutover_input_allowed(state, current_runtime) do
      cond do
        stored == stable_binding(current_runtime) ->
          :ok

        migration_committed_binding?(state, current_runtime) ->
          :ok

        AgentControl.external_runtime?(%{"runtime_config" => current_runtime}) and
            present?(state["runtime_capability_token_hash"]) ->
          :ok

        true ->
          {:error, :external_session_read_only}
      end
    end
  end

  # Group start uses this same lock. It cannot pass its quiet-work check while
  # a delivery is between its work-index update and the Session CAS.
  defp with_group_provider_admission(%{"group_id" => group}, fun) when is_binary(group) do
    SalixStore.Repo.transaction(fn ->
      case SalixStore.Repo.query(
             "SELECT pg_try_advisory_xact_lock(hashtext($1))",
             ["group-provider-migration:" <> group]
           ) do
        {:ok, %{rows: [[true]]}} -> fun.()
        {:ok, _} -> {:error, :provider_migration_busy}
        {:error, _} -> {:error, :group_workload_unavailable}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} -> {:error, :group_workload_unavailable}
    end
  end

  defp with_group_provider_admission(_agent, fun), do: fun.()

  defp provider_cutover_birth_allowed(%{
         "tenant_id" => tenant,
         "group_id" => group,
         "runtime_config" => %{"kind" => "connected_runtime", "device_id" => device} = runtime
       }) do
    case Compute.group_provider_ownership(tenant, group) do
      {:managed,
       %{
         "device_id" => ^device,
         "provider" => "cloudflare",
         "provider_migration" => %{"phase" => "committed"}
       }} ->
        with :ok <- Compute.group_provider_mutation_admission(tenant, group, device),
             {:ok, _} <-
               RuntimeEnvironment.resolve_external_runtime_binding(runtime, tenant, group) do
          :ok
        end

      {:managed, %{"device_id" => ^device, "provider_migration" => migration}}
      when is_map(migration) ->
        if migration["phase"] == "cancelled",
          do: :ok,
          else: {:error, :provider_migration_in_progress}

      {:managed, _} ->
        :ok

      :unmanaged ->
        :ok

      {:error, _} ->
        {:error, :group_workload_unavailable}
    end
  end

  defp provider_cutover_birth_allowed(_agent), do: :ok

  defp provider_cutover_input_allowed(
         %{
           "tenant_id" => tenant,
           "group_id" => group,
           "runtime" => %{"binding" => %{"kind" => "connected_runtime", "device_id" => device}}
         } = state,
         current_runtime
       ) do
    case Compute.group_provider_ownership(tenant, group) do
      {:managed, %{"device_id" => ^device, "provider_migration" => migration}}
      when is_map(migration) ->
        marker = state["migration"] || %{}

        cond do
          migration["phase"] == "cancelled" ->
            :ok

          marker["operation_id"] == migration["operation"] and
              marker["phase"] in ~w(provider_cutover_parked provider_cutover_committed committed) ->
            :ok

          migration["phase"] == "committed" and
              stable_binding(get_in(state, ["runtime", "binding"]) || %{}) ==
                stable_binding(current_runtime) ->
            :ok

          true ->
            {:error, :provider_cutover_session_not_migrated}
        end

      {:managed, _} ->
        :ok

      :unmanaged ->
        :ok

      {:error, _} ->
        {:error, :group_workload_unavailable}
    end
  end

  defp provider_cutover_input_allowed(_state, _current_runtime), do: :ok

  defp migration_committed_binding?(state, runtime) do
    case state["migration"] do
      %{"phase" => "committed", "source" => source, "target" => target} ->
        AgentControl.external_runtime?(%{"runtime_config" => runtime}) and
          get_in(state, ["runtime", "binding"]) == exact_binding(target) and
          case AgentControl.get_record(state["agent_id"]) do
            {:ok, %{"session_admission" => %{"kind" => "migration", "operation_id" => operation}}} ->
              operation == state["migration"]["operation_id"]

            _ ->
              stable_binding(runtime) == stable_binding(source)
          end

      _ ->
        false
    end
  end

  defp exact_binding(runtime),
    do: runtime |> Map.take(@stable_binding_fields ++ @session_config_fields) |> compact()

  defp stable_binding(runtime), do: runtime |> Map.take(@stable_binding_fields) |> compact()

  defp canonicalize_runtime(state, _current_runtime) do
    put_in(state, ["runtime", "binding"], exact_binding(get_in(state, ["runtime", "binding"])))
  end

  # The delivery-level stable source id is the dedupe grain — the same grain
  # as the retired inbox create-once object and the `deliver/3` retry
  # contract. The canonical fallback for the public runtime ingress (which
  # accepts payload-level identity) is the MAIN payload's stable id; a
  # delivery carrying no stable id anywhere is REJECTED before any
  # state/status write — an unledgered append would reintroduce the
  # at-least-once hole this ledger closes (review round 2, finding 1).
  defp require_ledger_source_id(delivery) do
    payload = delivery_payload(delivery)

    id =
      first_present([
        value(delivery, "source_message_id"),
        value(payload, "source_message_id"),
        value(payload, "runtime_message_id"),
        value(payload, "dedupe_key")
      ])

    case id do
      nil ->
        {:error,
         {:bad_request,
          "external delivery requires a stable source_message_id (or runtime_message_id/dedupe_key)"}}

      id ->
        {:ok, id}
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn v ->
      case trim(v) do
        "" -> nil
        present -> present
      end
    end)
  end

  # No nil clauses: require_ledger_source_id/1 guarantees a stable id before
  # any of these run — an unledgered append must be impossible, not silent.
  defp dedupe_member?(state, source_id) when is_binary(source_id),
    do: source_id in List.wrap(state["input_dedupe"])

  defp record_dedupe(state, source_id) when is_binary(source_id),
    do: Map.put(state, "input_dedupe", List.wrap(state["input_dedupe"]) ++ [source_id])

  # Bounded admission (docs/salix/conversation-owner-actor.md): refuse before
  # the CAS so a saturated delivery writes nothing — the caller retries with
  # the same source id. The whole atomic batch counts (pre_deliveries plus
  # the delivery itself); duplicate wins over saturated upstream.
  defp input_queue_saturated?(state, delivery) do
    limit = Application.get_env(:salix_agent, :session_input_queue_limit, 1000)

    length(List.wrap(state["input_message_queue"])) + length(delivery_payloads(delivery)) >
      limit
  end

  defp enqueue(state, delivery, committed_floor) do
    queue = List.wrap(state["input_message_queue"])
    floor = queue_floor(queue, committed_floor)

    {items, _floor} =
      Enum.map_reduce(delivery_payloads(delivery), floor, fn payload, floor ->
        id = ULID.generate(floor)
        {input_message(payload, id), id}
      end)

    state
    |> Map.put("input_message_queue", queue ++ items)
    |> clear_wait_for_input(items)
  end

  defp clear_wait_for_input(state, messages) do
    if Enum.any?(messages, &wakeable_input?/1),
      do: Map.put(state, "wait", nil),
      else: state
  end

  defp wakeable_input?(message),
    do: message["role"] in ["summary", "user", "runtime"] and message["no_wake"] != true

  defp input_message(payload, id) do
    role = value(payload, "role")
    decoded = runtime_content(payload)

    %{
      "id" => id,
      "role" => role,
      "content" => value(payload, "content") || decoded["summary"],
      "source_message_id" => value(payload, "source_message_id"),
      "input_time" => value(payload, "input_time"),
      "delivered_at_ms" => value(payload, "delivered_at_ms"),
      "no_wake" => value(payload, "no_wake") == true,
      "created_at" => value(payload, "created_at") || now()
    }
    |> maybe_put_trusted_origin(payload)
    |> maybe_merge_runtime_fields(payload, decoded, role)
    |> compact()
  end

  defp maybe_put_trusted_origin(message, payload) do
    trusted_origin = value(payload, "trusted_origin")

    source_message_ids =
      payload
      |> value("trusted_origin_source_message_ids")
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    message =
      if is_map(trusted_origin) do
        message
        |> Map.put("trusted_origin", trusted_origin)
        |> maybe_put(
          "trusted_origin_source_message_ids",
          source_message_ids,
          source_message_ids != []
        )
      else
        message
      end

    if message["role"] == "runtime",
      do: SalixAgent.ToolCallProvenance.inherit(message, payload),
      else: message
  end

  defp maybe_merge_runtime_fields(message, payload, decoded, "runtime") do
    Map.merge(message, %{
      "kind" => "runtime_message",
      "runtime_message_id" =>
        value(payload, "runtime_message_id") || value(payload, "source_message_id") ||
          value(payload, "dedupe_key"),
      "type" => value(payload, "runtime_message_type") || decoded["type"],
      "summary" => value(payload, "summary") || decoded["summary"],
      "source_tool_call_id" => value(payload, "source_tool_call_id"),
      "wait_id" => value(payload, "wait_id") || decoded["wait_id"],
      "reason" => value(payload, "reason") || decoded["reason"],
      "timeout_seconds" => value(payload, "timeout_seconds") || decoded["timeout_seconds"],
      "deadline_ms" => value(payload, "deadline_ms") || decoded["deadline_ms"],
      "elapsed_ms" => value(payload, "elapsed_ms") || decoded["elapsed_ms"],
      "overdue_ms" => value(payload, "overdue_ms") || decoded["overdue_ms"],
      "source" => value(payload, "source") || decoded["source"],
      "source_refs" => value(payload, "source_refs") || decoded["source_refs"]
    })
  end

  defp maybe_merge_runtime_fields(message, _payload, _decoded, _role), do: message

  defp put_metadata(state, payload) do
    Enum.reduce(@metadata_fields, state, fn key, acc ->
      maybe_put(acc, key, value(payload, key))
    end)
  end

  defp event_records(agent_id, session_id, events, floor) do
    Enum.map_reduce(events, floor, fn
      %{"type" => "delivery"}, current ->
        {nil, current}

      event, current ->
        id = ULID.generate(current)

        {%{
           "id" => id,
           "agent_id" => agent_id,
           "session_id" => session_id,
           "type" => "session." <> to_string(event["type"] || "event"),
           "data" => drop_trusted_origin(event),
           "created_at" => event["created_at"] || now()
         }, id}
    end)
    |> then(fn {records, last} -> {Enum.reject(records, &is_nil/1), last} end)
  end

  defp status_projection_record(records) do
    Enum.find(Enum.reverse(records), fn record ->
      record["type"] in ["session.wait_set", "session.wait_clear"]
    end)
  end

  defp put_status_projection_target(state, nil), do: state

  defp put_status_projection_target(state, record) do
    # Modeled in tla/salix/ExternalRuntimeToolWake.tla and
    # ExternalRuntimeEventProjection.tla. Lifecycle records may advance the
    # general projection target without certifying an older wait projection,
    # so retain the latest wait-record watermark independently.
    target =
      state
      |> Map.get("status_projection_target", %{})
      |> Map.take(
        ~w(dispatch_id execution_id connector_run_id record_floor source_message_ids updated_at wait_watermark)
      )
      |> Map.put("watermark", record["id"])
      |> Map.put_new("updated_at", record["created_at"] || now())
      |> maybe_put_wait_projection_target(record)

    target =
      case record do
        %{"type" => "runtime.event", "data" => %{"event" => event}} ->
          Map.merge(target, Map.take(event, ~w(dispatch_id execution_id)))

        _other ->
          target
      end

    Map.put(state, "status_projection_target", target)
  end

  defp maybe_put_wait_projection_target(target, %{
         "type" => type,
         "id" => watermark
       })
       when type in ["session.wait_set", "session.wait_clear"] and is_binary(watermark),
       do: Map.put(target, "wait_watermark", watermark)

  defp maybe_put_wait_projection_target(target, _record), do: target

  defp runtime_event_record(agent_id, session_id, attrs, floor) do
    event = value(attrs, "event") || %{}

    %{
      "id" => value(attrs, "event_id") || ULID.generate(floor),
      "agent_id" => agent_id,
      "session_id" => session_id,
      "type" => "runtime.event",
      "data" =>
        %{
          "event" => event,
          "connector_run_id" => value(attrs, "connector_run_id"),
          "model" => value(attrs, "model"),
          "usage" => value(attrs, "usage") || event["usage"]
        }
        |> compact(),
      "created_at" => event["created_at"] || now()
    }
  end

  defp input_record(agent_id, session_id, %{"id" => id} = message) do
    %{
      "id" => id,
      "agent_id" => agent_id,
      "session_id" => session_id,
      "type" => "message",
      "data" => drop_trusted_origin(message),
      "created_at" => message["created_at"] || now()
    }
  end

  defp apply_events(state, events, floor) do
    Enum.reduce(events, state, &apply_event(&2, &1, floor))
  end

  defp apply_event(state, %{"type" => "delivery"} = event, floor),
    do: enqueue(state, %{"payload" => event}, floor)

  defp apply_event(state, %{"type" => "wait_set", "wait" => wait}, _floor) when is_map(wait),
    do: Map.put(state, "wait", wait)

  defp apply_event(state, %{"type" => "wait_clear"}, _floor), do: Map.put(state, "wait", nil)

  defp apply_event(state, %{"type" => "async_tool_call_started"} = event, _floor),
    do: put_async_call(state, event["tool_call_id"], Map.put_new(event, "status", "running"))

  defp apply_event(state, %{"type" => "async_tool_call_progress"} = event, _floor) do
    update_async_call(state, event["tool_call_id"], fn current ->
      if terminal_async?(current["status"]),
        do: current,
        else:
          current |> Map.put("progress", event["progress"] || %{}) |> Map.put("updated_at", now())
    end)
  end

  defp apply_event(state, %{"type" => type} = event, _floor)
       when type in ["async_tool_call_completed", "async_tool_call_failed"] do
    update_async_call(state, event["tool_call_id"], fn current ->
      if terminal_async?(current["status"]) do
        current
      else
        current
        |> Map.merge(
          Map.take(event, ~w(result error error_class error_message duration_ms completed_at))
        )
        |> Map.put(
          "status",
          if(type == "async_tool_call_failed", do: "failed", else: "completed")
        )
        |> Map.put_new("completed_at", now())
      end
    end)
  end

  defp apply_event(state, %{"type" => "async_tool_call_cancelled"} = event, _floor) do
    update_async_call(state, event["tool_call_id"], fn current ->
      if terminal_async?(current["status"]),
        do: current,
        else:
          current
          |> Map.put("status", "cancelled")
          |> Map.put("cancelled_at", event["cancelled_at"] || now())
          |> maybe_put("cancel_reason", event["cancel_reason"])
    end)
  end

  defp apply_event(state, _event, _floor), do: state

  defp put_async_call(state, tool_call_id, call) do
    tool_call_id = trim(tool_call_id)

    if tool_call_id == "" do
      state
    else
      call =
        Map.take(
          call,
          ~w(tool_call_id tool_name input status completion_mode started_at auto_wait_seconds trusted_origin trusted_origins trusted_origin_source_message_ids)
        )

      update_in(state, ["async_tool_calls"], fn calls ->
        calls = calls || %{}

        case Map.get(calls, tool_call_id) do
          %{"status" => status} when status in ["completed", "failed", "cancelled"] ->
            # Modeled in tla/salix/ExternalRuntimeToolWake.tla. Replayed or
            # late handoff starts cannot resurrect an exact durable terminal.
            calls

          _current ->
            Map.put(calls, tool_call_id, call)
        end
      end)
    end
  end

  defp update_async_call(state, tool_call_id, fun) do
    tool_call_id = trim(tool_call_id)

    if tool_call_id == "" do
      state
    else
      update_in(state, ["async_tool_calls"], fn calls ->
        calls = calls || %{}

        Map.put(
          calls,
          tool_call_id,
          fun.(Map.get(calls, tool_call_id, %{"tool_call_id" => tool_call_id}))
        )
      end)
    end
  end

  defp terminal_async?(status), do: status in ["completed", "failed", "cancelled"]

  defp async_work_reasons(calls) when is_map(calls) do
    calls
    |> Map.values()
    |> Enum.flat_map(fn
      %{"status" => "running", "completion_mode" => "external_callback"} ->
        ["external_callback_tool_call"]

      %{"status" => :running, "completion_mode" => "external_callback"} ->
        ["external_callback_tool_call"]

      %{"status" => "running"} ->
        ["process_local_background_tool_run"]

      %{"status" => :running} ->
        ["process_local_background_tool_run"]

      _ ->
        []
    end)
  end

  defp async_work_reasons(_calls), do: []

  defp maybe_add_work_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_work_reason(reasons, false, _reason), do: reasons

  defp commit_status_record(agent_id, session_id, event, records, opts) do
    with {:ok, state} <- get_session_record(agent_id, session_id),
         {event_records, _floor} <-
           event_records(agent_id, session_id, [event], record_floor(state, records)),
         [record] = event_records,
         {:ok, records, _statuses} <-
           ExternalSessionRecords.append(agent_id, session_id, records, event_records),
         {:ok, state} <-
           update_state(agent_id, session_id, fn current ->
             next =
               current
               |> maybe_retire_triage_provenance(
                 state,
                 event,
                 Keyword.get(opts, :retire_triage, false)
               )
               |> put_status_projection_target(record)

             {:ok, next}
           end) do
      {:ok, state, record, records}
    end
  end

  defp maybe_commit_events(_agent_id, _session_id, state, [], records),
    do: {:ok, state, records}

  defp maybe_commit_events(agent_id, session_id, _state, events, records),
    do: commit_session_events(agent_id, session_id, events, records)

  defp maybe_add_status_event(events, attrs) do
    case value(attrs, "status") || value(attrs, "activity_status") do
      nil ->
        events

      status ->
        events ++ [%{"type" => "status", "state" => to_string(status), "created_at" => now()}]
    end
  end

  defp maybe_add_error_event(events, attrs) do
    case value(attrs, "last_error") do
      nil ->
        events

      error ->
        events ++ [%{"type" => "error", "message" => format_error(error), "created_at" => now()}]
    end
  end

  defp validate_delivery_payloads(payloads) do
    cond do
      Enum.any?(payloads, &(trim(value(&1, "role")) == "")) -> @delivery_role_required
      Enum.any?(payloads, &runtime_identity_missing?/1) -> @runtime_identity_required
      Enum.any?(payloads, &runtime_kind_invalid?/1) -> @runtime_kind_invalid
      Enum.any?(payloads, &runtime_type_missing?/1) -> @runtime_type_required
      true -> :ok
    end
  end

  defp validate_wait_events(events) do
    Enum.reduce_while(events, :ok, fn
      %{"type" => "wait_set", "wait" => wait}, :ok ->
        case Waits.validate(wait) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      %{"type" => "wait_set"}, :ok ->
        {:halt, {:error, :invalid_wait}}

      _event, :ok ->
        {:cont, :ok}
    end)
  end

  defp runtime_identity_missing?(payload) do
    value(payload, "role") == "runtime" and
      Enum.all?(
        ~w(source_message_id runtime_message_id dedupe_key),
        &(trim(value(payload, &1)) == "")
      )
  end

  defp runtime_kind_invalid?(payload) do
    value(payload, "role") == "runtime" and
      trim(value(payload, "kind")) not in ["", "runtime_message", "wait_timeout"]
  end

  defp runtime_type_missing?(payload) do
    value(payload, "role") == "runtime" and
      trim(value(payload, "runtime_message_type") || runtime_content(payload)["type"]) == ""
  end

  defp validate_snapshot(queue, snapshot) do
    if snapshot_prefix?(queue, snapshot) and Enum.all?(snapshot, &valid_queue_item?/1),
      do: :ok,
      else: {:error, :stale_external_runtime_session}
  end

  defp snapshot_prefix?(queue, snapshot) do
    Enum.map(Enum.take(List.wrap(queue), length(snapshot)), & &1["id"]) ==
      Enum.map(snapshot, & &1["id"])
  end

  defp valid_queue_item?(%{"id" => id}), do: ULID.valid?(id)
  defp valid_queue_item?(_), do: false

  defp normalize_delivery(delivery) do
    payload = delivery_payload(delivery)
    put_delivery_payload(delivery, normalize_payload(payload))
  end

  defp normalize_events(events) do
    Enum.map(events, fn event ->
      event = stringify_keys(event)
      if event["type"] == "delivery", do: normalize_payload(event), else: event
    end)
  end

  defp normalize_payload(payload) do
    payload = stringify_keys(payload)

    pre_deliveries =
      payload |> Map.get("pre_deliveries", []) |> List.wrap() |> Enum.map(&normalize_payload/1)

    payload
    |> Map.put("pre_deliveries", pre_deliveries)
    |> maybe_decode_runtime_content()
  end

  defp maybe_decode_runtime_content(%{"role" => "runtime"} = payload),
    do: Map.put_new(payload, "__runtime_content", decode_runtime_content(payload["content"]))

  defp maybe_decode_runtime_content(payload), do: payload

  defp runtime_content(payload) do
    case value(payload, "__runtime_content") do
      %{} = decoded -> decoded
      _ -> decode_runtime_content(value(payload, "content"))
    end
  end

  defp decode_runtime_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_runtime_content(_), do: %{}

  defp delivery_payloads(delivery) do
    payload = delivery_payload(delivery)
    source_message_id = value(delivery, "source_message_id")

    List.wrap(value(payload, "pre_deliveries")) ++
      [Map.put_new(payload, "source_message_id", source_message_id)]
  end

  defp delivery_payload(delivery), do: value(delivery, "payload") || %{}

  defp put_delivery_payload(delivery, payload) do
    cond do
      Map.has_key?(delivery, "payload") -> Map.put(delivery, "payload", payload)
      Map.has_key?(delivery, :payload) -> Map.put(delivery, :payload, payload)
      true -> Map.put(delivery, "payload", payload)
    end
  end

  defp delivery_session_id(delivery) do
    case trim(value(delivery_payload(delivery), "session_id")) do
      "" ->
        {:error, :missing_session_id}

      session_id ->
        if Ids.valid_session_id?(session_id),
          do: {:ok, session_id},
          else: {:error, :invalid_session_id}
    end
  end

  defp record_floor(state, records) do
    queue_floor(List.wrap(state["input_message_queue"]), records.last_id)
  end

  # Prepared notices already own their IDs even before Connector acceptance.
  # Reserve them for every allocator that shares the SessionRecord namespace.
  defp queue_floor(queue, committed_floor) do
    Enum.reduce(queue, committed_floor, fn item, floor ->
      prepared = get_in(item, ["do_not_send_to_llm", "prepared_activation", "messages"]) || []
      Enum.reduce(prepared, max_ulid(floor, item["id"]), &max_ulid(&1["id"], &2))
    end)
  end

  defp max_ulid(nil, right), do: right
  defp max_ulid(left, nil), do: left
  defp max_ulid(left, right), do: max(left, right)

  defp message_records(records) do
    Enum.flat_map(records, fn
      %{"type" => "message", "data" => %{} = message} -> [message]
      _ -> []
    end)
  end

  defp list_states(agent_id) do
    prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)

    with {:ok, objects} <- S3.list_all(prefix, delimiter: "/") do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, states} ->
        if state_key?(prefix, key) do
          case get_record(key) do
            {:ok, state} -> {:cont, {:ok, [state | states]}}
            {:error, _} = error -> {:halt, error}
          end
        else
          {:cont, {:ok, states}}
        end
      end)
      |> then(fn
        {:ok, states} -> {:ok, Enum.reverse(states)}
        error -> error
      end)
    end
  end

  defp state_key?(prefix, key) do
    session_id = key |> String.replace_prefix(prefix, "") |> String.trim_trailing(".json")
    String.ends_with?(key, ".json") and Ids.valid_session_id?(session_id)
  end

  defp session_summary(agent, state) do
    binding = get_in(state, ["runtime", "binding"]) || %{}
    status = session_status(agent, state)

    state
    |> Map.update("wait", nil, &drop_trusted_origin/1)
    |> Map.take(
      @metadata_fields ++
        ~w(tenant_id group_id agent_id session_id message_count created_at updated_at wait)
    )
    |> Map.merge(Map.take(binding, @stable_binding_fields ++ @session_config_fields))
    |> Map.put("runtime_kind", "external")
    |> Map.put(
      "runtime_provider",
      binding["provider"] || get_in(agent, ["runtime_config", "provider"])
    )
    |> Map.merge(
      Map.take(
        status,
        ~w(status status_updated_at activity_revision issue message wait runtime_availability)
      )
    )
    |> Map.put("activity_status", status["status"])
    |> compact()
  end

  defp session_status(agent, state) do
    availability = runtime_availability(agent, state)

    status =
      case ExternalSessionStatus.get(agent["agent_id"], state["session_id"]) do
        {:ok, status} ->
          case state["status_projection_target"] do
            target when is_map(target) ->
              if status_projection_current?(status, target) do
                status
              else
                ExternalSessionStatus.unknown(
                  state["session_id"],
                  target["updated_at"] || state["updated_at"] || 0
                )
              end

            _current ->
              status
          end

        {:error, _} ->
          ExternalSessionStatus.unknown(state["session_id"], state["created_at"] || 0)
      end

    ExternalSessionStatus.public(status, availability)
  end

  defp read_session_status(agent, state) do
    with {:ok, status} <- ExternalSessionStatus.get(agent["agent_id"], state["session_id"]),
         true <- status_projection_current?(status, state["status_projection_target"]),
         {:ok, availability} when is_map(availability) <-
           read_runtime_availability(agent, state) do
      {:ok, ExternalSessionStatus.public(status, availability)}
    else
      false -> {:error, :session_status_projection_stale}
      {:ok, _invalid_availability} -> {:error, :runtime_availability_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp status_projection_current?(_status, target) when not is_map(target), do: true

  defp status_projection_current?(status, target) do
    (not present?(target["watermark"]) or
       (present?(status["projection_watermark"]) and
          target["watermark"] <= status["projection_watermark"])) and
      (not present?(target["wait_watermark"]) or
         (present?(status["wait_projection_watermark"]) and
            target["wait_watermark"] <= status["wait_projection_watermark"])) and
      (not present?(target["dispatch_id"]) or target["dispatch_id"] == status["dispatch_id"]) and
      (not present?(target["execution_id"]) or
         target["execution_id"] == status["execution_id"])
  end

  defp runtime_availability(agent, state) do
    case read_runtime_availability(agent, state) do
      {:ok, status} when is_map(status) -> status
      {:error, _} -> %{"status" => "unknown"}
    end
  end

  defp read_runtime_availability(agent, state) do
    binding = get_in(state, ["runtime", "binding"]) || %{}

    RuntimeEnvironment.external_runtime_binding_status(
      binding,
      agent["tenant_id"],
      agent["group_id"]
    )
  end

  defp search_session(agent_id, session_id, query) do
    with {:ok, records} <- ExternalSessionRecords.load(agent_id, session_id),
         {:ok, all} <- ExternalSessionRecords.all(agent_id, session_id, records) do
      all
      |> message_records()
      |> Enum.flat_map(fn message ->
        content = stringify_content(message["content"])

        if query != "" and String.contains?(String.downcase(content), query) do
          [
            %{
              "message_id" => message["id"],
              "role" => message["role"],
              "session_id" => session_id,
              "created_at" => message["created_at"] || 0,
              "snippet" => content,
              "score" => 1
            }
          ]
        else
          []
        end
      end)
    else
      _ -> []
    end
  end

  defp session_runtime_capability(agent, session_id, runtime, resolved, state) do
    case trim(state["runtime_capability_token"]) do
      "" ->
        with {:ok, capability} <-
               create_runtime_capability(
                 agent,
                 session_id,
                 Map.take(
                   resolved,
                   ~w(kind stable_target_id connection_epoch connector_run_id device_runtime_id workload_id runtime_instance_id)
                 )
               ),
             {:ok, state} <-
               update_state(agent["agent_id"], session_id, fn current ->
                 with :ok <- migration_dispatch_allowed(current),
                      :ok <- ensure_writable(current, runtime) do
                   {:ok,
                    current
                    |> canonicalize_runtime(runtime)
                    |> Map.put("runtime_capability_token", capability["token"])
                    |> Map.put("runtime_capability_token_hash", capability["token_hash"])
                    |> Map.put("updated_at", now())}
                 end
               end) do
          {:ok, capability, state}
        end

      token ->
        with true <- state["runtime_capability_token_hash"] == token_hash(token),
             {:ok, capability} <- validate_runtime_capability(token) do
          cond do
            capability_target_current?(capability, resolved) ->
              {:ok, Map.put(capability, "token", token), state}

            capability["target_kind"] == "connected_runtime" and
                capability_stable_target?(capability, resolved) ->
              {:ok, Map.put(capability, "token", token), state}

            capability_stable_target?(capability, resolved) ->
              rotate_runtime_capability(agent, session_id, runtime, resolved, capability)

            true ->
              {:error, :active_session_target_changed}
          end
        else
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp rotate_runtime_capability(agent, session_id, runtime, resolved, previous) do
    with {:ok, capability} <-
           create_runtime_capability(
             agent,
             session_id,
             Map.take(
               resolved,
               ~w(kind stable_target_id connection_epoch connector_run_id device_runtime_id workload_id runtime_instance_id)
             )
           ),
         {:ok, state} <-
           update_state(agent["agent_id"], session_id, fn current ->
             if current["runtime_capability_token_hash"] == previous["token_hash"] do
               {:ok,
                current
                |> canonicalize_runtime(runtime)
                |> Map.put("runtime_capability_token", capability["token"])
                |> Map.put("runtime_capability_token_hash", capability["token_hash"])
                |> Map.put("updated_at", now())}
             else
               {:error, :stale_external_runtime_session}
             end
           end) do
      _ = revoke_runtime_capability_by_hash(previous["token_hash"])
      {:ok, capability, state}
    end
  end

  defp create_runtime_capability(agent, session_id, attrs) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, target_kind} <- required_string(attrs, "kind"),
         {:ok, stable_target_id} <- required_string(attrs, "stable_target_id"),
         {:ok, expires_at} <- capability_expires_at(attrs["expires_in_seconds"]) do
      raw = "salix_runtime_" <> random_id()
      hash = token_hash(raw)
      timestamp = now()

      capability =
        %{
          "token_hash" => hash,
          "tenant_id" => agent["tenant_id"],
          "group_id" => agent["group_id"],
          "agent_id" => agent["agent_id"],
          "session_id" => session_id,
          "target_kind" => target_kind,
          "stable_target_id" => stable_target_id,
          "llm_allowed" => attrs["llm_allowed"] == true,
          "created_at" => timestamp
        }
        |> maybe_put("connection_epoch", attrs["connection_epoch"])
        |> maybe_put("connector_run_id", attrs["connector_run_id"])
        |> maybe_put("device_runtime_id", attrs["device_runtime_id"])
        |> maybe_put("workload_id", attrs["workload_id"])
        |> maybe_put("runtime_instance_id", attrs["runtime_instance_id"])
        |> maybe_put("expires_at", expires_at)

      case S3.put(Keys.ctl_runtime_capability(hash), Jason.encode!(capability),
             if_none_match: "*"
           ) do
        {:ok, _} -> {:ok, capability |> Map.put("token", raw)}
        {:error, :precondition_failed} -> {:error, :capability_conflict}
        {:error, _} = error -> error
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  defp capability_target_current?(capability, resolved) do
    capability["target_kind"] == resolved["kind"] and
      capability["stable_target_id"] == resolved["stable_target_id"] and
      capability["connection_epoch"] == resolved["connection_epoch"] and
      capability["connector_run_id"] == resolved["connector_run_id"] and
      capability["runtime_instance_id"] == resolved["runtime_instance_id"]
  end

  defp capability_stable_target?(capability, resolved) do
    capability["target_kind"] == resolved["kind"] and
      capability["stable_target_id"] == resolved["stable_target_id"] and
      capability["runtime_instance_id"] == resolved["runtime_instance_id"]
  end

  defp runtime_capability_current?(
         %{
           "token_hash" => token_hash
         } = capability
       ) do
    with true <- trim(token_hash) != "",
         {:ok, _state, _agent} <- current_capability_session(capability) do
      :ok
    else
      false -> {:error, :unauthorized}
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  defp runtime_capability_current?(_), do: {:error, :unauthorized}

  defp current_capability_session(%{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "token_hash" => token_hash
       }) do
    with {:ok, state} <- lookup_capability_session(agent_id, session_id),
         :ok <- validate_capability_session_token(state, token_hash),
         {:ok, %{"runtime_config" => runtime} = agent} <- lookup_capability_agent(agent_id),
         :ok <- ensure_writable(state, runtime) do
      {:ok, state, agent}
    end
  end

  defp lookup_capability_session(agent_id, session_id) do
    case get_session_record(agent_id, session_id) do
      {:ok, state} -> {:ok, state}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, {:external_session_lookup_failed, reason}}
    end
  end

  defp validate_capability_session_token(state, token_hash) do
    if state["runtime_capability_token_hash"] == token_hash,
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp lookup_capability_agent(agent_id) do
    case AgentControl.get_record(agent_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, {:external_agent_lookup_failed, reason}}
    end
  end

  defp validate_capability_transport(
         %{"device_runtime_id" => device_runtime_id} = capability,
         connector_run_id
       )
       when is_binary(device_runtime_id) and device_runtime_id != "" do
    with {:ok, state, agent} <- current_capability_session(capability),
         binding <- get_in(state, ["runtime", "binding"]) || %{},
         {:ok, availability} <- runtime_binding_status(binding, agent) do
      cond do
        availability["status"] in ~w(disconnected missing unknown) ->
          {:error, :unauthorized}

        trim(availability["device_runtime_id"]) != trim(device_runtime_id) ->
          {:error, :unauthorized}

        trim(availability["connector_run_id"]) != trim(connector_run_id) ->
          {:error, :stale_connector_transport_generation}

        true ->
          :ok
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  defp validate_capability_transport(capability, connector_run_id) do
    if trim(capability["connector_run_id"]) == trim(connector_run_id),
      do: :ok,
      else: {:error, :stale_connector_transport_generation}
  end

  defp runtime_binding_status(binding, agent) do
    case RuntimeEnvironment.external_runtime_binding_status(
           binding,
           agent["tenant_id"],
           agent["group_id"]
         ) do
      {:ok, availability} -> {:ok, availability}
      {:error, reason} -> {:error, {:runtime_availability_lookup_failed, reason}}
    end
  end

  defp validate_capability_metadata(capability, meta) do
    cond do
      present?(meta["tenant_id"]) and meta["tenant_id"] != capability["tenant_id"] ->
        {:error, :unauthorized}

      present?(meta["group_id"]) and meta["group_id"] != capability["group_id"] ->
        {:error, :unauthorized}

      true ->
        :ok
    end
  end

  defp validate_runtime_event(%{"provider" => provider, "type" => type} = event)
       when provider in @external_runtime_providers do
    valid =
      case type do
        "message" -> event["role"] == "assistant" and Map.has_key?(event, "content")
        "thinking" -> Map.has_key?(event, "content")
        "operation" -> present?(event["name"])
        "status" -> present?(event["state"])
        "error" -> present?(event["message"])
        "usage" -> is_map(event["usage"])
        _ -> false
      end

    lifecycle_valid =
      case event["work_state"] do
        nil ->
          true

        state when state in ~w(running settled failed) ->
          present?(event["dispatch_id"]) and present?(event["execution_id"])

        _ ->
          false
      end

    if valid and lifecycle_valid and valid_terminal_detail?(event),
      do: :ok,
      else: {:error, {:bad_request, "invalid external runtime event shape"}}
  end

  defp validate_runtime_event(_),
    do: {:error, {:bad_request, "invalid external runtime event shape"}}

  defp valid_terminal_detail?(%{"issue" => issue, "work_state" => "failed", "message" => message})
       when issue in @terminal_issues and is_binary(message),
       do:
         String.valid?(message) and String.trim(message) != "" and byte_size(message) <= 300 and
           not Regex.match?(~r/[\x00-\x1F\x7F]/u, message)

  defp valid_terminal_detail?(%{"issue" => _issue}), do: false
  defp valid_terminal_detail?(_event), do: true

  defp validate_state(agent_id, session_id, state) do
    cond do
      state["agent_id"] != agent_id -> {:error, :session_agent_id_mismatch}
      state["session_id"] != session_id -> {:error, :session_id_mismatch}
      not is_map(get_in(state, ["runtime", "binding"])) -> {:error, :runtime_binding_missing}
      not is_list(state["input_message_queue"]) -> {:error, :input_message_queue_missing}
      not is_map(state["async_tool_calls"]) -> {:error, :async_tool_calls_missing}
      true -> :ok
    end
  end

  defp get_record(key) do
    with {:ok, %{body: body}} <- S3.get(key), do: Jason.decode(body)
  end

  defp trace_limit(nil), do: {:ok, @trace_limit_default}

  defp trace_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {value, ""} when value > 0 and value <= @trace_limit_max ->
        {:ok, value}

      {value, ""} when value > @trace_limit_max ->
        {:error, {:bad_request, "limit must be <= #{@trace_limit_max}"}}

      _ ->
        {:error, {:bad_request, "limit must be a positive integer"}}
    end
  end

  defp clamp(value, default, max) do
    case Integer.parse(to_string(value || default)) do
      {int, ""} when int > 0 -> min(int, max)
      _ -> default
    end
  end

  defp required_string(attrs, key) do
    case trim(value(attrs, key)) do
      "" -> {:error, {:bad_request, key <> " is required"}}
      string -> {:ok, string}
    end
  end

  defp capability_expires_at(nil), do: {:ok, nil}
  defp capability_expires_at(""), do: {:ok, nil}

  defp capability_expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, now() + seconds}

  defp capability_expires_at(_),
    do: {:error, {:bad_request, "expires_in_seconds must be a positive integer"}}

  defp token_expired?(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: expires_at <= now()

  defp token_expired?(_), do: false

  defp public_state(state) do
    state
    # input_dedupe is the internal, permanently growing delivery ledger
    # (#870) — never part of the public runtime projection.
    |> Map.drop(~w(runtime_capability_token active_external_trusted_origins input_dedupe))
    |> Map.update(
      "input_message_queue",
      [],
      &Enum.map(&1, fn message -> drop_trusted_origin(message) end)
    )
    |> Map.update("wait", nil, &drop_trusted_origin/1)
    |> Map.update("async_tool_calls", %{}, fn calls ->
      Map.new(calls, fn {id, call} -> {id, drop_trusted_origin(call)} end)
    end)
  end

  defp maybe_put_sources(state, attrs, accepted_snapshot) do
    state =
      case value(attrs, "active_external_source_message_ids") do
        ids when is_list(ids) ->
          ids = ids |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

          state
          |> Map.put("active_external_source_message_ids", ids)
          |> Map.put(
            "active_external_trusted_origins",
            active_trusted_origins(accepted_snapshot, ids)
          )

        _ ->
          state
      end

    state
  end

  defp normalize_source_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp active_trusted_origins(snapshot, source_ids) do
    snapshot
    |> List.wrap()
    |> Enum.reduce(%{}, fn message, origins ->
      source_message_id = value(message, "source_message_id")

      message
      |> SalixAgent.ToolCallProvenance.message_origins(source_ids)
      |> Enum.reduce(origins, fn origin, acc ->
        ids =
          case origin["source_message_id"] do
            id when is_binary(id) and id != "" -> [id]
            _ -> value(message, "trusted_origin_source_message_ids") || [source_message_id]
          end

        ids
        |> Enum.filter(&(&1 in source_ids))
        |> Enum.reduce(acc, &Map.put(&2, &1, origin))
      end)
    end)
  end

  defp drop_trusted_origin(map) when is_map(map) do
    map
    |> Map.drop(
      ~w(trusted_origin trusted_origins trusted_origin_source_message_ids do_not_send_to_llm)
    )
    |> Map.update("wait", nil, &drop_trusted_origin/1)
  end

  defp drop_trusted_origin(value), do: value

  defp maybe_put(map, key, value, condition \\ true)
  defp maybe_put(map, _key, value, _condition) when value in [nil, ""], do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map

  defp compact(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(value), do: value

  defp stringify_content(nil), do: ""
  defp stringify_content(value) when is_binary(value), do: value
  defp stringify_content(value), do: inspect(value)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp value(_map, _key), do: nil

  defp notify_session_updated(agent_id, session_id) do
    SalixAgent.Notifier.notify(agent_id, {:session_updated, session_id})
    SessionActivity.notify(agent_id, session_id)
  end

  # Modeled in tla/salix/ExternalRuntimeEventProjection.tla. SessionRecord
  # durability owns ACK. A new dispatch retains the durable-order first
  # execution's latest transition; only unreadable existing-target identity
  # requires the conservative one-event-per-execution retry set.
  defp project_connector_status_results(
         agent_id,
         session_id,
         state,
         records,
         records_with_entries,
         append_results
       ) do
    target = state["status_projection_target"] || %{}

    candidates =
      for {{{params, record}, status}, index} <-
            records_with_entries |> Enum.zip(append_results) |> Enum.with_index(),
          status in [:committed, :duplicate],
          event = params["event"] || %{},
          connector_lifecycle_event?(event) do
        %{
          agent_id: agent_id,
          session_id: session_id,
          index: index,
          event: event,
          record: record,
          record_id: record["id"],
          connector_run_id: params["connector_run_id"]
        }
      end
      |> Enum.sort_by(& &1.record_id)

    if candidates == [] do
      %{}
    else
      case ExternalSessionStatus.plan_runtime_event(
             agent_id,
             session_id,
             candidates,
             target
           ) do
        {:ok, nil, nil} ->
          %{}

        {:ok, nil, {candidate, mapping, status}} ->
          observe_connector_mapping(mapping, candidate, status)

          _ = project_status({:ok, status}, agent_id, session_id)
          %{}

        {:ok, candidate, _ignored} ->
          %{candidate.index => project_connector_status(candidate, state)}

        {:error, reason} ->
          projection_result = project_status({:error, reason}, agent_id, session_id)

          target
          |> retryable_projection_candidates(agent_id, session_id, records, candidates)
          |> Map.new(fn candidate ->
            observe_connector_mapping("projection_read_failed", candidate)
            {candidate.index, projection_result}
          end)
      end
    end
  end

  defp retryable_projection_candidates(target, agent_id, session_id, records, candidates) do
    target = resolve_projection_target(target, agent_id, session_id, records)

    candidates
    |> Enum.filter(fn candidate ->
      ExternalSessionStatus.runtime_event_candidate?(
        target,
        candidate.event,
        candidate.record_id
      )
    end)
    |> retain_first_dispatch_execution(target)
    |> Enum.reduce(%{}, fn candidate, latest ->
      Map.put(latest, candidate.event["execution_id"], candidate)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.record_id)
  end

  defp retain_first_dispatch_execution([first | _] = candidates, target) do
    if projection_target_waits_for_first_execution?(target) do
      execution_id = first.event["execution_id"]
      Enum.filter(candidates, &(&1.event["execution_id"] == execution_id))
    else
      candidates
    end
  end

  defp retain_first_dispatch_execution([], _target), do: []

  defp projection_target_waits_for_first_execution?(target) do
    not present?(target["execution_id"]) and present?(target["record_floor"]) and
      (not present?(target["watermark"]) or target["watermark"] <= target["record_floor"])
  end

  defp resolve_projection_target(target, agent_id, session_id, records) do
    with false <- present?(target["execution_id"]),
         true <- present?(target["watermark"]),
         true <-
           not present?(target["record_floor"]) or
             target["watermark"] > target["record_floor"],
         {:ok, %{"data" => %{"event" => event}}} <-
           ExternalSessionRecords.fetch(agent_id, session_id, records, target["watermark"]) do
      Map.merge(target, Map.take(event, ~w(dispatch_id execution_id)))
    else
      _not_resolved -> target
    end
  end

  defp connector_lifecycle_event?(event) do
    event["work_state"] in ~w(running settled failed) and
      present?(event["dispatch_id"]) and present?(event["execution_id"])
  end

  defp project_connector_status(candidate, state) do
    target_result =
      if get_in(state, ["status_projection_target", "watermark"]) == candidate.record_id do
        {:ok, state}
      else
        update_state(candidate.agent_id, candidate.session_id, fn current ->
          retire? =
            candidate.event["work_state"] in ["settled", "failed"] and
              ExternalSessionStatus.runtime_event_candidate?(
                current["status_projection_target"],
                candidate.event,
                candidate.record_id
              )

          next =
            current
            |> maybe_retire_triage_provenance(state, candidate.event, retire?)
            |> put_status_projection_target(candidate.record)

          {:ok, next}
        end)
      end

    case target_result do
      {:ok, state} ->
        projection =
          ExternalSessionStatus.apply_runtime_event(
            candidate.agent_id,
            candidate.session_id,
            candidate.event,
            candidate.record_id,
            candidate.connector_run_id,
            state["status_projection_target"]
          )

        case project_status(projection, candidate.agent_id, candidate.session_id) do
          {:ok, _status} ->
            :ok

          {:error, _reason} = error ->
            observe_connector_mapping("projection_failed", candidate)

            error
        end

      {:error, _reason} = error ->
        observe_connector_mapping("target_write_failed", candidate)

        error
    end
  end

  # Modeled in tla/salix/TriageRouterHandoffProvenance.tla. Retire only this accepted
  # activation's Triage candidates in the existing settlement CAS. Running
  # calls retain their saved provenance and may resume it through the normal
  # completion queue. A newer accepted dispatch or a mismatched late terminal
  # cannot retire the current batch; ordinary provenance keeps its semantics.
  defp maybe_retire_triage_provenance(current, expected, event, true) do
    identity_fields = ~w(dispatch_id execution_id connector_run_id record_floor)
    target = current["status_projection_target"] || %{}
    expected_target = expected["status_projection_target"] || %{}
    origins = current["active_external_trusted_origins"] || %{}

    same_activation? =
      Map.take(target, identity_fields) == Map.take(expected_target, identity_fields) and
        origins == (expected["active_external_trusted_origins"] || %{}) and
        not (event["type"] == "error" and present?(event["dispatch_id"]) and
               present?(target["execution_id"])) and
        Enum.all?(~w(dispatch_id execution_id), fn field ->
          not present?(event[field]) or not present?(target[field]) or
            event[field] == target[field]
        end)

    if same_activation? do
      retired_ids =
        for {source_id, origin} <- origins,
            is_map(origin) and Map.has_key?(origin, "triage_delegation"),
            do: source_id

      current
      |> Map.put("active_external_trusted_origins", Map.drop(origins, retired_ids))
      |> Map.update("active_external_source_message_ids", [], fn ids ->
        Enum.reject(ids, &(&1 in retired_ids))
      end)
    else
      current
    end
  end

  defp maybe_retire_triage_provenance(current, _expected, _event, _retire?), do: current

  defp observe_connector_mapping(mapping, candidate, status \\ %{}) do
    ExternalSessionLifecycleObservation.lifecycle(%{
      source: "connector_event",
      mapping: mapping,
      agent_id: candidate.agent_id,
      session_id: candidate.session_id,
      connector_run_id: candidate.connector_run_id,
      dispatch_id: candidate.event["dispatch_id"],
      execution_id: candidate.event["execution_id"],
      record_id: candidate.record_id,
      work_state: candidate.event["work_state"],
      status: status["status"],
      issue: status["issue"]
    })
  end

  defp project_status({:ok, _status} = result, _agent_id, _session_id) do
    Salix.Telemetry.emit_external_status_projection(:ok)
    result
  end

  defp project_status({:error, reason}, agent_id, session_id) do
    Salix.Telemetry.emit_external_status_projection(:failed)

    Logger.warning(
      "external session status projection failed for #{agent_id}/#{session_id}: #{inspect(reason)}"
    )

    {:error, reason}
  end

  defp project_status_and_notify(projection, agent_id, session_id) do
    result = project_status(projection, agent_id, session_id)
    notify_session_updated(agent_id, session_id)
    result
  end

  defp session_key(agent_id, session_id),
    do: Keys.agent_external_runtime_session(agent_id, session_id)

  defp token_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:second)
  defp present?(value), do: trim(value) != ""
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
