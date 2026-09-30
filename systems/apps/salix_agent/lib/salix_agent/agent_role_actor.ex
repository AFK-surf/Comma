defmodule SalixAgent.AgentRoleActor do
  @moduledoc """
  Node-local owner process for one agent's agent-level resources.

  `SalixAgent.AgentActor` routes to the agent owner node and reaches this
  process only for work that must be ordered per agent:

    * delivery staging, tracked so a Router session switch can wait for it;
    * workspace operations, which `SalixAgent.AgentWorkspace` requires to run
      inside this process;
    * conversation-source consumption, one in-flight source task per agent;
    * for a Router, the canonical-session switch barrier and the canonical
      read-then-start of its internal session actor.

  Stateless session commands and configuration reads do not pass through
  this mailbox; the facade runs them in bounded reply tasks. The role comes
  from the agent record when the process starts. Router, worker and meeting
  agents share this process; only a Router switches canonical sessions.
  """

  use GenServer

  alias SalixAgent.AgentActor.SessionDelivery
  alias SalixAgent.{AgentControl, InternalSessionActor, InternalSessionStore}
  alias SalixStore.Ids

  defstruct [
    :agent_id,
    :agent,
    :role,
    :switch_pending,
    :source_task,
    :source_result,
    :source_ref,
    source_progress: %{},
    source_pending: [],
    stage_tasks: %{}
  ]

  def child_spec(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    %{
      id: {__MODULE__, agent_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: SalixAgent.AgentActor.via(agent_id))
  end

  @doc false
  def stage_delivery(pid, entry, timeout)
      when is_pid(pid) and is_map(entry) and
             (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    request_id = make_ref()
    # The staged reply task continues this chain in another process; it
    # starts from the control records this process already read.
    read_scope = SalixStore.ReadScope.capture() || %{}

    try do
      GenServer.call(pid, {:stage_delivery, request_id, entry, read_scope}, timeout)
    catch
      :exit, reason ->
        # A timed-out GenServer.call only abandons its reply alias; it does not
        # retract the request already sitting in the actor mailbox. Give the
        # role actor the exact request identity so it can kill the tracked
        # staging task when that task has not already reached durability.
        GenServer.cast(pid, {:cancel_stage_delivery, request_id})
        {:error, normalize_stage_call_exit(reason)}
    end
  end

  @doc false
  def commit_workspace_operation(pid, operation_id, result, events, timeout \\ :infinity)
      when is_pid(pid) and is_binary(operation_id) and is_list(events) do
    GenServer.call(pid, {:commit_workspace_operation, operation_id, result, events}, timeout)
  end

  @doc false
  def prepare_workspace_operation(pid, operation_id, result, events, opts, timeout \\ :infinity)
      when is_pid(pid) and is_binary(operation_id) and is_list(events) and is_list(opts) do
    GenServer.call(
      pid,
      {:prepare_workspace_operation, operation_id, result, events, opts},
      timeout
    )
  end

  @doc false
  def commit_prepared_workspace_operation(pid, prepared, timeout \\ :infinity)
      when is_pid(pid) do
    GenServer.call(pid, {:commit_prepared_workspace_operation, prepared}, timeout)
  end

  @doc false
  def stop_runtime(pid, reason, timeout \\ :infinity) when is_pid(pid) do
    GenServer.call(pid, {:stop_runtime, reason}, timeout)
  end

  @doc false
  def switch_canonical_session(pid, expected_session_id, timeout \\ :infinity)
      when is_pid(pid) and is_binary(expected_session_id) do
    GenServer.call(pid, {:switch_canonical_session, expected_session_id}, timeout)
  end

  @doc false
  def admit_canonical_session(pid, session_id, timeout \\ :infinity)
      when is_pid(pid) and is_binary(session_id) do
    GenServer.call(pid, {:admit_canonical_session, session_id}, timeout)
  catch
    :exit, reason -> {:error, {:router_owner_unavailable, reason}}
  end

  @doc false
  def ensure_canonical_session_started(pid, session_id, opts, timeout \\ :infinity)
      when is_pid(pid) and is_binary(session_id) and is_list(opts) do
    GenServer.call(pid, {:ensure_canonical_session_started, session_id, opts}, timeout)
  catch
    :exit, reason -> {:error, {:router_owner_unavailable, reason}}
  end

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent = Keyword.get(opts, :agent, %{})
    role = agent["role"]

    if role == "router", do: SalixAgent.RouterRequestMonitor.register(agent_id, self())

    {:ok, %__MODULE__{agent_id: agent_id, agent: agent, role: role}}
  end

  @impl true
  def handle_call(
        {:stage_delivery, _request_id, _entry, _read_scope},
        _from,
        %{switch_pending: pending} = data
      )
      when not is_nil(pending) do
    {:reply, {:error, :router_session_switching}, data}
  end

  def handle_call({:stage_delivery, request_id, entry, read_scope}, from, data) do
    owner = self()

    data =
      begin_stage_reply(data, request_id, from, fn -> stage(data, entry, owner) end, read_scope)

    {:noreply, data}
  end

  def handle_call({:commit_workspace_operation, operation_id, result, events}, _from, data) do
    {:reply,
     SalixAgent.AgentWorkspace.commit_operation(data.agent_id, operation_id, result, events),
     data}
  end

  def handle_call(
        {:prepare_workspace_operation, operation_id, result, events, opts},
        _from,
        data
      ) do
    {:reply,
     SalixAgent.AgentWorkspace.prepare_operation(
       data.agent_id,
       operation_id,
       result,
       events,
       opts
     ), data}
  end

  def handle_call({:commit_prepared_workspace_operation, prepared}, _from, data) do
    {:reply, SalixAgent.AgentWorkspace.commit_prepared_operation(prepared), data}
  end

  def handle_call({:stop_runtime, _reason}, _from, data) do
    :ok = SalixAgent.Fleet.stop_local_session_actors(data.agent_id)
    {:stop, :normal, :ok, data}
  end

  def handle_call({request, _session_id}, _from, %{role: role} = data)
      when request in [:switch_canonical_session, :admit_canonical_session] and
             role != "router" do
    {:reply, {:error, {:unsupported_agent_role, role}}, data}
  end

  def handle_call(
        {:ensure_canonical_session_started, _session_id, _opts},
        _from,
        %{role: role} = data
      )
      when role != "router" do
    {:reply, {:error, {:unsupported_agent_role, role}}, data}
  end

  def handle_call(
        {:switch_canonical_session, _expected_session_id},
        _from,
        %{switch_pending: pending} = data
      )
      when not is_nil(pending) do
    {:reply, {:error, :router_session_switching}, data}
  end

  def handle_call(
        {:switch_canonical_session, expected_session_id},
        from,
        %{source_task: task} = data
      )
      when not is_nil(task) do
    {:noreply, %{data | switch_pending: {from, expected_session_id}}}
  end

  def handle_call({:switch_canonical_session, expected_session_id}, from, data)
      when map_size(data.stage_tasks) > 0 do
    {:noreply, %{data | switch_pending: {from, expected_session_id}}}
  end

  def handle_call({:switch_canonical_session, expected_session_id}, _from, data) do
    case rotate_canonical_session(data, expected_session_id) do
      {:ok, result, next_data} -> {:reply, {:ok, result}, next_data}
      {:error, reason, next_data} -> {:reply, {:error, reason}, next_data}
      {:error, reason} -> {:reply, {:error, reason}, data}
    end
  end

  def handle_call(
        {:admit_canonical_session, _session_id},
        _from,
        %{switch_pending: pending} = data
      )
      when not is_nil(pending) do
    {:reply, {:error, :router_session_switching}, data}
  end

  def handle_call({:admit_canonical_session, session_id}, _from, data) do
    result =
      case router_session_id(data) do
        {:ok, ^session_id} -> :ok
        {:ok, current_session_id} -> {:error, {:retired_router_session, current_session_id}}
        {:error, _} = error -> error
      end

    {:reply, result, data}
  end

  def handle_call(
        {:ensure_canonical_session_started, _session_id, _opts},
        _from,
        %{switch_pending: pending} = data
      )
      when not is_nil(pending) do
    {:reply, {:error, :router_session_switching}, data}
  end

  def handle_call({:ensure_canonical_session_started, session_id, opts}, _from, data) do
    case start_canonical_session_actor(data, session_id, opts) do
      {:ok, pid, current_agent} ->
        {:reply, {:ok, pid}, %{data | agent: current_agent}}

      {:error, reason, current_agent} ->
        {:reply, {:error, reason}, %{data | agent: current_agent}}

      {:error, reason} ->
        {:reply, {:error, reason}, data}
    end
  end

  @impl true
  def handle_cast({:conversation_source, source, scope}, data) do
    {:noreply, SalixAgent.ConversationConsumer.notify(data, source, scope)}
  end

  def handle_cast({:conversation_source, source}, data) do
    {:noreply, SalixAgent.ConversationConsumer.notify(data, source)}
  end

  def handle_cast({:cancel_stage_delivery, request_id}, data) do
    data = cancel_stage_reply_and_await_down(data, request_id)
    {:noreply, maybe_finish_pending_switch(data)}
  end

  @impl true
  def handle_info({:retry_conversation_source, source}, data) do
    {:noreply, SalixAgent.ConversationConsumer.notify(data, source)}
  end

  def handle_info({{:conversation_consumed, source}, result}, %{source_ref: source} = data) do
    {:noreply, SalixAgent.ConversationConsumer.complete(data, result)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{source_task: {pid, ref}} = data) do
    data = data |> SalixAgent.ConversationConsumer.finish() |> maybe_finish_pending_switch()
    {:noreply, SalixAgent.ConversationConsumer.start(data)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, data) do
    data = finish_stage_reply(data, monitor_ref)
    {:noreply, data |> maybe_finish_pending_switch() |> SalixAgent.ConversationConsumer.start()}
  end

  defp stage(%{role: "router"} = data, entry, owner) do
    # Re-register on new traffic after an observational-process restart.
    SalixAgent.RouterRequestMonitor.register(data.agent_id, owner)

    with {:ok, entry} <- resolve_router_session(data, entry) do
      SessionDelivery.stage(data.agent_id, entry, router_owner: owner)
    end
  end

  defp stage(data, entry, _owner), do: SessionDelivery.stage(data.agent_id, entry)

  defp begin_stage_reply(data, request_id, from, fun, read_scope) do
    fun = fn -> SalixStore.ReadScope.run(read_scope, fun) end

    case start_stage_task(from, fun) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)
        stage_tasks = Map.put(data.stage_tasks, request_id, {pid, monitor_ref})
        %{data | stage_tasks: stage_tasks}

      :error ->
        data
    end
  end

  defp start_stage_task(from, fun) do
    case SalixAgent.AgentReplyTask.start_stage(from, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        GenServer.reply(from, {:error, {:agent_actor_reply_task_failed, reason}})
        :error
    end
  catch
    :exit, reason ->
      GenServer.reply(from, {:error, {:agent_actor_reply_task_failed, reason}})
      :error
  end

  defp finish_stage_reply(data, monitor_ref) do
    case Enum.find(data.stage_tasks, fn {_request_id, {_pid, ref}} -> ref == monitor_ref end) do
      {request_id, _task} -> %{data | stage_tasks: Map.delete(data.stage_tasks, request_id)}
      nil -> data
    end
  end

  # A kill signal is asynchronous. Keep the task in the barrier until its
  # monitor confirms termination; dropping it here would let a cutover race
  # the task's last store or actor-start operation.
  defp cancel_stage_reply_and_await_down(data, request_id) do
    case Map.get(data.stage_tasks, request_id) do
      {pid, _monitor_ref} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        data

      nil ->
        data
    end
  end

  defp resolve_router_session(data, entry) do
    payload = entry[:payload] || entry["payload"] || %{}

    with {:ok, session_id} <- router_session_id(data) do
      {:ok, put_payload(entry, put_router_session_id(payload, session_id))}
    end
  end

  defp router_session_id(data) do
    SalixStore.RuntimeIds.persisted_router_session_id(data.agent)
  end

  # The durable canonical read and actor start stay inside one Router-owner
  # call. A switch cannot pass either stop/CAS boundary between them.
  defp start_canonical_session_actor(data, session_id, opts) do
    with {:ok, current_agent} <- AgentControl.get_record(data.agent_id),
         {:ok, ^session_id} <-
           SalixStore.RuntimeIds.persisted_router_session_id(current_agent),
         :ok <- run_session_start_test_barrier(data.agent_id, session_id),
         {:ok, pid} <- start_internal_session_actor(opts) do
      {:ok, pid, current_agent}
    else
      {:ok, current_session_id} ->
        {:error, {:retired_router_session, current_session_id}, refresh_agent_record(data)}

      {:error, _} = error ->
        error
    end
  end

  # Actor creation goes through Fleet.start_session_actor — THE
  # generation-qualified start boundary — like every other path: a new
  # actor's immutable generation must bind to the installed claim, not race
  # a registered Server's in-flight claim and be legacy-pinned (which would
  # fence valid Router recovery work forever).
  defp start_internal_session_actor(opts),
    do: SalixAgent.Fleet.start_session_actor(InternalSessionActor, opts)

  # Deterministic test seam for the canonical-read -> start-child boundary.
  # Production has no configured callback.
  defp run_session_start_test_barrier(agent_id, session_id) do
    case Application.get_env(:salix_agent, :router_session_start_test_barrier) do
      fun when is_function(fun, 2) -> fun.(agent_id, session_id)
      _other -> :ok
    end
  end

  defp refresh_agent_record(data) do
    case AgentControl.get_record(data.agent_id) do
      {:ok, agent} -> agent
      {:error, _reason} -> data.agent
    end
  end

  # Delivery staging tasks re-enter this actor for canonical admission. A
  # switch rejects later admissions and waits for every already-admitted task
  # to exit, so no task can restart the retired SessionActor after the stop.
  # Future recovery wakes are rejected by InternalSessionFleet's durable
  # canonical admission check.
  defp rotate_canonical_session(data, expected_session_id) do
    with {:ok, current_agent} <- AgentControl.get_record(data.agent_id),
         {:ok, ^expected_session_id} <-
           SalixStore.RuntimeIds.persisted_router_session_id(current_agent),
         new_session_id = Ids.new_session_id(),
         {:ok, source} <-
           SalixAgent.ConversationConsumer.reset_source(
             data.agent_id,
             expected_session_id,
             new_session_id
           ),
         {:ok, _session} <-
           InternalSessionStore.prepare_create(data.agent_id, new_session_id, %{
             "conversation_sources" => source
           }),
         :ok <- stop_internal_session(data.agent_id, expected_session_id),
         {:ok, updated_agent} <-
           AgentControl.switch_router_session_record(
             data.agent_id,
             expected_session_id,
             new_session_id
           ),
         :ok <- stop_internal_session(data.agent_id, expected_session_id) do
      SalixAgent.RouterRequestMonitor.clear_session(data.agent_id, expected_session_id)

      result = %{
        "agent_id" => data.agent_id,
        "previous_session_id" => expected_session_id,
        "router_session_id" => new_session_id
      }

      {:ok, result, %{data | agent: updated_agent}}
    else
      {:ok, current_session_id} ->
        {:error, {:stale_router_session, current_session_id}, refresh_agent(data)}

      {:error, {:stale_router_session, _current_session_id} = reason} ->
        {:error, reason, refresh_agent(data)}

      {:error, _} = error ->
        error
    end
  end

  defp refresh_agent(data) do
    case AgentControl.get_record(data.agent_id) do
      {:ok, agent} -> %{data | agent: agent}
      {:error, _reason} -> data
    end
  end

  defp maybe_finish_pending_switch(%{switch_pending: nil} = data), do: data

  defp maybe_finish_pending_switch(%{source_task: task} = data) when not is_nil(task), do: data

  defp maybe_finish_pending_switch(%{stage_tasks: stage_tasks} = data)
       when map_size(stage_tasks) > 0,
       do: data

  defp maybe_finish_pending_switch(
         %{
           switch_pending: {from, expected_session_id}
         } = data
       ) do
    data = %{data | switch_pending: nil}

    case rotate_canonical_session(data, expected_session_id) do
      {:ok, result, next_data} ->
        GenServer.reply(from, {:ok, result})
        next_data

      {:error, reason, next_data} ->
        GenServer.reply(from, {:error, reason})
        next_data

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        data
    end
  end

  defp stop_internal_session(agent_id, session_id) do
    SalixAgent.Fleet.stop(InternalSessionActor.key(agent_id, session_id))
  end

  defp put_payload(map, payload) do
    map
    |> Map.delete(:payload)
    |> Map.delete("payload")
    |> Map.put(:payload, payload)
  end

  defp put_router_session_id(payload, session_id) when is_map(payload) do
    payload
    |> Map.delete(:session_id)
    |> Map.delete("session_id")
    |> Map.put(:session_id, session_id)
    |> Map.put("session_id", session_id)
  end

  defp normalize_stage_call_exit({:timeout, _call}), do: :stage_timeout
  defp normalize_stage_call_exit(:timeout), do: :stage_timeout
  defp normalize_stage_call_exit({:noproc, _call}), do: :stage_unavailable
  defp normalize_stage_call_exit(:noproc), do: :stage_unavailable
  defp normalize_stage_call_exit(reason), do: {:stage_call_exit, reason}
end
