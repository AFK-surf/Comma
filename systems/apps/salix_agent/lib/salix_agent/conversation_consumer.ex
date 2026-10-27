defmodule SalixAgent.ConversationConsumer do
  @moduledoc false

  alias SalixAgent.{
    AgentActor,
    InternalSession,
    InternalSessionStore,
    RetiredSessions,
    SessionBirth
  }

  alias SalixAgent.AgentActor.SessionDelivery

  def adapter, do: SystemsRuntime.get_env(:salix_agent, :conversation_source_mod)

  def consume(agent_id, source, owner, cached_progress \\ nil) do
    started = SystemsClock.monotonic_time()

    result =
      SalixStore.ReadScope.run(fn ->
        if SalixAgent.Fleet.server_running?(agent_id) do
          case do_consume(agent_id, source, owner, cached_progress) do
            {:error, {:agent_owner_remote, _node}} -> redirect(agent_id, source)
            result -> result
          end
        else
          redirect(agent_id, source)
        end
      end)

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "conversation_log_consume",
      "salix",
      if(result == :redirected or match?({status, _} when status in [:done, :more], result),
        do: "ok",
        else: "error"
      ),
      SystemsClock.monotonic_time() - started
    )

    result
  end

  # A role actor may survive root Server passivation.
  # Forward the source hint so the current owner loads its own frontier and
  # applies its canonical-session fence. Never forward the old actor PID.
  defp redirect(agent_id, source) do
    with :ok <- AgentActor.notify_conversation(agent_id, source), do: :redirected
  end

  defp do_consume(agent_id, source, owner, cached_progress) do
    with adapter when is_atom(adapter) and not is_nil(adapter) <- adapter(),
         :ok <- adapter.prefetch(agent_id),
         {:ok, binding} <- adapter.binding(agent_id, source) do
      consume_binding(adapter, agent_id, source, owner, cached_progress, binding)
    else
      nil -> :done
      error -> error
    end
  end

  defp consume_binding(adapter, agent_id, source, owner, cached_progress, binding) do
    with {:ok, progress, runtime} <-
           current_progress(agent_id, binding, cached_progress, owner, source),
         {:ok, binding, messages} <- adapter.batch(binding, progress) do
      observe_source(binding, progress, messages)

      Enum.reduce_while(messages, {:done, {progress, runtime}}, fn message, _ ->
        with {:ok, entry} <-
               admit(
                 adapter,
                 agent_id,
                 source,
                 binding,
                 message,
                 owner,
                 runtime,
                 {3, retry_deadline()}
               ) do
          {:cont,
           {if(message["seq"] < binding.conversation["message_tail_seq"], do: :more, else: :done),
            {entry.conversation_source, runtime}}}
        else
          false -> {:halt, {:error, :conversation_source_retired}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :conversation_source_retired} -> retire_source(adapter, binding)
      error -> error
    end
  end

  # This task dies after the AgentReplyTask timeout, and a killed task neither
  # admits nor rejects the message: the source is retried with the same head
  # forever and every later message of the Conversation waits behind it. A
  # slow failure (a local-file import uses its whole 60 s read lease) therefore
  # retries only while the first quarter of that timeout lasts, so one message
  # always settles, admitted or rejected, inside one task.
  defp retry_deadline,
    do:
      SystemsClock.monotonic_time(:millisecond) +
        div(SalixAgent.AgentReplyTask.timeout_ms(), 4)

  defp admit(adapter, agent, source, binding, message, owner, runtime, {attempts, retry_until}) do
    result =
      safe_admission(fn ->
        with {:ok, current} <- adapter.binding(agent, source),
             true <- same_binding?(binding, current),
             :ok <- SalixAgent.Control.ensure_not_stopped(agent),
             {:ok, entry} <- adapter.entry(binding, message),
             entry = stamp_input_time(entry),
             :ok <- wake(agent, stage(agent, entry, owner, binding, runtime)) do
          {:ok, entry}
        end
      end)

    case result do
      {:ok, _} ->
        result

      false ->
        {:error, :conversation_source_retired}

      {:error, :conversation_source_retired} ->
        retire_source(adapter, binding)

      {:error, {:agent_owner_remote, _node}} ->
        result

      {:error, :source_busy} ->
        SalixAgent.InternalSessionActor.watch_source(agent, binding.session_id, owner, source)
        result

      {:error, :saturated} ->
        result

      {:error, _, false} ->
        reject(adapter, agent, binding, message, result, owner, runtime)

      _ ->
        if attempts > 1 and SystemsClock.monotonic_time(:millisecond) < retry_until do
          SystemsClock.sleep(100)
          retry = {attempts - 1, retry_until}
          admit(adapter, agent, source, binding, message, owner, runtime, retry)
        else
          reject(adapter, agent, binding, message, result, owner, runtime)
        end
    end
  end

  defp retire_source(adapter, binding) do
    with :ok <- adapter.retire(binding), do: {:error, :conversation_source_retired}
  end

  defp safe_admission(fun) do
    fun.()
  rescue
    error -> {:error, {:input_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:input_exit, reason}}
  end

  defp reject(adapter, agent, binding, message, reason, owner, runtime) do
    with {:ok, entry} <- adapter.reject(binding, message, reason),
         :ok <- wake(agent, stage(agent, entry, owner, binding, runtime)),
         do: {:ok, entry}
  end

  defp current_progress(agent, binding, cached, owner, source) do
    result = current_progress(agent, binding, cached)

    if result == {:error, :source_busy} do
      SalixAgent.InternalSessionActor.watch_source(agent, binding.session_id, owner, source)
    end

    result
  end

  defp current_progress(
         _agent,
         %{session_id: session_id},
         {%{"generation" => session_id} = progress, runtime}
       ),
       do: {:ok, progress, runtime}

  defp current_progress(agent, binding, _) do
    participant = binding.participant["participant_id"]

    case SalixAgent.InternalSessionActor.source_progress(agent, binding.session_id, participant) do
      {:ok, source} ->
        {:ok, source, :internal}

      :not_resident ->
        with {:ok, sources, runtime} <- progress(agent, binding.session_id),
             do: {:ok, sources[participant], runtime}

      error ->
        error
    end
  end

  defp same_binding?(left, right),
    do:
      left.conversation["conversation_id"] == right.conversation["conversation_id"] and
        left.participant["participant_id"] == right.participant["participant_id"] and
        left.start_seq == right.start_seq and left.session_id == right.session_id

  defp observe_source(binding, progress, messages) do
    seq =
      if is_map(progress), do: max(progress["seq"], binding.start_seq), else: binding.start_seq

    oldest =
      case messages do
        [%{"created_at" => at} | _] when is_integer(at) ->
          max(SystemsClock.system_time(:millisecond) - at, 0)

        _ ->
          0
      end

    Salix.Telemetry.emit_conversation_log_sample(
      max((binding.conversation["message_tail_seq"] || 0) - seq, 0),
      oldest
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # tla/salix/RpcDeliver.tla: SourceFrontierImpliesDurable maps to the Session CAS below.
  defp stage(agent_id, entry, owner, binding, runtime) do
    started = SystemsClock.monotonic_time()
    entry = Map.put(entry, :activate_on_admission, true)

    result =
      if binding.agent["role"] == "router" and runtime == :internal do
        SessionDelivery.stage(agent_id, entry, router_owner: owner)
      else
        case AgentActor.stage_delivery(agent_id, entry) do
          {:ok, :committed, _targets} -> {:ok, :committed, []}
          result -> result
        end
      end

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "conversation_log_admit",
      "salix",
      if(elem(result, 0) == :ok, do: "ok", else: "error"),
      SystemsClock.monotonic_time() - started
    )

    case result do
      {:error, :session_read_only} -> {:error, :conversation_source_retired}
      other -> other
    end
  end

  def progress(agent_id, session_id) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        {:ok, InternalSession.conversation_sources(session), :internal}

      {:error, :not_found} ->
        missing_session_progress(agent_id, session_id)

      error ->
        error
    end
  end

  # Missing internal state does not make a retired Session writable.
  # Recovery uses this result too, so it must not wait for an impossible frontier.
  defp missing_session_progress(agent_id, session_id) do
    case RetiredSessions.probe(agent_id, session_id) do
      :present ->
        {:error, :conversation_source_retired}

      :absent ->
        case SessionBirth.side(agent_id, session_id) do
          {:ok, :retired} -> {:error, :conversation_source_retired}
          {:ok, :internal} -> {:ok, %{}, :new}
          {:error, :not_found} -> {:ok, %{}, :new}
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  def reset_source(agent_id, old_session_id, new_session_id) do
    # Rotation copies internal frontiers. Retired history has no such frontier
    # and must not prevent an explicit switch to a fresh Session identity.
    case InternalSessionStore.read(agent_id, old_session_id) do
      {:ok, session} ->
        {:ok,
         Map.new(InternalSession.conversation_sources(session), fn {key, source} ->
           {key, Map.put(source, "generation", new_session_id)}
         end)}

      {:error, :not_found} ->
        {:ok, %{}}

      error ->
        error
    end
  end

  # One task per Agent, with bounded coalesced hints and a bounded disposable cache.
  # Recovery uses authoritative Conversation directories if a hint is dropped.
  @pending_limit 64
  # Carry observations only into immediate consumption of this append. Queued
  # hints and every retry start fresh; source identity never contains authority.
  def notify(%{source_task: nil, source_pending: []} = data, source, {scope, sent_at}) do
    if Map.get(data, :switch_pending) == true or
         SystemsClock.monotonic_time(:millisecond) - sent_at > 50,
       do: notify(data, source),
       else: start(%{data | source_pending: [source]}, scope)
  end

  def notify(data, source, _scope), do: notify(data, source)

  def notify(data, %{group_id: _, conversation_id: _, participant_id: _} = source) do
    pending = data.source_pending

    pending =
      if source in pending or length(pending) >= @pending_limit,
        do: pending,
        else: pending ++ [source]

    start(%{data | source_pending: pending})
  end

  def start(data, scope \\ nil)

  def start(%{source_task: task} = data, _scope) when not is_nil(task), do: data
  def start(%{source_pending: []} = data, _scope), do: data

  def start(data, scope) do
    if Map.get(data, :switch_pending) do
      data
    else
      [source | rest] = data.source_pending
      owner = SystemsRuntime.Proc.self()
      # Bound here so the task captures these values, not the actor state.
      agent_id = data.agent_id
      progress = data.source_progress[source]

      case SalixAgent.AgentReplyTask.start({owner, {:conversation_consumed, source}}, fn ->
             SalixStore.ReadScope.run(scope || %{}, fn ->
               consume(agent_id, source, owner, progress)
             end)
           end) do
        {:ok, pid} ->
          %{
            data
            | source_task: {pid, SystemsRuntime.Proc.monitor(pid)},
              source_ref: source,
              source_pending: rest,
              source_result: nil
          }

        {:error, _} ->
          SystemsClock.send_after(owner, {:retry_conversation_source, source}, 5_000)
          start(%{data | source_pending: rest})
      end
    end
  end

  def complete(data, result), do: %{data | source_result: result}

  def finish(data) do
    source = data.source_ref
    result = data.source_result
    data = %{data | source_task: nil, source_ref: nil, source_result: nil}

    case result do
      {status, progress} when status in [:done, :more] ->
        cache =
          if map_size(data.source_progress) >= @pending_limit,
            do: Map.delete(data.source_progress, data.source_progress |> Map.keys() |> hd()),
            else: data.source_progress

        data = %{data | source_progress: Map.put(cache, source, progress)}
        if status == :more, do: notify(data, source), else: start(data)

      {:error, reason} when reason in [:not_found, :conversation_source_retired] ->
        start(data)

      :redirected ->
        start(%{data | source_progress: Map.delete(data.source_progress, source)})

      :done ->
        start(data)

      _ ->
        SystemsClock.send_after(
          SystemsRuntime.Proc.self(),
          {:retry_conversation_source, source},
          5_000
        )

        start(data)
    end
  end

  defp stamp_input_time(%{conversation_scan_only: true} = entry), do: entry

  defp stamp_input_time(entry),
    do: put_in(entry.payload[:input_time], SalixAgent.InputTime.capture(entry.payload))

  defp wake(agent_id, {:ok, :committed, targets}) do
    case AgentActor.wake_targets_after_commit(agent_id, targets) do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp wake(_, {:ok, status}) when status in [:duplicate, :ignored], do: :ok
  defp wake(_, error), do: error
end
