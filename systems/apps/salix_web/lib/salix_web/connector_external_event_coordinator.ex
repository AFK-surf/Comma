defmodule SalixWeb.ConnectorExternalEventCoordinator do
  @moduledoc """
  Owns connector-originated external runtime event admission independently of
  any one WebSocket process.

  The unchanged connector can abandon and retry a stable event id, and a
  reconnect replaces the socket process. This coordinator therefore owns the
  per-device ordered lane, exact-id dedupe, bounded detached queue, task
  deadline, and completion cache outside `ConnectorSocket`.

  Every node routes calls to the constant `SalixCluster.Ring` owner for this
  coordinator, so exact admission and the global/tenant bounds are cluster-wide
  while that owner is stable and connected. Owner loss or a cluster partition
  may move admission to a fresh coordinator and therefore permit a duplicate
  validation task; the durable external-session event-id fence remains the
  safety backstop in that failure mode.

  A first-submit waiter is armed only after the bounded owner call returns to
  its socket. If that call times out, a late owner admission remains detached:
  completion is cached for the connector's exact-id retry and cannot push a
  second response for the already-timed-out wire request.

  Legacy coordination is modeled in
  `tla/salix/ConnectorExternalEvent.tla`; the reused permanent/transient
  classifier for batch settlement is modeled in
  `tla/salix/ExternalRuntimeEventBatch.tla`.
  """

  use GenServer

  alias SalixWeb.ConnectorTaskAdmission

  @doc "Classify one batch item's failure without transferring queue ownership."
  def batch_failure_disposition(connector_run_id, connection_generation, reason)
      when is_binary(connector_run_id) and is_integer(connection_generation) do
    case permanent_error_code(reason) do
      nil ->
        :retry

      error_code ->
        if stale_context_error?(reason) and
             not current_connector_generation?(connector_run_id, connection_generation) do
          :retry
        else
          {:permanently_rejected, error_code}
        end
    end
  end

  @legacy_waiter_timeout_ms 5_000
  @legacy_response_margin_ms 100
  @default_absolute_timeout_ms 60_000
  @default_queue_limit 64
  @default_global_retained_limit 4_096
  @default_tenant_retained_limit 512
  @default_retained_bytes_limit 16 * 1024 * 1024
  @default_global_retained_bytes_limit 128 * 1024 * 1024
  @default_tenant_retained_bytes_limit 32 * 1024 * 1024
  @default_tenant_active_limit 16
  @default_cache_limit 4_096
  @default_cache_ttl_ms 300_000
  @default_owner_call_timeout_ms 750
  @max_owner_call_timeout_ms 1_000
  @max_legacy_response_timeout_ms @legacy_waiter_timeout_ms - @max_owner_call_timeout_ms -
                                    @legacy_response_margin_ms
  @default_response_timeout_ms @max_legacy_response_timeout_ms
  @lane_retry_ms 250

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Admit an event for a stable connector device lane.

  Returns `{:wait, ref}` only for the first active waiter. Every queued or
  duplicate request gets an immediate reply map. A later active completion is
  delivered to the socket as `{:connector_external_event_reply, ref, reply}`.
  """
  def submit(socket, lane_key, id, params, execute)
      when is_pid(socket) and is_binary(id) and is_map(params) and
             (is_function(execute, 0) or is_function(execute, 1) or
                is_tuple(execute)) do
    submit(socket, lane_key, 0, id, params, execute)
  end

  def submit(socket, lane_key, generation, id, params, execute)
      when is_pid(socket) and is_integer(generation) and is_binary(id) and is_map(params) and
             (is_function(execute, 0) or is_function(execute, 1) or is_tuple(execute)) do
    timeout = owner_call_timeout_ms()
    target = server()
    key = {lane_key, id}
    waiter_token = make_ref()
    waiter_ref = make_ref()

    result =
      owner_call(
        target,
        {:submit, socket, lane_key, generation, id, params, normalize_executor(execute),
         waiter_token, waiter_ref},
        timeout
      )

    case result do
      {:wait_unarmed, ^key, ^waiter_token, ^waiter_ref} ->
        GenServer.cast(target, {:arm_waiter, key, waiter_token})
        {:wait, waiter_ref}

      {:error, _reason} = error ->
        GenServer.cast(target, {:detach_waiter, key, waiter_token})
        observe_submit_result(error)

      other ->
        observe_submit_result(other)
    end
  end

  @doc "Refresh an admitted lane with the current connector socket generation."
  def refresh_lane(socket, lane_key, generation, execute)
      when is_pid(socket) and is_integer(generation) and
             (is_function(execute, 0) or is_function(execute, 1) or is_tuple(execute)) do
    timeout = owner_call_timeout_ms()

    owner_call(
      server(),
      {:refresh_lane, socket, lane_key, generation, normalize_executor(execute)},
      timeout
    )
  end

  @impl true
  def init(_opts) do
    Salix.Telemetry.emit_connector_external_event_queue_depth(0)

    {:ok,
     %{
       events: %{},
       lanes: %{},
       task_monitors: %{},
       socket_monitors: %{},
       retained_count: 0,
       retained_bytes: 0,
       tenant_counts: %{},
       tenant_retained_bytes: %{},
       tenant_active_counts: %{},
       completed: %{},
       completed_order: :queue.new(),
       completion_sequence: 0,
       waiting_lanes: :queue.new(),
       waiting_lane_set: MapSet.new()
     }}
  end

  @impl true
  def handle_call(
        {:submit, socket, lane_key, generation, id, params, execute, waiter_token, waiter_ref},
        _from,
        state
      ) do
    cond do
      params["event_id"] == id ->
        state = prune_completed(state)
        key = {lane_key, id}

        case admitted_or_completed(state, key) do
          {:completed, completed} ->
            {outcome, reply, state} =
              if completed.params == params do
                {:cache_hit, completed.reply, clear_completed_waiter(state, key, completed)}
              else
                {:conflict, conflict_reply(id), state}
              end

            Salix.Telemetry.emit_connector_external_event(outcome)
            {:reply, {:reply, reply}, state}

          {:event, event} ->
            state = refresh_lane_executor(state, lane_key, socket, generation, execute)

            {outcome, reply, state} =
              cond do
                event.params != params ->
                  {:conflict, conflict_reply(id), state}

                event.status == :queued ->
                  {:duplicate, queued_reply(id), state}

                true ->
                  {:duplicate, retry_reply(id, "external runtime event is still in progress"),
                   state}
              end

            Salix.Telemetry.emit_connector_external_event(outcome)
            {:reply, {:reply, reply}, state}

          :missing ->
            case retained_external_size({key, params}) do
              {:ok, retained_bytes} ->
                admit_new_event(
                  state,
                  socket,
                  lane_key,
                  generation,
                  key,
                  id,
                  params,
                  retained_bytes,
                  execute,
                  waiter_token,
                  waiter_ref
                )

              :error ->
                Salix.Telemetry.emit_connector_external_event(:terminal)

                {:reply, {:reply, terminal_reply(id, "invalid_external_runtime_event_payload")},
                 state}
            end
        end

      true ->
        Salix.Telemetry.emit_connector_external_event(:terminal)
        {:reply, {:reply, terminal_reply(id, "external_runtime_event_id_mismatch")}, state}
    end
  end

  def handle_call(
        {:refresh_lane, socket, lane_key, generation, execute},
        _from,
        state
      ) do
    state =
      if Map.has_key?(state.lanes, lane_key) do
        state
        |> refresh_lane_executor(lane_key, socket, generation, execute)
        |> maybe_start_next(lane_key)
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:arm_waiter, key, waiter_token}, state) do
    case state.events[key] do
      %{waiter: %{token: ^waiter_token, armed: false}} = event ->
        event = arm_waiter(event)
        authorize_event_task(event)
        {:noreply, put_in(state, [:events, key], event)}

      _not_active ->
        case state.completed[key] do
          %{
            waiter_token: ^waiter_token,
            reply: reply,
            waiter_socket: socket,
            waiter_ref: waiter_ref
          } = completed ->
            send(socket, {:connector_external_event_reply, waiter_ref, reply})

            {:noreply, clear_completed_waiter(state, key, completed)}

          _not_completed ->
            {:noreply, state}
        end
    end
  end

  def handle_cast({:detach_waiter, key, waiter_token}, state) do
    case state.events[key] do
      %{waiter: %{token: ^waiter_token, armed: false}} = event ->
        event = %{event | waiter: nil, response_timer: nil, response_deadline_at: nil}
        authorize_event_task(event)
        {:noreply, put_in(state, [:events, key], event)}

      _not_active ->
        case state.completed[key] do
          %{waiter_token: ^waiter_token} = completed ->
            {:noreply, clear_completed_waiter(state, key, completed)}

          _not_completed ->
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:external_event_response_timeout, key, waiter_ref}, state) do
    case state.events[key] do
      %{waiter: %{ref: ^waiter_ref, socket: socket}, id: id} = event ->
        Salix.Telemetry.emit_connector_external_event(:timeout)

        send(
          socket,
          {:connector_external_event_reply, waiter_ref,
           retry_reply(id, "external runtime event response timed out")}
        )

        event = %{event | waiter: nil, response_timer: nil, response_deadline_at: nil}
        {:noreply, put_in(state, [:events, key], event)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:external_event_absolute_timeout, key}, state) do
    case state.events[key] do
      nil ->
        {:noreply, state}

      %{status: :queued} = event ->
        Salix.Telemetry.emit_connector_external_event(:timeout)
        {:noreply, remove_queued_event(state, event)}

      event ->
        Salix.Telemetry.emit_connector_external_event(:timeout)
        state = stop_event_task(state, event)
        maybe_send_waiter(event, retry_reply(event.id, "external runtime event timed out"))
        {:noreply, finish_active_event(state, event, nil)}
    end
  end

  def handle_info({:external_event_task_complete, key, task_pid, result}, state) do
    case state.events[key] do
      %{task_pid: ^task_pid} = event ->
        state = clear_event_task(state, event)
        send(task_pid, {:external_event_completion_ack, key})

        case classify_event_result(state, event, result) do
          {:cache, reply} ->
            Salix.Telemetry.emit_connector_external_event(cached_outcome(reply))
            maybe_send_waiter(event, reply)

            state
            |> finish_active_event(event, {event.params, reply})
            |> then(&{:noreply, &1})

          {:retry, reply} ->
            Salix.Telemetry.emit_connector_external_event(:retry)
            maybe_send_waiter(event, reply)
            {:noreply, finish_active_event(state, event, nil)}
        end

      _stale ->
        send(task_pid, {:external_event_completion_ack, key})
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.task_monitors, monitor) do
      {nil, _task_monitors} ->
        handle_socket_down(monitor, state)

      {key, task_monitors} ->
        case state.events[key] do
          %{task_monitor: ^monitor} = event ->
            state = %{state | task_monitors: task_monitors}
            state = clear_event_task(state, event)
            event = Map.fetch!(state.events, key)

            Salix.Telemetry.emit_connector_external_event(:retry)

            maybe_send_waiter(
              event,
              retry_reply(event.id, "external runtime event task exited: #{format_error(reason)}")
            )

            {:noreply, finish_active_event(state, event, nil)}

          _stale ->
            {:noreply, %{state | task_monitors: task_monitors}}
        end
    end
  end

  def handle_info({:retry_external_event_lane, lane_key}, state) do
    lane = lane(state, lane_key)
    state = put_lane(state, lane_key, %{lane | retry_timer: nil})
    {:noreply, maybe_start_next(state, lane_key)}
  end

  def handle_info({:connector_task_admission_released, :external_event}, state) do
    {:noreply, resume_waiting_lane(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit_new_event(
         state,
         socket,
         lane_key,
         generation,
         key,
         id,
         params,
         retained_bytes,
         execute,
         waiter_token,
         waiter_ref
       ) do
    tenant_key = tenant_key(lane_key)

    cond do
      retained_bytes > retained_bytes_limit() ->
        Salix.Telemetry.emit_connector_external_event(:terminal)

        {:reply, {:reply, terminal_reply(id, "external_runtime_event_too_large")}, state}

      state.retained_count >= global_retained_limit() ->
        Salix.Telemetry.emit_connector_external_event(:saturated)

        {:reply,
         {:reply, retry_reply(id, "external runtime event global retained capacity exhausted")},
         state}

      Map.get(state.tenant_counts, tenant_key, 0) >= tenant_retained_limit() ->
        Salix.Telemetry.emit_connector_external_event(:saturated)

        {:reply,
         {:reply, retry_reply(id, "external runtime event tenant retained capacity exhausted")},
         state}

      state.retained_bytes + retained_bytes > global_retained_bytes_limit() ->
        Salix.Telemetry.emit_connector_external_event(:saturated)

        {:reply,
         {:reply,
          retry_reply(id, "external runtime event global retained byte capacity exhausted")},
         state}

      Map.get(state.tenant_retained_bytes, tenant_key, 0) + retained_bytes >
          tenant_retained_bytes_limit() ->
        Salix.Telemetry.emit_connector_external_event(:saturated)

        {:reply,
         {:reply,
          retry_reply(id, "external runtime event tenant retained byte capacity exhausted")},
         state}

      true ->
        state = refresh_lane_executor(state, lane_key, socket, generation, execute)

        admit_retained_event(
          state,
          socket,
          lane_key,
          tenant_key,
          key,
          id,
          params,
          retained_bytes,
          waiter_token,
          waiter_ref
        )
    end
  end

  defp admit_retained_event(
         state,
         socket,
         lane_key,
         tenant_key,
         key,
         id,
         params,
         retained_bytes,
         waiter_token,
         waiter_ref
       ) do
    lane = lane(state, lane_key)

    cond do
      is_nil(lane.active) and :queue.is_empty(lane.queue) ->
        event =
          new_event(key, lane_key, tenant_key, id, params, retained_bytes, :active)
          |> attach_unarmed_waiter(socket, waiter_ref, waiter_token)

        state =
          state
          |> retain_event(event)
          |> put_lane(lane_key, %{lane | active: key})

        case start_event_task(state, key) do
          {:ok, state} ->
            {:reply, {:wait_unarmed, key, waiter_token, waiter_ref}, state}

          {:error, :admission_overloaded, state} ->
            Salix.Telemetry.emit_connector_external_event(:saturated)
            state = detach_active_event(state, event)

            {:reply, {:reply, retry_reply(id, "external runtime event capacity exhausted")},
             state}

          {:error, :tenant_admission_overloaded, state} ->
            Salix.Telemetry.emit_connector_external_event(:saturated)
            state = detach_active_event(state, event)

            {:reply,
             {:reply, retry_reply(id, "external runtime event tenant capacity exhausted")}, state}

          {:error, :task_start_failed, state} ->
            Salix.Telemetry.emit_connector_external_event(:saturated)
            state = discard_active_event(state, event)

            {:reply, {:reply, retry_reply(id, "external runtime event capacity exhausted")},
             state}

          {:error, :awaiting_generation, state} ->
            Salix.Telemetry.emit_connector_external_event(:retry)
            state = state |> detach_active_event(event) |> drop_waiting_lane(lane_key)

            {:reply, {:reply, retry_reply(id, "connector transport generation unavailable")},
             state}
        end

      :queue.len(lane.queue) >= queue_limit() ->
        Salix.Telemetry.emit_connector_external_event(:saturated)

        {:reply, {:reply, retry_reply(id, "external runtime event queue capacity exhausted")},
         state}

      true ->
        event = new_event(key, lane_key, tenant_key, id, params, retained_bytes, :queued)
        lane = %{lane | queue: :queue.in(key, lane.queue)}

        state =
          state
          |> retain_event(event)
          |> put_lane(lane_key, lane)

        Salix.Telemetry.emit_connector_external_event(:queued)
        {:reply, {:reply, queued_reply(id)}, state}
    end
  end

  defp new_event(key, lane_key, tenant_key, id, params, retained_bytes, status) do
    absolute_timer =
      Process.send_after(self(), {:external_event_absolute_timeout, key}, absolute_timeout_ms())

    %{
      key: key,
      lane_key: lane_key,
      tenant_key: tenant_key,
      id: id,
      params: params,
      retained_bytes: retained_bytes,
      status: status,
      waiter: nil,
      response_timer: nil,
      response_deadline_at: nil,
      absolute_timer: absolute_timer,
      task_pid: nil,
      task_monitor: nil,
      admission: nil,
      execution_socket: nil,
      execution_generation: nil
    }
  end

  defp attach_unarmed_waiter(event, socket, waiter_ref, waiter_token) do
    %{
      event
      | waiter: %{socket: socket, ref: waiter_ref, token: waiter_token, armed: false},
        response_timer: nil,
        response_deadline_at: monotonic_ms() + response_timeout_ms()
    }
  end

  defp arm_waiter(event) do
    remaining = max(event.response_deadline_at - monotonic_ms(), 0)

    response_timer =
      Process.send_after(
        self(),
        {:external_event_response_timeout, event.key, event.waiter.ref},
        remaining
      )

    %{event | waiter: %{event.waiter | armed: true}, response_timer: response_timer}
  end

  defp start_event_task(state, key) do
    event = Map.fetch!(state.events, key)
    lane = lane(state, event.lane_key)
    coordinator = self()

    with false <- tenant_active_saturated?(state, event.tenant_key),
         %{socket: socket, generation: generation, execute: execute} <- lane.executor do
      start_event_task_with_executor(state, event, coordinator, socket, generation, execute)
    else
      true -> {:error, :tenant_admission_overloaded, state}
      _ -> {:error, :awaiting_generation, state}
    end
  end

  defp start_event_task_with_executor(
         state,
         event,
         coordinator,
         socket,
         generation,
         execute
       ) do
    case ConnectorTaskAdmission.acquire(:external_event, coordinator) do
      {:ok, admission} ->
        case start_task_child(coordinator, event.key, fn ->
               execute_event(execute, event.params)
             end) do
          {:ok, task_pid} ->
            ConnectorTaskAdmission.track(admission, task_pid)
            monitor = Process.monitor(task_pid)

            event = %{
              event
              | status: :active,
                task_pid: task_pid,
                task_monitor: monitor,
                admission: admission,
                execution_socket: socket,
                execution_generation: generation
            }

            state =
              state
              |> put_in([:events, event.key], event)
              |> put_in([:task_monitors, monitor], event.key)
              |> increment_tenant_active(event.tenant_key)

            if is_nil(event.waiter) or event.waiter.armed, do: authorize_event_task(event)
            Salix.Telemetry.emit_connector_external_event(:accepted)
            {:ok, state}

          {:error, _reason} ->
            ConnectorTaskAdmission.release(admission)
            {:error, :task_start_failed, state}
        end

      {:error, _reason} ->
        {:error, :admission_overloaded, state}
    end
  end

  defp start_task_child(coordinator, key, execute) do
    Task.Supervisor.start_child(
      SalixWeb.ConnectorExternalEventTaskSupervisor,
      fn ->
        receive do
          {:external_event_authorize, ^key} -> :ok
        end

        result = execute_safely(execute)
        send(coordinator, {:external_event_task_complete, key, self(), result})

        receive do
          {:external_event_completion_ack, ^key} -> :ok
        after
          5_000 -> :ok
        end
      end
    )
  catch
    :exit, reason -> {:error, reason}
  end

  defp authorize_event_task(%{task_pid: task_pid, key: key}) when is_pid(task_pid) do
    send(task_pid, {:external_event_authorize, key})
    :ok
  end

  defp authorize_event_task(_event), do: :ok

  defp execute_safely(execute) do
    execute.()
  rescue
    error -> {:error, {:external_event_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_event({:connector_context, connector_run_id, meta}, params)
       when is_binary(connector_run_id) and is_map(meta) do
    handler =
      Application.get_env(
        :salix_web,
        :connector_external_runtime_handler,
        SalixWeb.ExternalRuntime
      )

    handler.handle_connector_event(connector_run_id, params, meta)
  end

  defp execute_event(execute, params) when is_function(execute, 1), do: execute.(params)
  defp execute_event(execute, _params) when is_function(execute, 0), do: execute.()
  defp execute_event(execute, _params), do: {:error, {:invalid_event_executor, execute}}

  defp classify_result(id, {:ok, result}) do
    {:cache, %{"id" => id, "type" => "response", "result" => result}}
  end

  defp classify_result(id, {:error, reason}) do
    case permanent_error_code(reason) do
      nil -> {:retry, retry_reply(id, format_error(reason))}
      error_code -> {:cache, terminal_reply(id, error_code)}
    end
  end

  defp classify_result(id, other),
    do: {:retry, retry_reply(id, "invalid external runtime event result: #{format_error(other)}")}

  defp classify_event_result(state, event, {:error, reason} = result) do
    if stale_execution?(state, event) and stale_context_error?(reason) do
      {:retry, retry_reply(event.id, "connector transport generation changed")}
    else
      classify_result(event.id, result)
    end
  end

  defp classify_event_result(_state, event, result), do: classify_result(event.id, result)

  defp stale_context_error?(reason),
    do:
      reason in [
        :unauthorized,
        :stale_external_runtime_session,
        :external_session_read_only,
        :stale_connector_transport_generation
      ]

  defp current_connector_generation?(connector_run_id, connection_generation) do
    case SalixEnv.Registry.get_by_connector_run_id(connector_run_id) do
      {:ok, _transport_id, %{"connection_generation" => ^connection_generation}} -> true
      _ -> false
    end
  end

  defp permanent_error_code(:unauthorized), do: "unauthorized"
  defp permanent_error_code(:not_found), do: "not_found"
  defp permanent_error_code(:external_session_read_only), do: "external_session_read_only"
  defp permanent_error_code(:stale_external_runtime_session), do: "stale_external_runtime_session"
  defp permanent_error_code(:invalid_session_id), do: "invalid_session_id"

  defp permanent_error_code(:external_session_record_conflict),
    do: "external_session_record_conflict"

  defp permanent_error_code(:external_runtime_declined_delivery),
    do: "external_runtime_declined_delivery"

  defp permanent_error_code(:external_runtime_input_empty),
    do: "external_runtime_input_empty"

  defp permanent_error_code(:external_runtime_input_id_missing),
    do: "external_runtime_input_id_missing"

  defp permanent_error_code({:bad_request, _detail}), do: "invalid_external_runtime_event"
  defp permanent_error_code(_reason), do: nil

  defp terminal_reply(id, error_code) do
    %{
      "id" => id,
      "type" => "response",
      "result" => %{
        "accepted" => false,
        "disposition" => "permanently_rejected",
        "error_code" => error_code
      }
    }
  end

  defp conflict_reply(id), do: terminal_reply(id, "external_runtime_event_id_conflict")

  defp queued_reply(id) do
    %{
      "id" => id,
      "type" => "error",
      "error" => "external runtime event queued for detached delivery",
      "error_code" => "external_runtime_event_queued"
    }
  end

  defp retry_reply(id, reason) do
    %{
      "id" => id,
      "type" => "error",
      "error" => reason,
      "error_code" => "external_runtime_event_retry"
    }
  end

  defp finish_active_event(state, event, cached) do
    cancel_event_timers(event)
    state = release_event(state, event)
    lane = lane(state, event.lane_key)
    state = put_lane(state, event.lane_key, %{lane | active: nil})
    state = if cached, do: cache_completion(state, event, cached), else: state
    maybe_start_next(state, event.lane_key)
  end

  defp discard_active_event(state, event) do
    cancel_event_timers(event)
    lane = lane(state, event.lane_key)

    state
    |> release_event(event)
    |> put_lane(event.lane_key, %{lane | active: nil})
    |> cleanup_lane_if_idle(event.lane_key)
  end

  defp detach_active_event(state, event) do
    if event.response_timer, do: Process.cancel_timer(event.response_timer)

    event = %{
      event
      | status: :queued,
        waiter: nil,
        response_timer: nil,
        response_deadline_at: nil,
        task_pid: nil,
        task_monitor: nil,
        admission: nil
    }

    lane = lane(state, event.lane_key)
    lane = %{lane | active: nil, queue: :queue.in(event.key, lane.queue)}

    state
    |> put_in([:events, event.key], event)
    |> put_lane(event.lane_key, lane)
    |> enqueue_waiting_lane(event.lane_key)
  end

  defp remove_queued_event(state, event) do
    cancel_event_timers(event)
    lane = lane(state, event.lane_key)

    queue =
      lane.queue
      |> :queue.to_list()
      |> Enum.reject(&(&1 == event.key))
      |> :queue.from_list()

    state
    |> release_event(event)
    |> put_lane(event.lane_key, %{lane | queue: queue})
    |> cleanup_lane_if_idle(event.lane_key)
  end

  defp maybe_start_next(state, lane_key) do
    lane = lane(state, lane_key)

    if is_nil(lane.active) do
      case :queue.out(lane.queue) do
        {{:value, key}, rest} ->
          lane = %{lane | active: key, queue: rest}
          state = state |> put_lane(lane_key, lane) |> put_in([:events, key, :status], :active)

          case start_event_task(state, key) do
            {:ok, state} ->
              state

            {:error, reason, state} ->
              lane = lane(state, lane_key)
              lane = %{lane | active: nil, queue: :queue.in_r(key, lane.queue)}
              state = put_in(state, [:events, key, :status], :queued)
              state = put_lane(state, lane_key, lane)

              case reason do
                reason when reason in [:admission_overloaded, :tenant_admission_overloaded] ->
                  Salix.Telemetry.emit_connector_external_event(:saturated)
                  enqueue_waiting_lane(state, lane_key)

                :task_start_failed ->
                  Salix.Telemetry.emit_connector_external_event(:saturated)
                  schedule_lane_retry(state, lane_key)

                :awaiting_generation ->
                  Salix.Telemetry.emit_connector_external_event(:retry)
                  state
              end
          end

        {:empty, _queue} ->
          cleanup_lane_if_idle(state, lane_key)
      end
    else
      state
    end
  end

  defp schedule_lane_retry(state, lane_key) do
    lane = lane(state, lane_key)

    if lane.retry_timer do
      state
    else
      timer = Process.send_after(self(), {:retry_external_event_lane, lane_key}, @lane_retry_ms)
      put_lane(state, lane_key, %{lane | retry_timer: timer})
    end
  end

  defp enqueue_waiting_lane(state, lane_key) do
    if MapSet.member?(state.waiting_lane_set, lane_key) do
      state
    else
      %{
        state
        | waiting_lanes: :queue.in(lane_key, state.waiting_lanes),
          waiting_lane_set: MapSet.put(state.waiting_lane_set, lane_key)
      }
    end
  end

  defp resume_waiting_lane(state), do: resume_waiting_lane(state, :queue.len(state.waiting_lanes))

  defp resume_waiting_lane(state, attempts) when attempts <= 0, do: state

  defp resume_waiting_lane(state, attempts) do
    case :queue.out(state.waiting_lanes) do
      {{:value, lane_key}, rest} ->
        state = %{
          state
          | waiting_lanes: rest,
            waiting_lane_set: MapSet.delete(state.waiting_lane_set, lane_key)
        }

        lane = lane(state, lane_key)

        cond do
          not is_nil(lane.active) ->
            resume_waiting_lane(state, attempts - 1)

          :queue.is_empty(lane.queue) ->
            state |> cleanup_lane_if_idle(lane_key) |> resume_waiting_lane(attempts - 1)

          true ->
            state = maybe_start_next(state, lane_key)

            if is_nil(lane(state, lane_key).active) do
              resume_waiting_lane(state, attempts - 1)
            else
              state
            end
        end

      {:empty, _queue} ->
        state
    end
  end

  defp cleanup_lane_if_idle(state, lane_key) do
    lane = lane(state, lane_key)

    if is_nil(lane.active) and :queue.is_empty(lane.queue) do
      if lane.retry_timer, do: Process.cancel_timer(lane.retry_timer)

      state
      |> clear_lane_executor(lane)
      |> Map.update!(:lanes, &Map.delete(&1, lane_key))
      |> drop_waiting_lane(lane_key)
    else
      state
    end
  end

  defp drop_waiting_lane(state, lane_key) do
    if MapSet.member?(state.waiting_lane_set, lane_key) do
      waiting_lanes =
        state.waiting_lanes
        |> :queue.to_list()
        |> Enum.reject(&(&1 == lane_key))
        |> :queue.from_list()

      %{
        state
        | waiting_lanes: waiting_lanes,
          waiting_lane_set: MapSet.delete(state.waiting_lane_set, lane_key)
      }
    else
      state
    end
  end

  defp clear_event_task(state, event) do
    if event.task_monitor, do: Process.demonitor(event.task_monitor, [:flush])
    ConnectorTaskAdmission.release(event.admission)

    state = %{
      state
      | task_monitors: Map.delete(state.task_monitors, event.task_monitor),
        events:
          Map.put(state.events, event.key, %{
            event
            | task_pid: nil,
              task_monitor: nil,
              admission: nil
          })
    }

    decrement_tenant_active(state, event.tenant_key)
  end

  defp stop_event_task(state, event) do
    if is_pid(event.task_pid), do: Process.exit(event.task_pid, :kill)
    clear_event_task(state, event)
  end

  defp maybe_send_waiter(%{waiter: %{socket: socket, ref: ref, armed: true}}, reply) do
    send(socket, {:connector_external_event_reply, ref, reply})
  end

  defp maybe_send_waiter(_event, _reply), do: :ok

  defp cancel_event_timers(event) do
    if event.response_timer, do: Process.cancel_timer(event.response_timer)
    if event.absolute_timer, do: Process.cancel_timer(event.absolute_timer)
    :ok
  end

  defp admitted_or_completed(state, key) do
    cond do
      event = state.events[key] -> {:event, event}
      completed = state.completed[key] -> {:completed, completed}
      true -> :missing
    end
  end

  defp lane(state, lane_key) do
    Map.get(state.lanes, lane_key, %{
      active: nil,
      queue: :queue.new(),
      retry_timer: nil,
      executor: nil
    })
  end

  defp put_lane(state, lane_key, lane) do
    previous_depth = queued_depth(state)
    state = put_in(state, [:lanes, lane_key], lane)
    depth = queued_depth(state)

    if depth != previous_depth,
      do: Salix.Telemetry.emit_connector_external_event_queue_depth(depth)

    state
  end

  defp refresh_lane_executor(state, lane_key, socket, generation, execute) do
    lane = lane(state, lane_key)

    if replace_executor?(lane.executor, socket, generation) do
      state = clear_lane_executor(state, lane)
      monitor = Process.monitor(socket)
      executor = %{socket: socket, generation: generation, execute: execute, monitor: monitor}

      state
      |> put_lane(lane_key, %{lane | executor: executor})
      |> put_in([:socket_monitors, monitor], {lane_key, generation, socket})
    else
      state
    end
  end

  defp replace_executor?(nil, _socket, _generation), do: true
  defp replace_executor?(%{socket: socket}, socket, _generation), do: true

  defp replace_executor?(%{generation: current}, _socket, generation),
    do: generation > current

  defp clear_lane_executor(state, %{executor: nil}), do: state

  defp clear_lane_executor(state, %{executor: %{monitor: monitor}}) do
    Process.demonitor(monitor, [:flush])
    %{state | socket_monitors: Map.delete(state.socket_monitors, monitor)}
  end

  defp handle_socket_down(monitor, state) do
    case Map.pop(state.socket_monitors, monitor) do
      {nil, _socket_monitors} ->
        {:noreply, state}

      {{lane_key, generation, socket}, socket_monitors} ->
        state = %{state | socket_monitors: socket_monitors}
        lane = lane(state, lane_key)

        lane =
          case lane.executor do
            %{monitor: ^monitor, generation: ^generation, socket: ^socket} ->
              %{lane | executor: nil}

            _stale ->
              lane
          end

        state = put_lane(state, lane_key, lane)
        {:noreply, detach_unarmed_socket_waiters(state, lane_key, socket)}
    end
  end

  defp detach_unarmed_socket_waiters(state, lane_key, socket) do
    Enum.reduce(state.events, state, fn
      {key, %{lane_key: ^lane_key, waiter: %{socket: ^socket, armed: false}} = event}, acc ->
        event = %{event | waiter: nil, response_timer: nil, response_deadline_at: nil}
        authorize_event_task(event)
        put_in(acc, [:events, key], event)

      {_key, _event}, acc ->
        acc
    end)
  end

  defp stale_execution?(state, event) do
    lane = lane(state, event.lane_key)

    current? =
      case lane.executor do
        %{socket: socket, generation: generation} ->
          socket == event.execution_socket and generation == event.execution_generation

        _ ->
          false
      end

    not current?
  end

  defp retain_event(state, event) do
    state = %{
      state
      | events: Map.put(state.events, event.key, event),
        retained_count: state.retained_count + 1,
        tenant_counts: Map.update(state.tenant_counts, event.tenant_key, 1, &(&1 + 1))
    }

    retain_bytes(state, event.tenant_key, event.retained_bytes)
  end

  defp tenant_active_saturated?(state, tenant_key) do
    Map.get(state.tenant_active_counts, tenant_key, 0) >= tenant_active_limit()
  end

  defp increment_tenant_active(state, tenant_key) do
    update_in(
      state,
      [:tenant_active_counts],
      &Map.update(&1, tenant_key, 1, fn count -> count + 1 end)
    )
  end

  defp decrement_tenant_active(state, tenant_key) do
    tenant_active_counts =
      case Map.get(state.tenant_active_counts, tenant_key, 0) do
        count when count <= 1 -> Map.delete(state.tenant_active_counts, tenant_key)
        count -> Map.put(state.tenant_active_counts, tenant_key, count - 1)
      end

    %{state | tenant_active_counts: tenant_active_counts}
  end

  defp release_event(state, event) do
    tenant_counts =
      case Map.get(state.tenant_counts, event.tenant_key, 0) do
        count when count <= 1 -> Map.delete(state.tenant_counts, event.tenant_key)
        count -> Map.put(state.tenant_counts, event.tenant_key, count - 1)
      end

    state = %{
      state
      | events: Map.delete(state.events, event.key),
        retained_count: max(state.retained_count - 1, 0),
        tenant_counts: tenant_counts
    }

    release_bytes(state, event.tenant_key, event.retained_bytes)
  end

  defp retain_bytes(state, tenant_key, retained_bytes) do
    %{
      state
      | retained_bytes: state.retained_bytes + retained_bytes,
        tenant_retained_bytes:
          Map.update(state.tenant_retained_bytes, tenant_key, retained_bytes, fn current ->
            current + retained_bytes
          end)
    }
  end

  defp release_bytes(state, tenant_key, retained_bytes) do
    tenant_retained_bytes =
      case Map.get(state.tenant_retained_bytes, tenant_key, 0) - retained_bytes do
        remaining when remaining > 0 ->
          Map.put(state.tenant_retained_bytes, tenant_key, remaining)

        _zero ->
          Map.delete(state.tenant_retained_bytes, tenant_key)
      end

    %{
      state
      | retained_bytes: max(state.retained_bytes - retained_bytes, 0),
        tenant_retained_bytes: tenant_retained_bytes
    }
  end

  defp tenant_key({tenant_key, _device_key}), do: tenant_key
  defp tenant_key({tenant_key, _group_key, _device_key}), do: tenant_key
  defp tenant_key(_lane_key), do: :unscoped

  defp cache_completion(state, event, {params, reply}) do
    with {:ok, retained_bytes} <- retained_external_size({event.key, params, reply}),
         true <- retained_bytes <= retained_bytes_limit(),
         true <- state.retained_bytes + retained_bytes <= global_retained_bytes_limit(),
         true <-
           Map.get(state.tenant_retained_bytes, event.tenant_key, 0) + retained_bytes <=
             tenant_retained_bytes_limit() do
      put_cached_completion(state, event, params, reply, retained_bytes)
    else
      _not_cacheable_within_budget -> state
    end
  end

  defp put_cached_completion(state, event, params, reply, retained_bytes) do
    sequence = state.completion_sequence + 1

    {waiter_token, waiter_socket, waiter_ref} =
      case event.waiter do
        %{token: token, socket: socket, ref: ref, armed: false} -> {token, socket, ref}
        _armed_or_detached -> {nil, nil, nil}
      end

    completed = %{
      params: params,
      reply: reply,
      tenant_key: event.tenant_key,
      retained_bytes: retained_bytes,
      waiter_token: waiter_token,
      waiter_socket: waiter_socket,
      waiter_ref: waiter_ref,
      expires_at: monotonic_ms() + cache_ttl_ms(),
      sequence: sequence
    }

    state = %{
      state
      | completed: Map.put(state.completed, event.key, completed),
        completed_order: :queue.in({event.key, sequence}, state.completed_order),
        completion_sequence: sequence
    }

    state
    |> retain_bytes(event.tenant_key, retained_bytes)
    |> trim_completed()
  end

  defp clear_completed_waiter(state, key, completed) do
    completed =
      completed
      |> Map.put(:waiter_token, nil)
      |> Map.put(:waiter_socket, nil)
      |> Map.put(:waiter_ref, nil)

    put_in(state, [:completed, key], completed)
  end

  defp prune_completed(state) do
    now = monotonic_ms()

    state =
      Enum.reduce(state.completed, state, fn {key, entry}, acc ->
        if entry.expires_at <= now, do: drop_completed(acc, key, entry), else: acc
      end)

    # TTL pruning must remove its order nodes too. Rebuilding from bounded live
    # entries also makes a later reuse of an expired key unable to evict the
    # newer completion through a stale queue node.
    completed_order =
      state.completed
      |> Enum.sort_by(fn {_key, entry} -> entry.sequence end)
      |> Enum.map(fn {key, entry} -> {key, entry.sequence} end)
      |> :queue.from_list()

    trim_completed(%{state | completed_order: completed_order})
  end

  defp trim_completed(state) do
    if map_size(state.completed) <= cache_limit() do
      state
    else
      case :queue.out(state.completed_order) do
        {{:value, {key, sequence}}, rest} ->
          state = %{state | completed_order: rest}

          state =
            case state.completed[key] do
              %{sequence: ^sequence} = entry -> drop_completed(state, key, entry)
              _stale -> state
            end

          trim_completed(state)

        {:empty, _queue} ->
          state =
            Enum.reduce(state.completed, state, fn {key, entry}, acc ->
              drop_completed(acc, key, entry)
            end)

          %{state | completed_order: :queue.new()}
      end
    end
  end

  defp drop_completed(state, key, entry) do
    state = %{state | completed: Map.delete(state.completed, key)}
    release_bytes(state, entry.tenant_key, entry.retained_bytes)
  end

  defp response_timeout_ms do
    :salix_web
    |> Application.get_env(
      :connector_external_event_response_timeout_ms,
      @default_response_timeout_ms
    )
    |> positive_timeout(@default_response_timeout_ms)
    |> min(@max_legacy_response_timeout_ms)
  end

  defp absolute_timeout_ms do
    configured =
      :salix_web
      |> Application.get_env(
        :connector_external_event_absolute_timeout_ms,
        @default_absolute_timeout_ms
      )
      |> positive_timeout(@default_absolute_timeout_ms)

    max(configured, response_timeout_ms() + 1)
  end

  defp queue_limit do
    :salix_web
    |> Application.get_env(:connector_external_event_queue_limit, @default_queue_limit)
    |> positive_limit(@default_queue_limit)
  end

  defp global_retained_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_global_retained_limit,
      @default_global_retained_limit
    )
    |> positive_limit(@default_global_retained_limit)
  end

  defp tenant_retained_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_tenant_retained_limit,
      @default_tenant_retained_limit
    )
    |> positive_limit(@default_tenant_retained_limit)
  end

  defp retained_bytes_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_retained_bytes_limit,
      @default_retained_bytes_limit
    )
    |> positive_limit(@default_retained_bytes_limit)
  end

  defp global_retained_bytes_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_global_retained_bytes_limit,
      @default_global_retained_bytes_limit
    )
    |> positive_limit(@default_global_retained_bytes_limit)
  end

  defp tenant_retained_bytes_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_tenant_retained_bytes_limit,
      @default_tenant_retained_bytes_limit
    )
    |> positive_limit(@default_tenant_retained_bytes_limit)
  end

  defp tenant_active_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_tenant_active_limit,
      @default_tenant_active_limit
    )
    |> positive_limit(@default_tenant_active_limit)
  end

  defp owner_call_timeout_ms do
    :salix_web
    |> Application.get_env(
      :connector_external_event_owner_call_timeout_ms,
      @default_owner_call_timeout_ms
    )
    |> positive_timeout(@default_owner_call_timeout_ms)
    |> min(@max_owner_call_timeout_ms)
  end

  defp cache_limit do
    :salix_web
    |> Application.get_env(
      :connector_external_event_completion_cache_limit,
      @default_cache_limit
    )
    |> positive_limit(@default_cache_limit)
  end

  defp cache_ttl_ms do
    :salix_web
    |> Application.get_env(
      :connector_external_event_completion_cache_ttl_ms,
      @default_cache_ttl_ms
    )
    |> positive_timeout(@default_cache_ttl_ms)
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default
  defp positive_timeout(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value, default), do: default

  defp normalize_executor(execute), do: execute

  defp server do
    {__MODULE__, SalixCluster.Ring.owner("connector-external-event-coordinator")}
  end

  defp owner_call(target, message, timeout) do
    GenServer.call(target, message, timeout)
  catch
    :exit, _reason -> {:error, :coordinator_unavailable}
  end

  defp observe_submit_result({:error, _reason} = error) do
    Salix.Telemetry.emit_connector_external_event(:retry)
    error
  end

  defp observe_submit_result(result), do: result

  defp cached_outcome(%{"result" => %{"disposition" => "permanently_rejected"}}),
    do: :terminal

  defp cached_outcome(_reply), do: :completed

  defp queued_depth(state) do
    Enum.reduce(state.lanes, 0, fn {_lane_key, lane}, total ->
      total + :queue.len(lane.queue)
    end)
  end

  defp retained_external_size(term) do
    {:ok, :erlang.external_size(term)}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
