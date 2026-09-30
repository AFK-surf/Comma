defmodule SalixAgent.ExternalSessionActor do
  @moduledoc """
  Single writer for one external session.

  The actor owns the durable input queue, its SessionRecord segment cache, and
  in-flight runtime/tool tasks. Native runtime status is recorded but never
  controls this process. Dispatch/ACK separation and native lifecycle evidence
  are modeled in `tla/salix/ExternalRuntime.tla`; the queue, deadline,
  projection, and reconnect progress assumptions are modeled in
  `tla/salix/ExternalRuntimeProgress.tla`.
  """

  use GenServer

  require Logger

  alias SalixAgent.{
    AgentActor,
    AgentControl,
    AsyncToolResults,
    ContextProviders,
    DependencyJob,
    ExternalRuntime,
    ExternalSessionLifecycleObservation,
    ExternalSessionStatus,
    ExternalSessionStore,
    MemoryConsultationRuntime,
    SessionActivity,
    SessionToolExecution,
    Waits
  }

  defstruct [
    :agent_id,
    :session_id,
    :idle_ms,
    :records,
    pending_external: nil,
    consultation_job: nil,
    failed_dispatch_id: nil,
    pending_async_tools: %{},
    pending_async_tool_commits: %{},
    startup_recovery_pending: false,
    # Supervisor of this session's outbound SSH sessions, started on the
    # first ssh.open and linked to this actor (`SalixAgent.SSH.Sessions`).
    ssh_sessions: nil
  ]

  @default_idle_ms 60_000
  @memory_consultation_timeout_ms 25_000

  def child_spec(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, agent_id, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(agent_id, session_id))
  end

  def key(agent_id, session_id), do: {:external_session, agent_id, session_id}

  def wake(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] -> GenServer.cast(pid, :wake)
      [] -> {:error, :not_running}
    end
  end

  def execute_tool(pid, tool_name, attrs, timeout \\ :infinity),
    do: GenServer.call(pid, {:execute_tool, tool_name, attrs}, timeout)

  def begin_session(pid, tenant_id, runtime, timeout \\ :infinity),
    do: GenServer.call(pid, {:begin_session, tenant_id, runtime}, timeout)

  def update_session(pid, attrs, timeout \\ :infinity),
    do: GenServer.call(pid, {:update_session, attrs}, timeout)

  def accept_session(pid, attrs, timeout \\ :infinity),
    do: GenServer.call(pid, {:accept_session, attrs}, timeout)

  def complete_session(pid, attrs, timeout \\ :infinity),
    do: GenServer.call(pid, {:complete_session, attrs}, timeout)

  def fail_session(pid, reason, attrs, timeout \\ :infinity),
    do: GenServer.call(pid, {:fail_session, reason, attrs}, timeout)

  def append_event(pid, attrs, timeout \\ :infinity),
    do: GenServer.call(pid, {:append_event, attrs}, timeout)

  def commit_session_events(pid, events, timeout \\ :infinity),
    do: GenServer.call(pid, {:commit_session_events, events}, timeout)

  def commit_connector_event(pid, capability, params, timeout \\ :infinity),
    do: GenServer.call(pid, {:commit_connector_event, capability, params}, timeout)

  def complete_async_tool_call(pid, tool_call_id, result, meta, timeout \\ :infinity),
    do: GenServer.call(pid, {:complete_async_tool_call, tool_call_id, result, meta}, timeout)

  def update_async_tool_call_progress(pid, tool_call_id, progress, timeout \\ :infinity),
    do: GenServer.call(pid, {:update_async_tool_call_progress, tool_call_id, progress}, timeout)

  def stage_delivery(pid, delivery, timeout \\ :infinity),
    do: GenServer.call(pid, {:stage_delivery, delivery}, timeout)

  @doc false
  def migration_command(pid, operation_id, action, attrs \\ %{}),
    do: GenServer.call(pid, {:migration_command, operation_id, action, attrs}, 30_000)

  def consult(pid, query, request_id, router_agent_id, timeout \\ :infinity),
    do:
      GenServer.call(
        pid,
        {:memory_consultation, query, request_id, router_agent_id},
        timeout
      )

  def stage_wait_timeout(pid, delivery, timeout \\ :infinity),
    do: GenServer.call(pid, {:stage_wait_timeout, delivery}, timeout)

  defp via(agent_id, session_id),
    do: {:via, Registry, {SalixAgent.Registry, key(agent_id, session_id)}}

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)

    with true <- SalixStore.Ids.valid_session_id?(session_id),
         {:ok, records} <- ExternalSessionStore.load_records(agent_id, session_id) do
      data = %__MODULE__{
        agent_id: agent_id,
        session_id: session_id,
        idle_ms:
          Keyword.get(
            opts,
            :idle_ms,
            Application.get_env(:salix_agent, :session_actor_idle_ms, @default_idle_ms)
          ),
        records: records
      }

      data = %{data | startup_recovery_pending: true}

      # Startup repair can route through the Agent owner and therefore re-enter
      # FleetSup. Queue it only after init has acknowledged this child to avoid
      # making the shared DynamicSupervisor wait on itself.
      if Keyword.get(opts, :process_on_init, true), do: send(self(), :process)
      # Generation binding runs as the actor's first act, before :process or
      # any queued command — see handle_continue.
      {:ok, data, {:continue, :bind_runtime_generation}}
    else
      false -> {:stop, :invalid_session_id}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Freeze the ownership epoch this actor runs under (same contract as
  # InternalSessionActor, see its handle_continue: the binding is the
  # actor's own first act so every creation path — the Fleet start funnel
  # AND a supervisor-driven restart of a crashed actor — participates in
  # the lifecycle contract; a registered Server's in-flight claim is waited
  # out so the freeze binds to the installed claim instead of
  # legacy-pinning the replacement).
  @impl true
  def handle_continue(:bind_runtime_generation, data) do
    :ok = SalixAgent.Fleet.await_ownership_installed(data.agent_id)

    case SalixAgent.OwnershipCell.fetch(data.agent_id) do
      {:ok, epoch} ->
        _ =
          Registry.update_value(
            SalixAgent.Registry,
            key(data.agent_id, data.session_id),
            fn _ -> %{runtime_epoch: epoch} end
          )

      _ ->
        :ok
    end

    {:noreply, data}
  end

  @impl true
  def handle_cast(:wake, data) do
    send(self(), :process)
    noreply(data)
  end

  @doc """
  True while the actor holds in-flight work; a call timeout counts as busy,
  a dead actor does not. Used by the root Server's lease keep-alive gate.
  """
  @spec busy?(pid(), timeout()) :: boolean()
  def busy?(pid, timeout \\ 100) when is_pid(pid) do
    GenServer.call(pid, :busy?, timeout)
  catch
    :exit, {:timeout, _} -> true
    :exit, _ -> false
  end

  @impl true
  def handle_call(:busy?, _from, data) do
    reply(not idle?(data), data)
  end

  def handle_call({:migration_command, operation_id, action, attrs}, _from, data) do
    result =
      if action in [:staged, :retiring] and data.pending_external != nil do
        {:error, :migration_dispatch_ack_pending}
      else
        ExternalSessionStore.migration_command(
          data.agent_id,
          data.session_id,
          operation_id,
          action,
          attrs
        )
      end

    data =
      case {action, result} do
        {action, {:ok, _}} when action in [:commit, :cancel] ->
          %{data | failed_dispatch_id: nil}

        _ ->
          data
      end

    {:reply, result, data}
  end

  def handle_call({:stage_delivery, delivery}, _from, data) do
    case scoped_delivery(data.session_id, delivery) do
      {:ok, delivery} ->
        case ExternalSessionStore.stage_delivery(data.agent_id, delivery, data.records) do
          {:ok, :external, _state, records} ->
            send(self(), :process)
            reply({:ok, :committed}, %{data | records: records})

          {:ok, :duplicate} ->
            reply({:ok, :duplicate}, data)

          {:ok, :internal, _state, _records} ->
            reply({:error, :external_runtime_declined_delivery}, data)

          {:error, _} = error ->
            reply(error, data)
        end

      {:error, _} = error ->
        reply(error, data)
    end
  end

  # `memory.ask_worker` is a bounded read of this owner's committed records.
  # The independent LLM job never dispatches input to the native runtime.
  def handle_call({:memory_consultation, query, request_id, router_agent_id}, from, data) do
    if is_map(data.consultation_job) do
      reply({:error, :busy}, data)
    else
      case start_memory_consultation(data, from, query, request_id, router_agent_id) do
        {:ok, data} -> {:noreply, data, :infinity}
        {:error, reason, data} -> reply({:error, reason}, data)
      end
    end
  end

  def handle_call({:begin_session, tenant_id, runtime}, _from, data) do
    case ExternalSessionStore.begin_session(
           data.agent_id,
           data.session_id,
           tenant_id,
           runtime,
           data.records
         ) do
      {:ok, binding, _state, records} -> reply({:ok, binding}, %{data | records: records})
      {:error, _} = error -> reply(error, data)
    end
  end

  def handle_call({:update_session, attrs}, _from, data) do
    case ExternalSessionStore.update_session(data.agent_id, data.session_id, attrs, data.records) do
      {:ok, state, records} -> reply({:ok, state}, %{data | records: records})
      {:error, _} = error -> reply(error, data)
    end
  end

  def handle_call({:accept_session, attrs}, _from, data) do
    attrs = put_source_ids(attrs, tool_source_ids(data))

    case ExternalSessionStore.accept_session(data.agent_id, data.session_id, attrs, data.records) do
      {:ok, :accepted, state, records} ->
        reply({:ok, :accepted, state}, %{data | records: records})

      {:error, _} = error ->
        reply(error, data)
    end
  end

  def handle_call({:complete_session, attrs}, _from, data) do
    case ExternalSessionStore.complete_session(
           data.agent_id,
           data.session_id,
           attrs,
           data.records
         ) do
      {:ok, state, records} -> reply({:ok, state}, %{data | records: records})
      {:error, _} = error -> reply(error, data)
    end
  end

  def handle_call({:fail_session, reason, attrs}, _from, data) do
    case ExternalSessionStore.fail_session(
           data.agent_id,
           data.session_id,
           reason,
           attrs,
           data.records
         ) do
      {:ok, state, records} -> reply({:ok, state}, %{data | records: records})
      {:error, _} = error -> reply(error, data)
    end
  end

  def handle_call({:append_event, attrs}, _from, data) do
    case ExternalSessionStore.append_event(data.agent_id, data.session_id, attrs, data.records) do
      {:ok, state, record, records} ->
        reply({:ok, state, record}, %{data | records: records})

      {:error, _} = error ->
        reply(error, data)
    end
  end

  def handle_call({:commit_session_events, events}, _from, data) do
    case commit_events(data, events) do
      {:ok, state, data} -> reply({:ok, state}, data)
      {:error, reason, data} -> reply({:error, reason}, data)
    end
  end

  def handle_call({:commit_connector_event, capability, params}, _from, data) do
    if capability["agent_id"] == data.agent_id and capability["session_id"] == data.session_id do
      case ExternalSessionStore.commit_connector_event(capability, params, data.records) do
        {:ok, response, records} ->
          data = %{data | records: records}
          reply({:ok, response}, data)

        {:error, reason, records} ->
          data = %{data | records: records}
          reply({:error, reason}, data)

        {:error, _} = error ->
          reply(error, data)
      end
    else
      reply({:error, :stale_external_runtime_session}, data)
    end
  end

  def handle_call({:ssh_start, spec}, _from, data) do
    {result, supervisor} = SalixAgent.SSH.Sessions.start(data.ssh_sessions, spec)
    reply(result, %{data | ssh_sessions: supervisor})
  end

  def handle_call({:execute_tool, tool_name, attrs}, _from, data) do
    case SessionToolExecution.execute(
           data.agent_id,
           data.session_id,
           :external,
           tool_source_ids(data),
           tool_name,
           attrs
         ) do
      {:ok, result, pending_async, events, observed_result} ->
        case commit_events(data, events) do
          {:ok, _state, data} ->
            SessionToolExecution.emit_result(observed_result)

            data =
              Enum.reduce(pending_async, data, fn pending, acc ->
                %{
                  acc
                  | pending_async_tools: Map.put(acc.pending_async_tools, pending.ref, pending)
                }
              end)

            reply({:ok, result}, data)

          {:error, reason, data} ->
            reply({:error, reason}, data)
        end

      {:error, _} = error ->
        reply(error, data)
    end
  end

  def handle_call({:complete_async_tool_call, tool_call_id, result, meta}, _from, data) do
    with {:ok, state} <- ExternalSessionStore.get_session_record(data.agent_id, data.session_id),
         %{} = call <- get_in(state, ["async_tool_calls", tool_call_id]),
         false <- terminal_async?(call["status"]),
         {:ok, events, response, pending, observed_result} <-
           SessionToolExecution.complete_surface(
             data.agent_id,
             data.session_id,
             :external,
             call,
             tool_call_id,
             result,
             meta
           ),
         {:ok, committed_state, data} <- commit_events(data, events) do
      data =
        if committed_terminal_async_call?(committed_state, tool_call_id) do
          retire_terminal_async_tool_owners(data, tool_call_id)
        else
          data
        end

      SessionToolExecution.emit_surface(
        data.agent_id,
        data.session_id,
        tool_call_id,
        observed_result,
        Map.merge(meta, pending)
      )

      send(self(), :process)
      reply({:ok, response}, data)
    else
      true ->
        data = retire_terminal_async_tool_owners(data, tool_call_id)

        reply(
          {:ok,
           %{
             "status" => "resolved",
             "tool_call_id" => tool_call_id,
             "message" => "async tool call is already resolved"
           }},
          data
        )

      nil ->
        reply({:error, :not_found}, data)

      {:error, reason, next_data} ->
        reply({:error, reason}, next_data)

      {:error, _} = error ->
        reply(error, data)
    end
  end

  def handle_call({:update_async_tool_call_progress, tool_call_id, progress}, _from, data) do
    event = %{
      "type" => "async_tool_call_progress",
      "session_id" => data.session_id,
      "tool_call_id" => tool_call_id,
      "progress" => progress,
      "updated_at" => System.system_time(:millisecond)
    }

    case commit_events(data, [event]) do
      {:ok, _state, data} ->
        reply({:ok, %{"status" => "updated", "tool_call_id" => tool_call_id}}, data)

      {:error, reason, data} ->
        reply({:error, reason}, data)
    end
  end

  def handle_call({:stage_wait_timeout, delivery}, _from, data) do
    case stage_wait_timeout_data(data, delivery) do
      {:ok, status, data} ->
        if status == :committed, do: send(self(), :process)
        reply({:ok, status}, data)

      {:error, reason, data} ->
        reply({:error, reason}, data)
    end
  end

  @impl true
  def handle_info(:process, data) do
    data = attempt_startup_recovery(data)

    cond do
      data.startup_recovery_pending -> noreply(data)
      is_nil(data.pending_external) -> noreply(recover_wait_then_dispatch(data))
      true -> noreply(data)
    end
  end

  def handle_info({:starting_deadline, dispatch_id}, data) do
    case ExternalSessionStatus.get(data.agent_id, data.session_id) do
      {:ok,
       %{
         "dispatch_id" => ^dispatch_id,
         "status" => "unknown",
         "issue" => "native_start_unconfirmed"
       }} ->
        SessionActivity.notify(data.agent_id, data.session_id)

      _other ->
        :ok
    end

    noreply(data)
  end

  def handle_info({ref, {:external_runtime, result, duration_ms}}, data)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case data.pending_external do
      %{ref: ^ref} = pending ->
        data = %{data | pending_external: nil}
        noreply(handle_runtime_result(data, pending, result, duration_ms))

      _ ->
        noreply(data)
    end
  end

  def handle_info(
        {:dependency_job_result, token, {:external_runtime, result, duration_ms}},
        %{
          pending_external:
            %{
              dependency_job: %DependencyJob{token: token} = job
            } = pending
        } = data
      ) do
    :ok = DependencyJob.complete(job)
    data = %{data | pending_external: nil}
    noreply(handle_runtime_result(data, pending, result, duration_ms))
  end

  def handle_info(
        {:dependency_job_result, token, {:memory_consultation, result}},
        %{consultation_job: %{dependency_job: %DependencyJob{token: token} = job}} = data
      ) do
    :ok = DependencyJob.complete(job)
    noreply(finish_memory_consultation(data, result))
  end

  def handle_info(
        {:dependency_job_timeout, token},
        %{consultation_job: %{dependency_job: %DependencyJob{token: token} = job}} = data
      ) do
    :ok = DependencyJob.cancel(job, :timeout)
    noreply(finish_memory_consultation(data, {:error, :timeout}))
  end

  def handle_info(
        {:dependency_job_down, token, reason},
        %{consultation_job: %{dependency_job: %DependencyJob{token: token} = job}} = data
      ) do
    :ok = DependencyJob.complete(job)
    noreply(finish_memory_consultation(data, {:error, reason}))
  end

  def handle_info(
        {:dependency_job_timeout, token},
        %{
          pending_external:
            %{
              dependency_job: %DependencyJob{token: token} = job
            } = pending
        } = data
      ) do
    :ok = DependencyJob.cancel(job, :timeout)
    data = %{data | pending_external: nil}

    data =
      handle_runtime_result(data, pending, {:error, {:dependency_timeout, :external_runtime}}, 0)

    noreply(data)
  end

  def handle_info(
        {:dependency_job_down, token, reason},
        %{
          pending_external:
            %{
              dependency_job: %DependencyJob{token: token} = job
            } = pending
        } = data
      ) do
    :ok = DependencyJob.complete(job)
    data = %{data | pending_external: nil}

    data =
      handle_runtime_result(
        data,
        pending,
        {:error, {:dependency_crashed, :external_runtime, reason}},
        0
      )

    noreply(data)
  end

  def handle_info({:dependency_job_result, token, result}, data)
      when is_reference(token) and is_map(result) do
    case Map.get(data.pending_async_tools, token) do
      %{dependency_job: %DependencyJob{token: ^token} = job} = pending ->
        :ok = DependencyJob.complete(job)
        noreply(begin_async_tool_terminal(data, token, pending, result))

      _other ->
        noreply(data)
    end
  end

  def handle_info({:dependency_job_timeout, token}, data) when is_reference(token) do
    case Map.get(data.pending_async_tools, token) do
      %{dependency_job: %DependencyJob{token: ^token} = job} = pending ->
        :ok = DependencyJob.cancel(job, :timeout)

        [result] =
          SalixAgent.InternalAgentRuntime.tool_error_results(
            [pending.call],
            {:dependency_timeout, :tool},
            "timeout"
          )

        noreply(begin_async_tool_terminal(data, token, pending, result))

      _other ->
        noreply(data)
    end
  end

  def handle_info({:dependency_job_down, token, reason}, data) when is_reference(token) do
    case Map.get(data.pending_async_tools, token) do
      %{dependency_job: %DependencyJob{token: ^token} = job} = pending ->
        :ok = DependencyJob.complete(job)

        [result] =
          SalixAgent.InternalAgentRuntime.tool_error_results(
            [pending.call],
            {:dependency_crashed, :tool, reason},
            "crashed"
          )

        noreply(begin_async_tool_terminal(data, token, pending, result))

      _other ->
        noreply(data)
    end
  end

  def handle_info({:dependency_job_result, _token, _result}, data), do: noreply(data)
  def handle_info({:dependency_job_timeout, _token}, data), do: noreply(data)
  def handle_info({:dependency_job_down, _token, _reason}, data), do: noreply(data)

  def handle_info({:retry_async_tool_commit, ref, attempts}, data)
      when is_reference(ref) and is_integer(attempts) and attempts > 0 do
    data =
      case Map.get(data.pending_async_tool_commits, ref) do
        %{pending: pending, result: result} ->
          do_commit_async_result(data, ref, pending, result, attempts)

        nil ->
          data
      end

    noreply(data)
  end

  def handle_info({ref, result}, data) when is_reference(ref) and is_map(result) do
    Process.demonitor(ref, [:flush])

    case Map.get(data.pending_async_tools, ref) do
      nil ->
        noreply(data)

      pending ->
        noreply(begin_async_tool_terminal(data, ref, pending, result))
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, data) do
    case data.pending_external do
      %{ref: ^ref} = pending ->
        data = %{data | pending_external: nil}
        noreply(handle_runtime_result(data, pending, {:error, reason}, 0))

      _ ->
        case Map.get(data.pending_async_tools, ref) do
          nil ->
            noreply(data)

          pending ->
            [result] =
              SalixAgent.InternalAgentRuntime.tool_error_results(
                [pending.call],
                reason,
                "crashed"
              )

            noreply(begin_async_tool_terminal(data, ref, pending, result))
        end
    end
  end

  def handle_info(:timeout, data) do
    if idle?(data), do: {:stop, :normal, data}, else: noreply(data)
  end

  def handle_info(_message, data), do: noreply(data)

  defp attempt_startup_recovery(%{startup_recovery_pending: false} = data), do: data

  defp attempt_startup_recovery(data) do
    case recover_durable_work(data) do
      {:ok, data} -> %{data | startup_recovery_pending: false}
      {:retry, data} -> %{data | startup_recovery_pending: true}
    end
  end

  defp recover_durable_work(data) do
    case ExternalSessionStore.get_session_record(data.agent_id, data.session_id) do
      {:ok, state} ->
        {data, async_status} =
          recover_process_local_async_calls(data, state["async_tool_calls"])

        {data, _context_status} = recover_current_wait(data, state)

        case async_status do
          :complete -> {:ok, data}
          :retry -> {:retry, data}
        end

      {:error, :not_found} ->
        {:ok, data}

      {:error, reason} ->
        Logger.warning(
          "external session #{data.agent_id}/#{data.session_id} recovery read failed: #{inspect(reason)}"
        )

        {:retry, data}
    end
  end

  defp recover_process_local_async_calls(data, calls) when is_map(calls) do
    calls
    |> Map.values()
    |> Enum.filter(&process_local_running_async?/1)
    |> Enum.sort_by(&value(&1, "tool_call_id"))
    |> Enum.reduce({data, :complete}, fn call, {data, status} ->
      case recover_process_local_async_call(data, call) do
        {:ok, data} -> {data, status}
        {:retry, data} -> {data, :retry}
      end
    end)
  end

  defp recover_process_local_async_calls(data, _calls), do: {data, :complete}

  defp recover_process_local_async_call(data, call) do
    pending = restart_pending(data.session_id, call)

    with {:ok, result} <- staged_external_async_result(data.agent_id, data.session_id, pending),
         {:ok, events, _observed_result} <-
           SessionToolExecution.commit_async(
             data.agent_id,
             data.session_id,
             :external,
             pending,
             result
           ),
         {:ok, _state, data} <- commit_events(data, events) do
      {:ok, data}
    else
      {:error, reason, data} ->
        Logger.warning(
          "external session #{data.agent_id}/#{data.session_id} async restart repair commit failed: #{inspect(reason)}"
        )

        {:retry, data}

      {:error, reason} ->
        Logger.warning(
          "external session #{data.agent_id}/#{data.session_id} async restart repair failed: #{inspect(reason)}"
        )

        {:retry, data}
    end
  end

  defp recover_current_wait(data, %{"wait" => %{} = wait}), do: recover_wait(data, wait)
  defp recover_current_wait(data, _state), do: {data, :reusable}

  defp recover_wait(data, wait) do
    deadline_ms = value(wait, "deadline_ms")

    cond do
      is_integer(deadline_ms) and deadline_ms <= System.system_time(:millisecond) ->
        data =
          with {:ok, delivery} <- Waits.timeout_delivery(data.session_id, wait),
               {:ok, _status, data} <- stage_wait_timeout_data(data, delivery) do
            data
          else
            {:error, reason, data} ->
              Logger.warning(
                "external session #{data.agent_id}/#{data.session_id} overdue wait recovery failed: #{inspect(reason)}"
              )

              data

            {:error, reason} ->
              Logger.warning(
                "external session #{data.agent_id}/#{data.session_id} overdue wait is invalid: #{inspect(reason)}"
              )

              data
          end

        {data, :refresh}

      is_integer(deadline_ms) ->
        case Waits.register_timer_for_wait(data.agent_id, data.session_id, wait) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "external session #{data.agent_id}/#{data.session_id} wait timer recovery failed: #{inspect(reason)}"
            )
        end

        {data, :reusable}

      true ->
        {data, :reusable}
    end
  end

  defp stage_wait_timeout_data(data, delivery) do
    payload = delivery_payload(delivery)

    with {:ok, state} <- ExternalSessionStore.get_session_record(data.agent_id, data.session_id),
         %{} = wait <- state["wait"],
         true <- Waits.identity_matches?(wait, value(payload, "wait_id")),
         {:ok, delivery} <-
           scoped_delivery(
             data.session_id,
             delivery
             |> put_delivery_role("runtime")
             |> put_delivery_trusted_origin(wait)
           ),
         {:ok, :external, _state, records} <-
           ExternalSessionStore.stage_delivery(data.agent_id, delivery, data.records) do
      {:ok, :committed, %{data | records: records}}
    else
      false -> {:ok, :ignored, data}
      nil -> {:ok, :ignored, data}
      {:ok, :duplicate} -> {:ok, :duplicate, data}
      {:error, :not_found} -> {:ok, :ignored, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp process_local_running_async?(call) when is_map(call) do
    value(call, "status") in ["running", :running] and
      value(call, "completion_mode") not in ["external_callback", :external_callback]
  end

  defp process_local_running_async?(_call), do: false

  defp restart_pending(session_id, call) do
    %{
      session_id: session_id,
      tool_call_id: value(call, "tool_call_id"),
      tool_name: value(call, "tool_name"),
      trusted_origin: value(call, "trusted_origin"),
      trusted_origins: value(call, "trusted_origins"),
      trusted_origin_source_message_ids: value(call, "trusted_origin_source_message_ids")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp staged_external_async_result(agent_id, session_id, pending) do
    operation_id =
      SalixAgent.WorkspaceEvents.operation_id(
        AsyncToolResults.operation_source(:external),
        agent_id,
        session_id,
        pending.tool_call_id
      )

    case SalixAgent.AgentWorkspace.operation_result(agent_id, operation_id) do
      {:ok, result} ->
        {:ok, SalixAgent.WorkspaceEvents.restore_operation_result(result)}

      {:error, :not_found} ->
        {:ok,
         %{
           id: pending.tool_call_id,
           name: pending.tool_name,
           status: "failed",
           error: true,
           error_class: "runtime_restarted",
           error_message: "async tool call did not complete before runtime restart",
           diagnostic_visibility: "model_only"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recover_wait_then_dispatch(data) do
    case ExternalSessionStore.session_context(data.agent_id, data.session_id) do
      {:ok, session_context} ->
        case recover_current_wait(data, session_context) do
          {data, :refresh} -> maybe_dispatch(data)
          {data, :reusable} -> maybe_dispatch(data, session_context)
        end

      {:error, :not_found} ->
        data

      {:error, reason} ->
        Logger.warning(
          "external session #{data.agent_id}/#{data.session_id} dispatch failed: #{inspect(reason)}"
        )

        data
    end
  end

  defp maybe_dispatch(data) do
    case ExternalSessionStore.session_context(data.agent_id, data.session_id) do
      {:ok, session_context} ->
        maybe_dispatch(data, session_context)

      {:error, :not_found} ->
        data

      {:error, reason} ->
        Logger.warning(
          "external session #{data.agent_id}/#{data.session_id} dispatch failed: #{inspect(reason)}"
        )

        data
    end
  end

  defp maybe_dispatch(data, session_context) do
    queued_messages = session_context["input_messages"] || []

    with true <- actionable_input?(activation_input_messages(queued_messages)),
         {:ok, queued_batch_id} <- input_batch_id(queued_messages),
         # Modeled by FailedBatchCannotRedispatch and
         # FreshInputReleasesFailedBatch in tla/salix/ExternalRuntime.tla.
         # An AgentServer recovery wake can already be in this actor's mailbox
         # when the in-flight dependency reports a terminal dispatch failure.
         # Coalesce that stale wake without consulting lifecycle status; a new
         # durable input changes the deterministic batch id and remains live.
         true <- queued_batch_id != data.failed_dispatch_id,
         {:ok, %{"tenant_id" => tenant_id, "runtime_config" => runtime}} <-
           AgentControl.get_record(data.agent_id),
         {:ok, binding, _state, records} <-
           ExternalSessionStore.begin_session(
             data.agent_id,
             data.session_id,
             tenant_id,
             runtime,
             data.records
           ),
         data = %{data | records: records},
         {:ok, selected, prepared} <- prepare_activation(data),
         input_messages =
           ContextProviders.strip_llm_private_metadata(selected) ++ prepared["messages"],
         system_prompt = prepared["system_prompt"],
         {:ok, batch_id} <- input_batch_id(selected),
         {:ok, queue_fence_id} <- input_batch_id(queued_messages) do
      request = %{
        agent_id: data.agent_id,
        session_id: data.session_id,
        dispatch_id: batch_id,
        binding: binding,
        input_messages: input_messages,
        system_prompt: system_prompt
      }

      source_ids = source_message_ids(request.input_messages)
      started_at = System.system_time(:second)

      steer? =
        case ExternalSessionStore.start_dispatch(
               data.agent_id,
               data.session_id,
               request.dispatch_id,
               binding["connector_run_id"],
               started_at,
               data.records.last_id,
               source_ids
             ) do
          {:ok, status} ->
            schedule_starting_deadline(status)
            status["status"] == "running"

          {:error, :session_migration_in_progress} ->
            :migration_frozen

          {:error, reason} ->
            Logger.warning("external session starting projection failed: #{inspect(reason)}")
            false
        end

      if steer? == :migration_frozen do
        data
      else
        started = System.monotonic_time(:millisecond)

        dependency = fn ->
          result = ExternalRuntime.run(request)
          {:external_runtime, result, System.monotonic_time(:millisecond) - started}
        end

        pending = %{
          session_id: data.session_id,
          dispatch_id: request.dispatch_id,
          steer?: steer?,
          started_at: started_at,
          binding: binding,
          queue_snapshot: selected,
          source_message_ids: source_ids,
          system_prompt: system_prompt,
          activation_delta: %{provider_state: prepared["provider_state"]},
          queue_fence_id: queue_fence_id
        }

        case DependencyJob.start(:external_runtime, tenant_id, dependency) do
          {:ok, job} ->
            CommaLog.log("external_runtime_input_start", %{
              agent_id: data.agent_id,
              session_id: data.session_id,
              dispatch_id: request.dispatch_id,
              device_runtime_id: binding["device_runtime_id"]
            })

            pending =
              Map.merge(pending, %{
                dependency_job: job,
                ref: job.ref,
                pid: job.pid
              })

            %{data | pending_external: pending, failed_dispatch_id: nil}

          {:error, :dependency_saturated} ->
            record_dispatch_failure(data, pending, {:dependency_saturated, :external_runtime})

          {:error, reason} ->
            record_dispatch_failure(data, pending, reason)
        end
      end
    else
      false ->
        data

      {:error, :not_found} ->
        data

      {:error, {:bad_request, message}}
      when message in [
             "runtime_config.device_runtime_id not found",
             "runtime_config.device_runtime_id is not ready"
           ] ->
        case ExternalSessionStore.park_runtime(data.agent_id, data.session_id) do
          {:ok, _state} ->
            # Register first, then recheck once. A READY notification racing
            # the first failed lookup cannot strand the accepted input.
            if not is_map(session_context["runtime_wait"]), do: send(self(), :process)
            data

          {:skip, reason} when reason in [:no_pending_input, :already_waiting] ->
            data

          {:error, reason} ->
            Logger.warning("external runtime wait could not persist: #{inspect(reason)}")
            data
        end

      {:error, reason} ->
        Logger.warning(
          "external session #{data.agent_id}/#{data.session_id} dispatch failed: #{inspect(reason)}"
        )

        data
    end
  end

  defp start_memory_consultation(data, from, query, request_id, router_agent_id) do
    started_at = System.monotonic_time(:millisecond)

    with true <- is_binary(query) and String.trim(query) != "",
         true <- is_binary(request_id) and request_id != "",
         true <- is_binary(router_agent_id) and router_agent_id != "",
         {:ok, %{"tenant_id" => tenant_id}} <- AgentControl.get_record(data.agent_id),
         {:ok, snapshot} <-
           MemoryConsultationRuntime.capture_external(
             data.agent_id,
             data.session_id,
             data.records
           ),
         remaining when remaining > 0 <-
           @memory_consultation_timeout_ms -
             (System.monotonic_time(:millisecond) - started_at) do
      dependency = fn ->
        result =
          MemoryConsultationRuntime.consult_external(
            String.trim(query),
            router_agent_id,
            data.session_id,
            snapshot
          )

        {:memory_consultation, result}
      end

      case DependencyJob.start(:llm, tenant_id, dependency, timeout_ms: remaining) do
        {:ok, job} ->
          pending = %{
            from: from,
            request_id: request_id,
            dependency_job: job
          }

          {:ok, %{data | consultation_job: pending}}

        {:error, :dependency_saturated} ->
          {:error, :busy, data}

        {:error, reason} ->
          {:error, reason, data}
      end
    else
      false -> {:error, :invalid_memory_consultation, data}
      remaining when is_integer(remaining) and remaining <= 0 -> {:error, :timeout, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp finish_memory_consultation(data, response) do
    case data.consultation_job do
      %{from: from} ->
        GenServer.reply(from, response)
        %{data | consultation_job: nil}

      _ ->
        data
    end
  end

  defp prepare_activation(data) do
    with {:ok, context} <- ExternalSessionStore.session_context(data.agent_id, data.session_id),
         {:ok, config} <-
           AgentActor.runtime_session_config(data.agent_id, %{
             platform: context["platform"],
             session_context: context,
             runtime_kind: :external
           }) do
      selected = activation_input_messages(context["input_messages"] || [])
      selected_context = Map.put(context, "input_messages", selected)

      delta =
        case ContextProviders.prepare_activation_delta(selected_context, config) do
          :none -> nil
          {:delta, delta} -> delta
        end

      ExternalSessionStore.prepare_activation_context(
        data.agent_id,
        data.session_id,
        selected,
        delta,
        context["system_prompt"] || config.system_prompt,
        data.records
      )
    end
  end

  defp handle_runtime_result(data, pending, result, duration_ms) do
    CommaLog.log("external_runtime_input_result", %{
      agent_id: data.agent_id,
      session_id: pending.session_id,
      duration_ms: duration_ms
    })

    case result do
      {:accepted, %{"dispatch_id" => dispatch_id}}
      when dispatch_id == pending.dispatch_id ->
        attrs =
          %{
            "queue_snapshot" => pending.queue_snapshot,
            "dispatch_id" => dispatch_id,
            "context_provider_states" =>
              ContextProviders.adopted_provider_state(pending.activation_delta),
            "active_external_source_message_ids" => pending.source_message_ids,
            "system_prompt" => pending.system_prompt,
            "token_hash" => get_in(pending.binding, ["runtime_capability", "token_hash"])
          }

        case ExternalSessionStore.accept_session(
               data.agent_id,
               pending.session_id,
               attrs,
               data.records
             ) do
          {:ok, :accepted, _state, records} ->
            send(self(), :process)
            %{data | records: records}

          {:error, reason} ->
            Logger.warning("external session acceptance failed: #{inspect(reason)}")
            data
        end

      {:error, reason} ->
        record_dispatch_failure(data, pending, reason)

      invalid ->
        Logger.warning("external runtime returned invalid result")
        record_dispatch_failure(data, pending, {:invalid_runtime_result, invalid})
    end
  end

  defp record_dispatch_failure(data, pending, reason) do
    terminal = not pending.steer?

    ExternalSessionLifecycleObservation.runtime_failure(reason, %{
      agent_id: data.agent_id,
      session_id: pending.session_id,
      connector_run_id: pending.binding["connector_run_id"],
      dispatch_id: pending.dispatch_id,
      terminal: terminal
    })

    attrs = %{"dispatch_id" => pending.dispatch_id, "terminal" => terminal}

    case ExternalSessionStore.fail_session(
           data.agent_id,
           pending.session_id,
           reason,
           attrs,
           data.records
         ) do
      {:ok, _state, records} ->
        failed_dispatch_id =
          if terminal, do: Map.get(pending, :queue_fence_id, pending.dispatch_id), else: nil

        %{data | records: records, failed_dispatch_id: failed_dispatch_id}

      {:error, record_reason} ->
        Logger.warning("external runtime error record failed: #{inspect(record_reason)}")
        %{data | failed_dispatch_id: nil}
    end
  end

  defp begin_async_tool_terminal(data, ref, pending, result) do
    if async_terminal?(data.agent_id, pending) do
      data = delete_pending_async_tool(data, ref)
      send(self(), :process)
      data
    else
      retired_pending = retire_dependency_identity(pending)

      # Archive boundary 5, async arm — the external-runtime mirror of
      # InternalSessionActor.begin_async_tool_terminal/4. Without it these
      # sessions archived the tool CALL and an async_running stub and never the
      # answer, which reads worse than absence: it looks like the tool never
      # completed.
      SalixAgent.EventArchive.Emit.async_tool_result(
        data.agent_id,
        retired_pending[:session_id] || retired_pending["session_id"],
        retired_pending,
        result
      )

      data
      |> delete_pending_async_tool(ref)
      |> retain_async_tool_terminal(ref, retired_pending, result)
      |> do_commit_async_result(ref, retired_pending, result)
    end
  end

  defp retire_dependency_identity(pending) when is_map(pending) do
    Map.drop(pending, [:dependency_job, :ref, :pid])
  end

  defp retain_async_tool_terminal(data, ref, pending, result) do
    commit = %{pending: retire_dependency_identity(pending), result: result}

    %{
      data
      | pending_async_tool_commits: Map.put(data.pending_async_tool_commits, ref, commit)
    }
  end

  @async_commit_retry_ms 1_000
  @async_commit_retry_budget 60

  defp do_commit_async_result(data, ref, pending, result, attempts \\ 0) do
    if async_terminal?(data.agent_id, pending) do
      data = delete_pending_async_tool_commit(data, ref)
      send(self(), :process)
      data
    else
      attempt_async_tool_commit(data, ref, pending, result, attempts)
    end
  end

  defp attempt_async_tool_commit(data, ref, pending, result, attempts) do
    case SessionToolExecution.commit_async(
           data.agent_id,
           pending.session_id,
           :external,
           pending,
           result
         ) do
      {:ok, events, observed_result} ->
        case commit_events(data, events) do
          {:ok, _state, data} ->
            SessionToolExecution.emit_async(data.agent_id, pending, observed_result)
            data = delete_pending_async_tool_commit(data, ref)
            send(self(), :process)
            data

          {:error, reason, data} when attempts < @async_commit_retry_budget ->
            schedule_async_tool_commit_retry(data, ref, attempts, :commit, reason)

          {:error, reason, data} ->
            Logger.error(
              "external async tool result commit exhausted its retry budget; " <>
                "terminal result lost: #{inspect(reason)}"
            )

            delete_pending_async_tool_commit(data, ref)
        end

      {:error, reason} when attempts < @async_commit_retry_budget ->
        schedule_async_tool_commit_retry(data, ref, attempts, :staging, reason)

      {:error, reason} ->
        Logger.error(
          "external async tool result staging exhausted its retry budget; " <>
            "terminal result lost: #{inspect(reason)}"
        )

        delete_pending_async_tool_commit(data, ref)
    end
  end

  defp schedule_async_tool_commit_retry(data, ref, attempts, phase, reason) do
    Logger.warning(
      "external async tool result #{phase} failed (attempt #{attempts + 1}); " <>
        "retaining the terminal result for retry: #{inspect(reason)}"
    )

    Process.send_after(
      self(),
      {:retry_async_tool_commit, ref, attempts + 1},
      @async_commit_retry_ms
    )

    data
  end

  defp commit_events(data, []) do
    case ExternalSessionStore.get_session_record(data.agent_id, data.session_id) do
      {:ok, state} -> {:ok, state, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp commit_events(data, events) do
    case ExternalSessionStore.commit_session_events(
           data.agent_id,
           data.session_id,
           events,
           data.records
         ) do
      {:ok, state, records} ->
        register_timers(data.agent_id, events)
        {:ok, state, %{data | records: records}}

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp register_timers(agent_id, events) do
    case SalixAgent.Waits.register_timers_from_events(agent_id, events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("external session timer registration failed: #{inspect(reason)}")
        :ok
    end
  end

  # Modeled in tla/salix/ExternalRuntimeToolWake.tla. A callback terminal can
  # commit before the process-local setup dependency returns its handoff. The
  # exact durable terminal owns that race; the late local result only retires
  # process-local work and must not create another wait or delivery.
  defp async_terminal?(agent_id, pending) do
    with {:ok, state} <- ExternalSessionStore.get_session_record(agent_id, pending.session_id),
         %{"status" => status} <- get_in(state, ["async_tool_calls", pending.tool_call_id]),
         true <- terminal_async?(status) do
      true
    else
      _ -> false
    end
  end

  defp committed_terminal_async_call?(state, tool_call_id) when is_map(state) do
    calls = value(state, "async_tool_calls") || %{}

    case Map.get(calls, tool_call_id) do
      %{} = call -> terminal_async?(value(call, "status"))
      _other -> false
    end
  end

  defp committed_terminal_async_call?(_state, _tool_call_id), do: false

  # Modeled in tla/salix/ExternalRuntimeToolWake.tla. A durable callback
  # terminal and revocation of every matching process-local producer are one
  # actor-owned transition. Queued result, timeout, down, and retained-retry
  # messages then stay stale because their exact map identities are gone.
  defp retire_terminal_async_tool_owners(data, tool_call_id) do
    pending_async_tools =
      Enum.reduce(data.pending_async_tools, data.pending_async_tools, fn {ref, pending}, acc ->
        if exact_async_tool_owner?(pending, data.session_id, tool_call_id) do
          demonitor_pending_async_tool(ref, pending)
          stop_pending_async_tool(pending)
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    pending_async_tool_commits =
      Enum.reduce(
        data.pending_async_tool_commits,
        data.pending_async_tool_commits,
        fn {ref, commit}, acc ->
          if exact_async_tool_owner?(value(commit, "pending"), data.session_id, tool_call_id),
            do: Map.delete(acc, ref),
            else: acc
        end
      )

    %{
      data
      | pending_async_tools: pending_async_tools,
        pending_async_tool_commits: pending_async_tool_commits
    }
  end

  defp exact_async_tool_owner?(pending, session_id, tool_call_id) when is_map(pending) do
    value(pending, "session_id") == session_id and
      value(pending, "tool_call_id") == tool_call_id
  end

  defp exact_async_tool_owner?(_pending, _session_id, _tool_call_id), do: false

  defp demonitor_pending_async_tool(ref, pending) do
    [ref, value(pending, "ref")]
    |> Enum.filter(&is_reference/1)
    |> Enum.uniq()
    |> Enum.each(&Process.demonitor(&1, [:flush]))

    :ok
  end

  defp stop_pending_async_tool(pending) do
    case value(pending, "dependency_job") do
      %DependencyJob{} = job ->
        DependencyJob.cancel(job)

      _other ->
        case value(pending, "pid") do
          pid when is_pid(pid) ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
            :ok

          _other ->
            :ok
        end
    end
  end

  defp actionable_input?(messages),
    do:
      Enum.any?(
        List.wrap(messages),
        &(&1["role"] in ["summary", "user", "runtime"] and &1["no_wake"] != true)
      )

  # FORMAL-SPEC: tla/salix/ExternalRuntime.tla BeginDispatch.
  # The Connector accepts and the Server removes this exact ordered prefix.
  # Provider-backed user wakeables are dispatched one at a time so the
  # runtime's singular current source cannot be replaced by a later provider
  # message. Runtime completions carrying inherited provenance stay in the
  # selected prefix so the current activation can make progress.
  defp activation_input_messages(messages) do
    messages = List.wrap(messages)

    case Enum.find_index(messages, &external_provider_wakeable_message?/1) do
      nil -> messages
      index -> Enum.take(messages, index + 1)
    end
  end

  defp external_provider_wakeable_message?(message) when is_map(message) do
    message["role"] == "user" and actionable_input?([message]) and
      external_provider_origin?(message["trusted_origin"])
  end

  defp external_provider_wakeable_message?(_message), do: false

  defp external_provider_origin?(origin) when is_map(origin) do
    provider = origin["provider"] || origin[:provider]
    provider = provider |> to_string() |> String.trim()
    provider != "" and provider != "internal"
  end

  defp external_provider_origin?(_origin), do: false

  defp source_message_ids(messages) do
    messages = List.wrap(messages)

    ids =
      Enum.flat_map(messages, fn message ->
        cond do
          message["role"] == "user" and is_binary(message["source_message_id"]) ->
            [message["source_message_id"]]

          message["role"] == "runtime" and
              SalixAgent.ToolCallProvenance.origins(message) != [] ->
            List.wrap(message["trusted_origin_source_message_ids"])

          true ->
            []
        end
      end)

    ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp input_batch_id(messages) when is_list(messages) and messages != [] do
    ids = Enum.map(messages, & &1["id"])

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
      {:ok, "batch-" <> List.last(ids)}
    else
      {:error, :external_runtime_input_id_missing}
    end
  end

  defp input_batch_id(_messages), do: {:error, :external_runtime_input_empty}

  defp tool_source_ids(data) do
    if is_map(data.pending_external), do: data.pending_external.source_message_ids, else: []
  end

  defp put_source_ids(attrs, source_ids),
    do: Map.put(attrs, "active_external_source_message_ids", source_ids)

  defp scoped_delivery(session_id, delivery) do
    payload = delivery_payload(delivery)
    delivery_session_id = value(payload, "session_id") || session_id

    if delivery_session_id == session_id do
      {:ok, put_delivery_payload(delivery, Map.put(payload, "session_id", session_id))}
    else
      {:error, {:session_mismatch, session_id, delivery_session_id}}
    end
  end

  defp put_delivery_role(delivery, role) do
    payload = Map.put(delivery_payload(delivery), "role", role)
    put_delivery_payload(delivery, payload)
  end

  defp put_delivery_trusted_origin(delivery, source) do
    payload =
      delivery
      |> delivery_payload()
      |> SalixAgent.ToolCallProvenance.inherit(source)

    put_delivery_payload(delivery, payload)
  end

  defp delivery_payload(delivery), do: value(delivery, "payload") || %{}

  defp put_delivery_payload(delivery, payload) do
    cond do
      Map.has_key?(delivery, "payload") -> Map.put(delivery, "payload", payload)
      Map.has_key?(delivery, :payload) -> Map.put(delivery, :payload, payload)
      true -> Map.put(delivery, "payload", payload)
    end
  end

  defp terminal_async?(status), do: status in ["completed", "failed", "cancelled"]

  defp idle?(data),
    do:
      is_nil(data.pending_external) and is_nil(data.consultation_job) and
        map_size(data.pending_async_tools) == 0 and
        map_size(data.pending_async_tool_commits) == 0 and
        not SalixAgent.SSH.Sessions.live?(data.ssh_sessions)

  defp delete_pending_async_tool(data, ref) do
    %{data | pending_async_tools: Map.delete(data.pending_async_tools, ref)}
  end

  defp delete_pending_async_tool_commit(data, ref) do
    %{
      data
      | pending_async_tool_commits: Map.delete(data.pending_async_tool_commits, ref)
    }
  end

  # One actor owns at most one external dispatch at a time.  The timer is an
  # invalidation hint for exact-session subscribers; the authoritative read
  # still derives the deadline transition from the persisted status object.
  defp schedule_starting_deadline(%{
         "status" => "starting",
         "dispatch_id" => dispatch_id,
         "starting_expires_at" => expires_at
       })
       when is_binary(dispatch_id) and is_integer(expires_at) do
    delay_ms = max(expires_at - System.system_time(:second), 0) * 1_000 + 50
    Process.send_after(self(), {:starting_deadline, dispatch_id}, delay_ms)
    :ok
  end

  defp schedule_starting_deadline(_status), do: :ok

  defp noreply(data), do: {:noreply, data, idle_timeout(data)}
  defp reply(response, data), do: {:reply, response, data, idle_timeout(data)}
  defp idle_timeout(data), do: if(idle?(data), do: data.idle_ms, else: :infinity)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp value(_map, _key), do: nil
end
