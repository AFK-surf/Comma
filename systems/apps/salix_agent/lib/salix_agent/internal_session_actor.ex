defmodule SalixAgent.InternalSessionActor do
  @moduledoc """
  Runtime owner for one internal agent session.

  The identity is `{agent_id, session_id}`. This process owns the internal
  runtime lifecycle for that single session: repair, compaction, LLM turns, and
  async tool completions. The kernel's session driver (`session_step`,
  `VerifiedKernel.Session.Drive`) decides every step of that lifecycle; this
  process performs the effects the driver names. Durable persistence is
  `InternalSessionStore`; AgentServer only routes/wakes sessions. Recovery/rehome and the single
  logical activation fence are modeled in `tla/salix/SessionActivation.tla`.
  Legacy visible-reply obligation fields remain readable so rolling sessions
  can be retired without authoring a Conversation Message. Their historical
  semantic retry disposition is modeled in
  `tla/salix/VisibleReplyObligation.tla`.
  Manual compaction's durable continuation and coalesced control wake are
  modeled in `tla/salix/CompactionContinuation.tla`.
  Durable wake invalidation and the actor-owned level trigger are modeled in
  `tla/salix/SessionWakeNotification.tla`.
  """

  use GenServer

  require Logger

  alias SalixAgent.{
    Compaction,
    DependencyJob,
    InternalAgentRuntime,
    InternalSession,
    InternalSessionStore,
    Repair,
    Round,
    SessionActivity,
    SessionDriver,
    SessionToolExecution,
    TrajectoryEval,
    VisibleReply
  }

  alias SalixAgent.InternalSession.Recovery
  alias SalixAgent.InternalSessionStore.Revision

  require InternalSession

  @control_prefetch_join_ms 5_000

  defstruct [
    :agent_id,
    :session_id,
    wake_pending: false,
    process_scheduled: false,
    source_waiters: %{},
    direct_round_waiter: nil,
    pending_llm: nil,
    pending_compaction: nil,
    pending_async_tools: %{},
    pending_async_tool_commits: %{},
    session_checkpoint: nil,
    round_config_cache: %SalixAgent.RoundConfigCache{},
    # Start the round configuration build as soon as the actor is bound
    # (an actor born for a delivery), so it overlaps the delivery commit.
    prewarm_on_bind: false,
    # Control record read during the delivery commit for the processing
    # entry that follows it (the activation decision and the round both
    # consult it); joined once, then the entry's read scope serves it.
    control_prefetch: nil,
    durable_marked: false,
    llm_retry_timer: nil,
    session_retry_timer: nil,
    session_retry_attempt: 0,
    session_recovery: nil,
    # Wall clock of the processing entry that led to the current
    # activation; handed to Round.run so the `activation` phase fact can
    # cover repair + activation read + materialization + config rebuild.
    activation_started_ms: nil,
    # The owner's resident revision. This actor is the only writer of its
    # session, so the revision it last read or committed is the session
    # until it commits again; it is read from the store only when there is
    # none (actor start, a foreign write surfacing as a CAS conflict, a path
    # that wrote through the plain store API and forgot it).
    revision: nil,
    # Supervisor of this session's outbound SSH sessions, started on the
    # first ssh.open and linked to this actor (`SalixAgent.SSH.Sessions`).
    ssh_sessions: nil
  ]

  @type t :: %__MODULE__{}
  @session_retry_base_ms 100
  @session_retry_max_ms 5_000

  # ---- API ----

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

  def wake(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] ->
        SalixAgent.SessionResidency.cast(pid, :wake)

      [] ->
        {:error, :not_running}
    end
  end

  def running?(agent_id, session_id),
    do: Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) != []

  @doc """
  Whether a resident actor here holds a revision it read from or committed
  to the internal store: proof of the session's birth store that needs no
  probe. A registered actor whose session is still being created is not.
  """
  def resident_durable?(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{_pid, %{durable: true}}] -> true
      _ -> false
    end
  end

  @doc false
  def watch_source(agent_id, session_id, owner, source) when is_pid(owner) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] -> GenServer.cast(pid, {:watch_source, owner, source})
      [] -> :ok
    end
  end

  @doc false
  def activity_snapshot(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] when pid != self() ->
        case SalixAgent.SessionResidency.call(pid, :activity_snapshot, 5_000) do
          {:error, :session_actor_retiring} -> :not_resident
          result -> result
        end

      [{_self, _}] ->
        {:error, :session_activity_busy}

      [] ->
        :not_resident
    end
  catch
    :exit, {:timeout, _} -> {:error, :session_activity_busy}
    :exit, _ -> :not_resident
  end

  @doc false
  def source_progress(agent_id, session_id, participant_id) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] when pid != self() ->
        SalixAgent.SessionResidency.call(pid, {:source_progress, participant_id}, 1_000)

      _ ->
        :not_resident
    end
  catch
    :exit, {:timeout, _} -> {:error, :source_busy}
    :exit, _ -> :not_resident
  end

  def owner?(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] when pid == self() -> true
      _ -> false
    end
  end

  @doc """
  True while the actor holds in-flight work (pending LLM/compaction/async
  tools, or a scheduled process pass). A call timeout means the actor is
  mid-work (e.g. an inline round) and counts as busy; a dead actor does not.
  Used by the root Server's lease keep-alive gate.
  """
  @spec busy?(pid(), timeout()) :: boolean()
  def busy?(pid, timeout \\ 100) when is_pid(pid) do
    GenServer.call(pid, :busy?, timeout)
  catch
    :exit, {:timeout, _} -> true
    :exit, _ -> false
  end

  def run_round(pid, context, opts, timeout \\ :infinity)
      when is_pid(pid) and is_map(context) and is_list(opts) do
    SalixAgent.SessionResidency.call(
      pid,
      {:run_round, SystemsObservability.Context.capture(), context, opts},
      timeout
    )
  end

  def compact_session(pid, mode, context, opts, timeout \\ :infinity)
      when is_pid(pid) and mode in [:compact, :maybe_compact] and is_map(context) and
             is_list(opts) do
    SalixAgent.SessionResidency.call(pid, {:compact_session, mode, context, opts}, timeout)
  end

  def commit_tool_results(pid, context, pending, results, timeout \\ :infinity)
      when is_pid(pid) and is_map(context) and is_map(pending) and is_list(results) do
    SalixAgent.SessionResidency.call(
      pid,
      {:commit_tool_results, context, pending, results},
      timeout
    )
  end

  def execute_tool(pid, tool_name, attrs, timeout \\ :infinity)
      when is_pid(pid) and is_binary(tool_name) and is_map(attrs) do
    SalixAgent.SessionResidency.call(pid, {:execute_tool, tool_name, attrs}, timeout)
  end

  def complete_async_tool_call(pid, tool_call_id, result, meta, timeout \\ :infinity)
      when is_pid(pid) and is_binary(tool_call_id) and is_map(result) and is_map(meta) do
    SalixAgent.SessionResidency.call(
      pid,
      {:complete_async_tool_call, tool_call_id, result, meta},
      timeout
    )
  end

  def update_async_tool_call_progress(pid, tool_call_id, progress, timeout \\ :infinity)
      when is_pid(pid) and is_binary(tool_call_id) and is_map(progress) do
    SalixAgent.SessionResidency.call(
      pid,
      {:update_async_tool_call_progress, tool_call_id, progress},
      timeout
    )
  end

  def stage_delivery(pid, entry, timeout \\ :infinity) when is_pid(pid) and is_map(entry) do
    SalixAgent.SessionResidency.call(
      pid,
      {:stage_delivery, entry, SalixStore.ReadScope.capture()},
      timeout
    )
  end

  def stage_delivery_in_owner(agent_id, session_id, entry)
      when is_binary(agent_id) and is_binary(session_id) and is_map(entry) do
    with_session_owner(agent_id, session_id, fn ->
      commit_inbound_delivery(agent_id, session_id, entry)
    end)
  end

  def stage_wait_timeout(pid, entry, timeout \\ :infinity) when is_pid(pid) and is_map(entry) do
    SalixAgent.SessionResidency.call(pid, {:stage_wait_timeout, entry}, timeout)
  end

  def stage_wait_timeout_in_owner(agent_id, session_id, entry)
      when is_binary(agent_id) and is_binary(session_id) and is_map(entry) do
    with_session_owner(agent_id, session_id, fn ->
      commit_inbound_wait_timeout(agent_id, session_id, entry)
    end)
  end

  def stage_control(pid, entry, timeout \\ :infinity) when is_pid(pid) and is_map(entry) do
    SalixAgent.SessionResidency.call(pid, {:stage_control, entry}, timeout)
  end

  def stage_control_in_owner(agent_id, session_id, entry)
      when is_binary(agent_id) and is_binary(session_id) and is_map(entry) do
    with_session_owner(agent_id, session_id, fn ->
      result = commit_control_delivery(agent_id, session_id, entry)
      notify_control_result(result, agent_id, session_id)
    end)
  end

  def fork_session(pid, source_session_id, target_session_id, attrs, timeout \\ :infinity)
      when is_pid(pid) and is_binary(source_session_id) and is_binary(target_session_id) and
             is_map(attrs) do
    SalixAgent.SessionResidency.call(
      pid,
      {:fork_session, source_session_id, target_session_id, attrs},
      timeout
    )
  end

  def fork_session_in_owner(agent_id, source_session_id, target_session_id, attrs)
      when is_binary(agent_id) and is_binary(source_session_id) and is_binary(target_session_id) and
             is_map(attrs) do
    with_session_owner(agent_id, target_session_id, fn ->
      result = fork_internal_session(agent_id, source_session_id, target_session_id, attrs)
      notify_session_result(result, agent_id, target_session_id)
    end)
  end

  def seed_session(pid, source_session, target_session_id, attrs, timeout \\ :infinity)
      when is_pid(pid) and is_binary(target_session_id) and is_map(attrs) do
    SalixAgent.SessionResidency.call(
      pid,
      {:seed_session, source_session, target_session_id, attrs},
      timeout
    )
  end

  def seed_session_in_owner(agent_id, source_session, target_session_id, attrs)
      when is_binary(agent_id) and is_binary(target_session_id) and is_map(attrs) do
    with_session_owner(agent_id, target_session_id, fn ->
      result = seed_internal_session(agent_id, source_session, target_session_id, attrs)
      notify_session_result(result, agent_id, target_session_id)
    end)
  end

  def seed_transcript(pid, event, timeout \\ :infinity) when is_pid(pid) and is_map(event) do
    SalixAgent.SessionResidency.call(pid, {:seed_transcript, event}, timeout)
  end

  def seed_transcript_in_owner(agent_id, session_id, event)
      when is_binary(agent_id) and is_binary(session_id) and is_map(event) do
    with_session_owner(agent_id, session_id, fn ->
      result = commit_transcript_seed(agent_id, session_id, event)
      notify_session_result(result, agent_id, session_id)
    end)
  end

  def key(agent_id, session_id), do: {:internal_session, agent_id, session_id}

  defp via(agent_id, session_id),
    do: {:via, Registry, {SalixAgent.Registry, key(agent_id, session_id)}}

  defp with_session_owner(agent_id, session_id, fun) do
    case Registry.lookup(SalixAgent.Registry, key(agent_id, session_id)) do
      [{pid, _}] when pid == self() -> fun.()
      _ -> {:error, :not_session_owner}
    end
  end

  defp ensure_actor_target(%__MODULE__{session_id: session_id}, session_id), do: :ok

  defp ensure_actor_target(%__MODULE__{session_id: current}, target),
    do: {:error, {:session_actor_target_mismatch, current, target}}

  defp ensure_context_target(%__MODULE__{agent_id: agent_id, session_id: session_id}, %{
         agent_id: agent_id,
         session_id: session_id
       }),
       do: :ok

  defp ensure_context_target(%__MODULE__{agent_id: agent_id, session_id: session_id}, context),
    do:
      {:error,
       {:session_actor_context_mismatch, %{agent_id: agent_id, session_id: session_id},
        %{agent_id: context[:agent_id], session_id: context[:session_id]}}}

  # Direct run_round is an operator/test entrypoint. It must not bypass
  # activation repair; process-local background tool work is recovered
  # here before normal activation decides whether a round should run.
  defp ensure_direct_round_ready(session) when InternalSession.is_session(session) do
    case Repair.plan_session(session) do
      {:error, _} = error ->
        error

      {[], _next} ->
        InternalSession.query(session, :direct_round_ready)

      {_events, _next} ->
        {:error, :activation_required}
    end
  end

  # ---- GenServer ----

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    if SalixStore.Ids.valid_session_id?(session_id) do
      agent_id = Keyword.fetch!(opts, :agent_id)

      data = %__MODULE__{
        agent_id: agent_id,
        session_id: session_id,
        prewarm_on_bind: Keyword.get(opts, :prewarm_round_config, false) == true
      }

      data =
        if Keyword.get(opts, :process_on_init, true) do
          request_process(data)
        else
          data
        end

      # Generation binding is this actor's FIRST act, before any queued
      # command — see handle_continue. Doing it in a continue (not inline
      # here) keeps a mid-claim wait out of the shared FleetSup supervisor,
      # which blocks in start_child until init returns.
      :ok = SalixAgent.SessionResidency.register(self())
      {:ok, data, {:continue, :bind_runtime_generation}}
    else
      {:stop, :invalid_session_id}
    end
  end

  # Freeze the ownership epoch this actor runs under into its Registry
  # value: fencing admission for this actor's commits compares against this
  # immutable actor-scoped epoch, so a later re-claim on the same node can
  # never launder a stale in-flight actor's writes as the new epoch's
  # (rollout-concurrent-runner-fencing D2/D3.1). Running the binding as the
  # actor's own first act makes EVERY creation path a participant in the
  # lifecycle contract — the Fleet start funnel, the Router owner's
  # canonical start, and crucially a supervisor-driven restart of a crashed
  # actor, which re-runs the retained child_spec directly and never passes
  # a call-site boundary. A registered Server's in-flight claim is waited
  # out (bounded) so the freeze binds to the installed claim instead of
  # legacy-pinning the actor; if the wait gives up, the store's
  # first-resolution pin stays the safety net.
  @impl true
  def handle_continue(:bind_runtime_generation, data) do
    # The session read needs no epoch and the delivery commit needs the
    # session anyway; reading it before the claim wait lets the round
    # configuration build overlap the Server's claim.
    data = maybe_prewarm_on_bind(data)
    :ok = SalixAgent.Fleet.await_ownership_installed(data.agent_id)

    case SalixAgent.OwnershipCell.fetch(data.agent_id) do
      {:ok, epoch} ->
        _ =
          Registry.update_value(
            SalixAgent.Registry,
            key(data.agent_id, data.session_id),
            fn
              value when is_map(value) -> Map.put(value, :runtime_epoch, epoch)
              _other -> %{runtime_epoch: epoch}
            end
          )

      _ ->
        :ok
    end

    {:noreply, data}
  end

  # The session read here is the one the delivery commit needs anyway; it
  # moves ahead of the stage so the configuration build starts earlier.
  defp maybe_prewarm_on_bind(%{prewarm_on_bind: true} = data) do
    data = %{data | prewarm_on_bind: false}

    case owned_revision(data) do
      {:ok, _revision, data} -> prewarm_round_config({:ok, :committed}, data)
      _absent_or_failed -> data
    end
  end

  defp maybe_prewarm_on_bind(data), do: data

  @impl true
  def handle_cast({:watch_source, owner, source}, data) do
    # Match the consumer's 64-source bound. Lost hints retain its recovery timer.
    waiters =
      if map_size(data.source_waiters) < 64,
        do: Map.put(data.source_waiters, {owner, source}, true),
        else: data.source_waiters

    noreply(%{data | source_waiters: waiters})
  end

  def handle_cast(:wake, data) do
    noreply(request_process(data))
  end

  @impl true
  def handle_call({:ssh_start, spec}, _from, data) do
    {result, supervisor} = SalixAgent.SSH.Sessions.start(data.ssh_sessions, spec)
    reply(result, %{data | ssh_sessions: supervisor})
  end

  def handle_call({:execute_tool, tool_name, attrs}, _from, data) do
    case SessionToolExecution.execute(
           data.agent_id,
           data.session_id,
           :internal,
           [],
           tool_name,
           attrs
         ) do
      {:ok, result, pending_async, events, observed_result} ->
        case commit_session_events_with_timers(data.agent_id, data.session_id, events) do
          {:ok, _session} ->
            SessionToolExecution.emit_result(observed_result)
            data = forget(data)

            data =
              Enum.reduce(pending_async, data, fn item, acc ->
                %{acc | pending_async_tools: Map.put(acc.pending_async_tools, item.ref, item)}
              end)

            data =
              if Enum.any?(pending_async, &completion_activates?/1) do
                request_process(data)
              else
                data
              end

            reply({:ok, result}, data)

          {:error, reason} ->
            reply({:error, reason}, data)
        end

      {:error, _} = error ->
        reply(error, data)
    end
  end

  def handle_call({:complete_async_tool_call, tool_call_id, result, meta}, _from, data) do
    with {:ok, revision, data} <- owned_revision(data),
         {:running, call} <- completion_target(revision.state, tool_call_id),
         {:ok, events, response, pending, observed_result} <-
           SessionToolExecution.complete_surface(
             data.agent_id,
             data.session_id,
             :internal,
             call,
             tool_call_id,
             result,
             meta
           ),
         {:ok, committed} <-
           commit_revision_events_with_timers(data.agent_id, data.session_id, revision, events) do
      data = retain(data, committed)

      data =
        if terminal_async_call?(committed.state, tool_call_id) do
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

      data = if completion_activates?(pending), do: request_process(data), else: data
      reply({:ok, response}, data)
    else
      :already_resolved ->
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

      :unknown ->
        reply({:error, :not_found}, data)

      {:error, _} = error ->
        reply(error, forget(data))
    end
  end

  def handle_call(:activity_snapshot, _from, data) do
    result =
      case data.revision do
        %Revision{etag: etag} = revision when not is_nil(etag) ->
          # Pending transitions are private working state. Status exposes only
          # the committed baseline retained by this owner.
          baseline = InternalSessionStore.revision_baseline(revision)

          {:ok,
           SalixAgent.InternalAgentRuntime.project_session_activity(data.agent_id, baseline.state)}

        _ ->
          :not_resident
      end

    {:reply, result, data, :infinity}
  end

  def handle_call({:source_progress, participant_id}, _from, data) do
    result =
      cond do
        process_blocked?(data) ->
          {:error, :source_busy}

        match?(%Revision{pending: nil}, data.revision) ->
          {:ok, InternalSession.conversation_sources(data.revision.state)[participant_id]}

        true ->
          :not_resident
      end

    {:reply, result, data, :infinity}
  end

  def handle_call(:busy?, _from, data) do
    # Strictly side-effect-free: the probe must observe, never perturb — in
    # particular it must not run maybe_schedule_process/1 and inject extra
    # :process passes into a working actor.
    {:reply, not idle?(data), data, :infinity}
  end

  def handle_call({:update_async_tool_call_progress, tool_call_id, progress}, _from, data) do
    event = async_tool_call_progress_event(data.session_id, tool_call_id, progress)

    with {:ok, revision, data} <- owned_revision(data),
         {:ok, committed} <-
           commit_revision_events_with_timers(data.agent_id, data.session_id, revision, [event]) do
      reply(
        {:ok, %{"status" => "updated", "tool_call_id" => tool_call_id}},
        retain(data, committed)
      )
    else
      {:error, reason} ->
        reply({:error, reason}, forget(data))
    end
  end

  def handle_call(
        {:run_round, _observability_context, _context, _opts},
        _from,
        %{pending_llm: %{} = _pending} = data
      ) do
    reply({:error, :session_busy}, data)
  end

  def handle_call(
        {:run_round, _observability_context, _context, _opts},
        _from,
        %{pending_compaction: %{} = _pending} = data
      ) do
    reply({:error, :session_compacting}, data)
  end

  def handle_call(
        {:run_round, _observability_context, _context, _opts},
        _from,
        %{pending_async_tools: pending} = data
      )
      when map_size(pending) > 0 do
    reply({:error, :session_has_background_tool_work}, data)
  end

  def handle_call(
        {:run_round, _observability_context, _context, _opts},
        _from,
        %{pending_async_tool_commits: pending} = data
      )
      when map_size(pending) > 0 do
    reply({:error, :session_has_background_tool_work}, data)
  end

  def handle_call({:run_round, observability_context, context, opts}, from, data) do
    await_completion? =
      Keyword.get(opts, :__round_run_delegate__, false) or
        Keyword.get(opts, :__round_run_await_completion__, false)

    {result, data} =
      SystemsObservability.Context.run(observability_context, fn ->
        with :ok <- ensure_context_target(data, context),
             {:ok, revision, data} <- owned_revision(data),
             :ok <- ensure_direct_round_ready(revision.state),
             {:ok, data, revision} <- prepare_session_activation(data, revision) do
          direct_round(data, revision, context, opts)
        else
          {:error, reason, next_data} -> {{:error, reason}, forget(next_data)}
          {:error, _} = error -> {error, forget(data)}
        end
      end)

    case {await_completion?, result} do
      {true, {:ok, _context, {:llm_pending, _pending}}} ->
        data = %{data | direct_round_waiter: from}
        {:noreply, data, :infinity}

      _other ->
        reply(result, data)
    end
  end

  def handle_call(
        {:compact_session, _mode, _context, _opts},
        _from,
        %{pending_compaction: %{} = _pending} = data
      ) do
    reply({:error, :session_compacting}, data)
  end

  def handle_call({:compact_session, mode, context, opts}, from, data) do
    case ensure_context_target(data, context) do
      :ok ->
        context = with_owned_revision(context, data)

        noreply(start_compaction(data, mode, context, opts, {:reply, from}))

      {:error, _} = error ->
        reply(error, data)
    end
  end

  def handle_call({:commit_tool_results, context, pending, results}, _from, data) do
    with :ok <- ensure_context_target(data, context),
         :ok <- ensure_actor_target(data, pending.session_id),
         {:ok, revision, data} <- resident_or_new(data) do
      # The caller's context is data from another process; the owner's
      # resident revision is the session the results commit against.
      {host, event} = Round.results_host(Map.put(context, :revision, revision), pending, results)

      case data |> driven(revision, :results, %{host: host}) |> run({:loop, nil, event}) do
        {{:loop_end, {:stop, outcome}}, ctx, _driver} ->
          result = Round.round_result(ctx.host, outcome)
          reply(result, retain(ctx.data, ctx.rev))

        {{:round_failure, reason}, ctx, _driver} ->
          reply({:error, reason}, forget(ctx.data))
      end
    else
      {:error, _} = error -> reply(error, forget(data))
    end
  end

  def handle_call({:stage_delivery, entry, read_scope}, from, data) do
    SalixStore.ReadScope.run(read_scope || %{}, fn ->
      handle_call({:stage_delivery, entry}, from, data)
    end)
  end

  def handle_call(
        {:stage_delivery, %{activate_on_admission: true, conversation_source: source} = entry},
        _from,
        data
      )
      when is_map(source) do
    {result, data} =
      SalixStore.ReadScope.run(fn ->
        prefetch_round_refresh(data)
        admit_conversation(data, entry)
      end)

    reply(result, data)
  end

  def handle_call({:stage_delivery, entry}, _from, data) do
    data = start_control_prefetch(data)
    {result, data} = SalixStore.ReadScope.run(fn -> commit_inbound_delivery(data, entry) end)
    reply(result, prewarm_round_config(result, data))
  end

  # The paths below write through the plain store API; the next processing
  # entry reads what they left behind.
  def handle_call({:stage_wait_timeout, entry}, _from, data) do
    reply(commit_inbound_wait_timeout(data.agent_id, data.session_id, entry), forget(data))
  end

  def handle_call({:stage_control, entry}, _from, data) do
    result = commit_control_delivery(data.agent_id, data.session_id, entry)
    result = notify_control_result(result, data.agent_id, data.session_id)

    reply(result, forget(data))
  end

  def handle_call({:fork_session, source_session_id, target_session_id, attrs}, _from, data) do
    result =
      with :ok <- ensure_actor_target(data, target_session_id) do
        fork_internal_session(data.agent_id, source_session_id, target_session_id, attrs)
      end

    result = notify_session_result(result, data.agent_id, target_session_id)

    reply(result, forget(data))
  end

  def handle_call({:seed_session, source_session, target_session_id, attrs}, _from, data) do
    result =
      with :ok <- ensure_actor_target(data, target_session_id) do
        seed_internal_session(data.agent_id, source_session, target_session_id, attrs)
      end

    result = notify_session_result(result, data.agent_id, target_session_id)

    reply(result, forget(data))
  end

  def handle_call({:seed_transcript, event}, _from, data) do
    result =
      with :ok <- ensure_actor_target(data, event["session_id"] || event[:session_id]) do
        commit_transcript_seed(data.agent_id, data.session_id, event)
      end

    result = notify_session_result(result, data.agent_id, data.session_id)

    reply(result, forget(data))
  end

  @impl true
  def handle_info({ref, result}, %{round_config_cache: %{task: %Task{ref: ref}}} = data) do
    cache = SalixAgent.RoundConfigCache.completed(data.round_config_cache, ref, result)
    noreply(%{data | round_config_cache: cache})
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{round_config_cache: %{task: %Task{ref: ref}}} = data
      ) do
    cache = SalixAgent.RoundConfigCache.down(data.round_config_cache, ref, reason)
    noreply(%{data | round_config_cache: cache})
  end

  # One processing entry resolves the agent's control record at the
  # activation decision, the round configuration and the catalog; the read
  # scope serves those from one read.
  def handle_info({ref, result}, %{control_prefetch: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    noreply(%{data | control_prefetch: {:done, result}})
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{control_prefetch: %Task{ref: ref}} = data
      ),
      do: noreply(%{data | control_prefetch: nil})

  def handle_info(:process, data) do
    data = %{data | process_scheduled: false, wake_pending: true}
    {seed, data} = join_control_prefetch(data)
    noreply(SalixStore.ReadScope.run(seed, fn -> maybe_process_session(data) end))
  end

  def handle_info(
        {:session_retry, token},
        %{session_retry_timer: {token, _timer_ref}} = data
      ) do
    data = %{data | session_retry_timer: nil}
    noreply(request_process(data))
  end

  # Another local process wrote this session through the store; the resident
  # revision is behind it, so the next processing entry reads.
  def handle_info({:session_written_elsewhere, _session_id}, data), do: noreply(forget(data))

  def handle_info({:retry_async_tool_commit, ref, pending, result, attempts}, data) do
    retained = Map.get(data.pending_async_tool_commits, ref)

    owner =
      case retained do
        %{pending: _, result: _} -> true
        nil -> false
        _ -> :invalid
      end

    data =
      case SalixVerifiedKernel.AgentLoop.retry_admission(owner, attempts) do
        :retained ->
          %{pending: retained_pending, result: retained_result} = retained
          do_commit_async_tool_result(data, ref, retained_pending, retained_result, attempts)

        :initial ->
          data
          |> retain_async_tool_terminal(ref, pending, result)
          |> do_commit_async_tool_result(
            ref,
            retire_dependency_identity(pending),
            result,
            attempts
          )

        :ignore ->
          data
      end

    noreply(data)
  end

  def handle_info({:run_session_compact, entry}, %{pending_compaction: %{}} = data) do
    case inbound_source_message_id(entry) do
      source when is_binary(source) and source != "" ->
        _ =
          Compaction.commit_compact_noop_result(
            data.agent_id,
            data.session_id,
            source,
            :session_compacting
          )

        noreply(forget(data))

      _missing_source ->
        noreply(data)
    end
  end

  def handle_info({:run_session_compact, entry}, data) do
    context = runtime_context(data)
    opts = [result_source_message_id: inbound_source_message_id(entry)]

    noreply(start_compaction(data, :compact, context, opts, {:control, entry}))
  end

  def handle_info(:residency_evict, data) do
    # The owner closes admission before checking the mailbox. An admitted call
    # holds a pin; a cast is either queued or still pinned during enqueue.
    if SalixAgent.SessionResidency.eviction_allowed?() and idle?(data) and
         SalixAgent.SessionResidency.close(self()) do
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, 0} ->
          SalixAgent.SessionResidency.evicted()
          {:stop, :normal, data}

        _ ->
          SalixAgent.SessionResidency.reopen(self())
          {:noreply, data}
      end
    else
      {:noreply, data}
    end
  end

  def handle_info({:llm_retry, token}, %{llm_retry_timer: {token, _}} = data) do
    noreply(request_process(%{data | llm_retry_timer: nil}))
  end

  def handle_info({:llm_retry, _stale_token}, data), do: noreply(data)

  def handle_info({:dependency_job_result, token, result}, data) do
    handle_dependency_event(data, token, :result, result)
  end

  def handle_info({:dependency_job_timeout, token}, data) do
    handle_dependency_event(data, token, :timeout, nil)
  end

  def handle_info({:dependency_job_down, token, reason}, data) do
    handle_dependency_event(data, token, :down, reason)
  end

  def handle_info({ref, result}, data) when is_reference(ref) and is_map(result) do
    Process.demonitor(ref, [:flush])

    case legacy_tool_owner(data, ref, :result) do
      nil ->
        noreply(data)

      pending ->
        noreply(begin_async_tool_terminal(data, ref, pending, result))
    end
  end

  # Model calls and summaries run as dependency jobs, which report through
  # their own messages; a monitor here belongs to a background tool.
  def handle_info({:DOWN, ref, :process, _pid, reason}, data) when is_reference(ref),
    do: handle_async_tool_down(ref, reason, data)

  def handle_info(_message, data), do: noreply(data)

  @impl true
  def terminate(_reason, data) do
    SalixAgent.SessionResidency.unregister(self())
    SalixAgent.RoundConfigCache.stop(data.round_config_cache)
    :ok
  end

  # The pure kernel admits the exact live owner. Payload validation and job
  # cleanup stay at this actor boundary; no second token registry is created.
  defp handle_dependency_event(data, token, event, result) do
    case dependency_owner(data, token, event, result) do
      {:llm, pending} ->
        received_at = SalixAgent.PhaseTelemetry.now_ms()
        :ok = finish_dependency_job(pending.dependency_job, event)
        data = %{data | pending_llm: nil}

        case event do
          :result ->
            {response, duration_ms, meter_meta} = result
            meter_meta = Map.put(meter_meta, :actor_received_at_ms, received_at)
            noreply(complete_llm_response(data, pending, response, duration_ms, meter_meta))

          failure ->
            noreply(fail_pending_llm(data, pending, dependency_failure(:llm, failure, result)))
        end

      {:compaction, pending} ->
        log_compaction_job(
          pending.plan,
          "compaction_job_#{event}",
          pending.dependency_job.timeout_ms
        )

        :ok = finish_dependency_job(pending.dependency_job, event)
        data = %{data | pending_compaction: nil}

        if event == :result do
          noreply(finish_compaction(data, pending, result))
        else
          noreply(fail_compaction(data, pending, dependency_failure(:compaction, event, result)))
        end

      {:tool, pending} ->
        :ok = finish_dependency_job(pending.dependency_job, event)

        result =
          case event do
            :result ->
              result

            failure ->
              status = if failure == :timeout, do: "timeout", else: "crashed"

              InternalAgentRuntime.tool_error_results(
                [pending.call],
                dependency_failure(:tool, failure, result),
                status
              )
              |> hd()
          end

        noreply(begin_async_tool_terminal(data, token, pending, result))

      nil ->
        noreply(data)
    end
  end

  defp dependency_owner(data, token, event, result) do
    tool = Map.get(data.pending_async_tools, token)

    cond do
      (event != :result or valid_llm_result?(result)) and
          dependency_matches?(data.pending_llm, token, event) ->
        {:llm, data.pending_llm}

      dependency_matches?(data.pending_compaction, token, event) ->
        {:compaction, data.pending_compaction}

      is_reference(token) and (event != :result or is_map(result)) and
          dependency_matches?(tool, token, event) ->
        {:tool, tool}

      true ->
        nil
    end
  end

  defp valid_llm_result?({_response, duration_ms, meter_meta}),
    do: is_integer(duration_ms) and is_map(meter_meta)

  defp valid_llm_result?(_result), do: false

  defp dependency_matches?(%{dependency_job: %DependencyJob{token: expected}}, token, event),
    do: live_dependency_event?(expected, token, event)

  defp dependency_matches?(_pending, _token, _event), do: false

  defp live_dependency_event?(expected, token, event)
       when is_reference(expected) and is_reference(token) do
    case SalixVerifiedKernel.AgentLoop.dependency_step({:running, expected}, {token, event}) do
      {{:retained, ^expected}, command}
      when command in [:accept_result, :accept_timeout, :accept_down] ->
        true

      _ ->
        false
    end
  end

  defp live_dependency_event?(_expected, _token, _event), do: false

  defp finish_dependency_job(job, :timeout), do: DependencyJob.cancel(job, :timeout)
  defp finish_dependency_job(job, _event), do: DependencyJob.complete(job)

  defp dependency_failure(kind, :timeout, _reason), do: {:dependency_timeout, kind}
  defp dependency_failure(kind, :down, reason), do: {:dependency_crashed, kind, reason}

  # ---- processing ----

  defp handle_async_tool_down(ref, reason, data) do
    case legacy_tool_owner(data, ref, :down) do
      nil ->
        noreply(data)

      pending ->
        result =
          InternalAgentRuntime.tool_error_results([pending.call], reason, "crashed") |> hd()

        noreply(begin_async_tool_terminal(data, ref, pending, result))
    end
  end

  defp legacy_tool_owner(data, ref, event) do
    pending = Map.get(data.pending_async_tools, ref)
    owner = if pending == nil, do: :retired, else: {:running, ref}

    case SalixVerifiedKernel.AgentLoop.dependency_step(owner, {ref, event}) do
      {{:retained, ^ref}, command} when command in [:accept_result, :accept_down] -> pending
      _ -> nil
    end
  end

  # A queued wake cannot bypass an actor-owned LLM, compaction, or reply
  # backoff. Background tools remain independently wakeable as before.
  defp maybe_process_session(data) do
    case SalixVerifiedKernel.AgentLoop.activation(
           is_map(data.pending_llm),
           is_map(data.pending_compaction),
           match?({_token, _ref}, data.session_retry_timer)
         ) do
      :pause ->
        data

      :process ->
        data
        |> Map.put(:wake_pending, false)
        |> Map.put(:activation_started_ms, SalixAgent.PhaseTelemetry.now_ms())
        |> process_session()
    end
  end

  # One read per processing entry. The owner is the only writer of its
  # session, so the revision read here is the whole truth for this callback:
  # the kernel's session driver decides every step over it, and every effect
  # commits against it and hands the next revision forward. A CAS conflict (an
  # ownership transfer, a foreign write) is the one thing that re-reads.
  defp process_session(data) do
    case owned_revision(data) do
      {:ok, revision, data} ->
        span(:salix_session_activation, fn ->
          data |> driven(revision, :full) |> run({:process, process_entry(data)}) |> conclude()
        end)

      {:error, :not_found} ->
        data |> forget() |> reset_session_retry()

      {:error, reason} ->
        apply_session_recovery(
          forget(data),
          Recovery.failure(data.session_recovery, :repair_read, reason)
        )
    end
  end

  # The ordinary async-terminal continuation has just produced this exact
  # revision in the same owner callback. When no older mailbox work is queued,
  # the driver keeps that fence through the no-compaction activation instead
  # of paying for a fresh copy of the same Session at every phase; any
  # exceptional shape falls back to the full processing path over the same
  # revision. This is the concrete combined pending -> active CAS abstracted
  # by tla/salix/SessionActivation.tla.
  defp process_session(data, %Revision{} = revision) do
    span(:salix_session_activation, fn ->
      data
      |> retain(revision)
      |> driven(revision, :fast)
      |> run({:process_fast, process_entry(data)})
      |> conclude()
    end)
  end

  # What crash repair reads from this owner: the tool calls that live
  # processes still own, and the recovery checkpoint.
  defp process_entry(data) do
    %{
      "live" =>
        live_process_tool_call_ids(data.pending_async_tools, data.pending_async_tool_commits),
      "checkpoint" => data.session_recovery
    }
  end

  # ---- the kernel's session driver ----
  #
  # The kernel's session driver (`session_step`, `VerifiedKernel.Session.Drive`)
  # sequences every processing entry: recovery and crash repair, the
  # activation decision and its commits, compaction, model rounds, and the
  # answer of a model call. This owner performs each effect the driver names
  # and answers with its result. The driver context carries the owner state,
  # the working revision, and what the effects of the entry resolved so far.
  # A driver that waits for a model call or a summary is kept with that
  # dependency and continues when it answers.

  defp driven(data, revision, entry, fields \\ %{}) do
    Map.merge(
      %{
        data: data,
        rev: revision,
        entry: entry,
        # The round configuration and the activation that a prepared round
        # starts from.
        config: nil,
        prepared: nil,
        # An overlapped activation: its running fence, the persistence gate
        # of its model call, and what the fence commits.
        fence: nil,
        gate: nil,
        prerequisite: nil,
        events: [],
        kind: nil,
        # The prepared round, and the loop host of the running round.
        prep: nil,
        host: nil,
        # A model call's answer, or its failure.
        llm: nil,
        lost: nil,
        # A direct round's options and result.
        ropts: [],
        result: nil,
        # The caller's runtime context (a direct round or an explicit
        # compaction), and a compaction's options, host, and continuation.
        ccontext: nil,
        copts: [],
        chost: nil,
        continuation: nil
      },
      fields
    )
  end

  # One driver step: `{terminal_effect, ctx, driver}` once the step ends.
  defp run(ctx, event), do: run(ctx, nil, event)

  defp run(ctx, driver, event) do
    {ctx, state} = working_state(ctx)
    {driver, effect} = traced_step(ctx, state, driver, event)
    perform(ctx, state, driver, effect)
  end

  # The step after recovery runs crash repair; the step after a round's
  # preparation builds its request.
  defp traced_step(ctx, state, %{"phase" => "recover"} = driver, event),
    do: span(:salix_session_repair, fn -> step(ctx, state, driver, event) end)

  defp traced_step(ctx, state, %{"phase" => "round_prepare"} = driver, event),
    do: span(:salix_round_conversation, fn -> step(ctx, state, driver, event) end)

  defp traced_step(ctx, state, driver, event), do: step(ctx, state, driver, event)

  defp step(ctx, state, driver, event),
    do: SessionDriver.step(state, driver, event, reader(ctx, state))

  defp span(name, fun) do
    SystemsObservability.Trace.with_span(
      name,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fun
    )
  end

  defp answer(ctx, driver, value), do: run(ctx, driver, {:done, value})

  # A path that forgot the revision reads the session again before the next
  # step; a session that does not exist is born by its first commit.
  defp working_state(%{rev: %Revision{state: state}} = ctx), do: {ctx, state}

  defp working_state(%{data: data} = ctx) do
    case InternalSessionStore.read_revision(data.agent_id, data.session_id) do
      {:ok, revision} -> {%{ctx | rev: revision}, revision.state}
      {:error, _} -> {ctx, InternalSession.new(data.agent_id, data.session_id)}
    end
  end

  # The driver reads crash repair facts and, while a round builds its
  # request, stored images and results.
  defp reader(%{prep: prep}, state) do
    repair = Repair.reader(state)

    fn
      {:request_image, _} = request when is_map(prep) -> Round.request_reader(prep).(request)
      {:request_result, _} = request when is_map(prep) -> Round.request_reader(prep).(request)
      request -> repair.(request)
    end
  end

  # The driver ends a step with an idle machine, or waits for a dependency.
  defp perform(ctx, _state, %{"phase" => "idle"} = driver, effect), do: {effect, ctx, driver}
  defp perform(ctx, _state, driver, :await), do: {:await, ctx, driver}
  defp perform(ctx, state, driver, effect), do: effect(ctx, state, driver, effect)

  # ---- driver effects ----

  defp effect(ctx, _state, driver, :recover) do
    %{agent_id: agent_id, session_id: session_id, session_recovery: checkpoint} = ctx.data

    {result, revision, _checkpoint} =
      InternalSession.Command.run(agent_id, session_id, ctx.rev, :recover, nil, checkpoint)

    answer(%{ctx | rev: revision}, driver, result)
  end

  defp effect(ctx, _state, driver, {:apply_recovery, recovery}),
    do: answer(apply_recovery(ctx, recovery), driver, :ok)

  # Crash repair events arm the timers they carry.
  defp effect(ctx, _state, driver, {:commit, events, _opts, %{"timers" => true}}) do
    %{agent_id: agent_id, session_id: session_id} = ctx.data

    case commit_revision_events_with_timers(agent_id, session_id, ctx.rev, events) do
      {:ok, committed} -> answer(%{ctx | rev: committed}, driver, :ok)
      {:error, _} = error -> answer(ctx, driver, error)
    end
  end

  defp effect(%{host: host} = ctx, state, driver, {:commit, _, _, _} = effect)
       when is_map(host),
       do: round_effect(ctx, state, driver, effect)

  defp effect(%{chost: chost} = ctx, _state, driver, {:commit, _, _, _} = effect)
       when is_map(chost),
       do: compaction_effect(ctx, driver, effect)

  # A model call that never started records its failure over the session as
  # stored now: the round that failed may have restored its status already.
  defp effect(ctx, _state, driver, {:commit, events, opts, %{"fresh" => true} = mode}),
    do: commit(%{ctx | rev: nil}, driver, {events, opts, mode})

  defp effect(ctx, _state, driver, {:commit, events, opts, mode}),
    do: commit(ctx, driver, {events, opts, mode})

  # The yield events join the working revision without a store round trip;
  # the activation CAS that follows persists them with the materialization.
  defp effect(ctx, _state, driver, {:write, events}) do
    started = System.monotonic_time()

    case InternalSessionStore.write_revision(ctx.rev, events) do
      {:ok, revision} ->
        log_wait_yielded(started)
        answer(%{ctx | rev: revision}, driver, :ok)

      error ->
        answer(ctx, driver, error)
    end
  end

  # No unfenced state leaves a processing entry.
  defp effect(%{rev: %Revision{pending: nil}} = ctx, _state, driver, :fence),
    do: answer(ctx, driver, :ok)

  defp effect(ctx, _state, driver, :fence) do
    %{agent_id: agent_id, session_id: session_id} = ctx.data

    case InternalSessionStore.durable_fence(agent_id, session_id, ctx.rev) do
      {:ok, committed} -> answer(%{ctx | rev: committed}, driver, :ok)
      error -> answer(ctx, driver, error)
    end
  end

  # Activation projects the queued input onto the working revision; the
  # driver decides on the projection.
  defp effect(ctx, _state, driver, {:plan, mode}) do
    {planned, outcome, changed} = InternalSessionStore.plan_revision(ctx.rev, mode)
    answer(%{ctx | rev: planned}, driver, {outcome, changed})
  end

  # The combined activation CAS: the materialization, the visible-reply
  # installation, the prompt snapshot, and the active status.
  # After an async result, only the overlapped activation carries the
  # result's prerequisite; any other activation commits the result alone.
  defp effect(%{entry: :prefetch} = ctx, _state, driver, {:command, :activate, _args}),
    do: answer(ctx, driver, {:error, :sequential_activation})

  defp effect(ctx, _state, driver, {:command, :activate, args}) do
    case run_session_activation(ctx.data, ctx.rev, args) do
      {:ok, data, committed} ->
        ctx = %{ctx | data: data, rev: committed, prepared: prepared_activation(ctx, committed)}
        answer(ctx, driver, :ok)

      {:error, reason, data} ->
        answer(%{ctx | data: forget(data)}, driver, {:error, reason})
    end
  end

  defp effect(ctx, _state, driver, :round_config) do
    case resolve_round_config(ctx.data, ctx.rev.state, nil) do
      {:ok, config, data} ->
        case commit_miniskills(%{ctx | data: data, config: config}, config) do
          {:ok, ctx} -> answer(ctx, driver, {:ok, config_facts(config)})
          {:error, reason, _ctx} -> answer(ctx, driver, {:error, reason})
        end

      {:error, reason, data} ->
        answer(%{ctx | data: data}, driver, {:error, reason})
    end
  end

  defp effect(ctx, _state, driver, {:speculate, args}), do: speculate(ctx, driver, args)
  defp effect(ctx, _state, driver, :await_fence), do: await_fence(ctx, driver)

  # A round after a lost compaction race reads the winner's durable view; it
  # never reuses the losing projection.
  defp effect(ctx, _state, driver, :refresh) do
    %{agent_id: agent_id, session_id: session_id} = ctx.data

    case InternalSessionStore.read_revision(agent_id, session_id) do
      {:ok, revision} ->
        answer(%{ctx | rev: revision, data: retain(ctx.data, revision)}, driver, :ok)

      {:error, reason} ->
        answer(%{ctx | data: forget(ctx.data)}, driver, {:error, unstarted(reason)})
    end
  end

  defp effect(ctx, _state, driver, {:set_timer, :wait, _wait}) do
    register_current_wait_timer(ctx.data, ctx.rev.state)
    answer(ctx, driver, :ok)
  end

  # A failed registration keeps the durable wait; the timeout answers it.
  defp effect(ctx, _state, driver, {:set_timer, :wait_for, wait}) do
    %{agent_id: agent_id, session_id: session_id} = ctx.data

    case SalixAgent.Waits.register_timer_for_wait(agent_id, session_id, wait) do
      :ok -> answer(ctx, driver, :ok)
      error -> answer(%{ctx | result: error}, driver, :ok)
    end
  end

  defp effect(ctx, _state, driver, {:set_timer, :retry, retry_at}),
    do: answer(%{ctx | data: schedule_llm_retry(ctx.data, retry_at)}, driver, :ok)

  defp effect(ctx, _state, driver, {:cancel_timer, :retry}),
    do: answer(%{ctx | data: cancel_llm_retry_timer(ctx.data)}, driver, :ok)

  defp effect(ctx, _state, driver, {:fact, {:delegates_busy, wait}}) do
    %{agent_id: agent_id, session_id: session_id} = ctx.data
    answer(ctx, driver, SalixAgent.WaitExtension.busy?(agent_id, session_id, wait))
  end

  defp effect(%{host: nil, llm: nil} = ctx, _state, driver, {:fact, :canonical_router}),
    do: answer(ctx, driver, canonical_router_session?(ctx.data))

  defp effect(%{host: nil} = ctx, state, driver, {:fact, :canonical_router}),
    do: answer(ctx, driver, SalixAgent.TerminalReply.canonical_router?(state))

  defp effect(%{host: nil} = ctx, _state, driver, {:notify, :wait_extended, {wait, path}}) do
    log_wait_extended(ctx.data.agent_id, ctx.data.session_id, wait, path)
    answer(ctx, driver, :ok)
  end

  defp effect(ctx, _state, driver, {:round_prepare, kind}), do: round_prepare(ctx, driver, kind)

  defp effect(ctx, _state, driver, {:round_abandon, reason}) do
    _ = Round.abandon(ctx.prep, reason)
    answer(%{ctx | prep: nil}, driver, :ok)
  end

  defp effect(ctx, _state, driver, {:call_model, request, facts}),
    do: call_model(ctx, driver, request, facts)

  defp effect(%{llm: %{} = llm, host: nil} = ctx, _state, driver, {:round, _facts}) do
    case Round.response_host(
           round_context(ctx),
           llm.pending,
           llm.response,
           llm.duration_ms,
           llm.meter_meta
         ) do
      {:ok, host} -> answer(%{ctx | host: host}, driver, :ok)
      {:error, _} = error -> answer(ctx, driver, error)
    end
  end

  defp effect(ctx, _state, driver, {:round_outcome, outcome}),
    do: round_outcome(ctx, driver, outcome)

  defp effect(%{lost: %{}} = ctx, _state, driver, {:call_failed, committed}),
    do: round_lost(ctx, driver, committed)

  # A model call that never started.
  defp effect(ctx, _state, driver, {:call_failed, committed}) do
    if committed, do: notify_session_updated(ctx.data)
    :ok = SalixAgent.ActivityEvent.idle(ctx.data.agent_id, ctx.data.session_id)
    answer(ctx, driver, :ok)
  end

  defp effect(ctx, _state, driver, effect)
       when effect == :compaction_config or
              elem(effect, 0) in [:summarize, :compacted, :compaction_facts, :compaction_prompt],
       do: compaction_effect(ctx, driver, effect)

  # The effects of a round's loop: its record, tools, results, notices, and
  # commits.
  defp effect(ctx, state, driver, effect), do: round_effect(ctx, state, driver, effect)

  # A commit that meets a newer session asks the driver to rebuild the step
  # against it; a rebuilt step that took another branch continues from there.
  defp commit(ctx, driver, step) do
    %{agent_id: agent_id, session_id: session_id} = ctx.data

    case SessionDriver.commit(agent_id, session_id, ctx.rev, driver, step) do
      {:ok, revision, driver} ->
        answer(%{ctx | rev: revision}, driver, :ok)

      {:rerouted, revision, driver, effect} ->
        perform(%{ctx | rev: revision}, revision.state, driver, effect)

      {:error, reason} = error ->
        Logger.warning(
          "internal session #{agent_id}/#{session_id} commit failed: #{inspect(reason)}"
        )

        answer(ctx, driver, error)
    end
  end

  defp round_effect(ctx, state, driver, effect) do
    host = %{ctx.host | context: Map.put(ctx.host.context, :revision, ctx.rev)}

    case Round.effect(host, state, driver, effect) do
      {:answer, value, host, driver} ->
        answer(with_host(ctx, host), driver, value)

      {:rerouted, host, state, driver, effect} ->
        perform(with_host(ctx, host), state, driver, effect)
    end
  end

  defp with_host(ctx, host), do: %{ctx | host: host, rev: host.context[:revision] || ctx.rev}

  defp round_context(ctx),
    do: Map.put(ctx.ccontext || runtime_context(ctx.data), :revision, ctx.rev)

  defp config_facts(config) do
    %{
      "prompt" => config.session_config.system_prompt,
      "compaction" => Compaction.required_facts(config.llm_opts)
    }
  end

  defp prepared_activation(%{config: nil}, _revision), do: nil

  defp prepared_activation(%{config: config}, revision) do
    %{
      session: revision.state,
      revision: revision,
      session_config: config.session_config,
      llm_opts: config.llm_opts
    }
  end

  defp unstarted(reason), do: {:unstarted, llm_failure_detail(reason)}

  defp llm_failure_detail(reason), do: inspect(reason, limit: 20, printable_limit: 2048)

  # A direct round (an operator or test entry) runs on the same driver as the
  # owner's own rounds. Its caller gets the round's result, and a failure is
  # the caller's to handle, so it applies no recovery.
  defp direct_round(data, revision, context, opts) do
    ctx = driven(data, revision, :direct, %{ccontext: context, ropts: opts})

    case run(ctx, {:round_run, :normal}) do
      {:await, _ctx, _driver} = step ->
        data = conclude(step)
        context = Map.put(context, :revision, data.revision)
        {{:ok, context, {:llm_pending, data.pending_llm}}, data}

      {{failure, reason}, ctx, _driver} when failure in [:round_failure, :activation_error] ->
        {{:error, reason}, forget(ctx.data)}

      {{:recovery_failure, _stage, reason}, ctx, _driver} ->
        {{:error, reason}, forget(ctx.data)}

      {_end, ctx, _driver} = step ->
        {ctx.result || {:error, :round_not_run}, conclude(step)}
    end
  end

  # ---- recovery ----

  defp apply_recovery(ctx, recovery) do
    recovery = struct!(Recovery, recovery) |> Map.put(:session, ctx.rev && ctx.rev.state)

    data =
      case recovery.action do
        action when action in [:continue, :settled] ->
          ctx.data |> retain(ctx.rev) |> retire_repaired_async_tool_owners(ctx.rev)

        _failed ->
          Logger.warning(
            "internal session #{ctx.data.agent_id}/#{ctx.data.session_id} repair failed: #{inspect(recovery.reason)}"
          )

          ctx.data
      end

    %{ctx | data: apply_session_recovery(data, recovery)}
  end

  # ---- the overlapped activation ----
  #
  # The activation CAS and the first provider request run in parallel: the
  # activation is prepared up to its durable fence, the fence runs in a task,
  # and the round starts the provider dependency behind a persistence gate
  # that opens only once the fence has landed. The owner stays in this
  # callback until then, so no other mailbox entry writes through the
  # in-flight CAS. A failed fence cancels the speculative request; the
  # ordinary recovery path re-reads and re-activates.
  #
  # A blocked session (a provider call, compaction or retry timer pending)
  # never speculates: the retry fence decides when the next round may start.
  defp speculate(ctx, driver, args) do
    data = ctx.data

    with false <- process_blocked?(data),
         {{:awaiting_fence, continuation}, prepared, _checkpoint} <-
           InternalSession.Command.prepare(
             data.agent_id,
             data.session_id,
             ctx.rev,
             :activate,
             args,
             data.session_checkpoint
           ),
         {:ok, task} <-
           InternalSessionStore.start_command_fence(
             data.agent_id,
             data.session_id,
             continuation,
             ctx.prerequisite
           ) do
      ctx = %{ctx | fence: task, gate: make_ref(), rev: prepared}
      answer(%{ctx | prepared: prepared_activation(ctx, prepared)}, driver, :started)
    else
      _not_speculating -> answer(ctx, driver, :sequential)
    end
  end

  # The fence is always joined, even when the round did not start.
  defp await_fence(ctx, driver) do
    data = ctx.data

    with {:ok, confirmed} <- InternalSessionStore.await_durable_fence(ctx.fence),
         {:ok, committed, checkpoint} <-
           InternalSession.Command.resume_fence(data.agent_id, data.session_id, confirmed) do
      register_committed_timers(data.agent_id, ctx.events)
      data = %{data | session_checkpoint: checkpoint} |> retain(committed) |> fence_landed(ctx)
      ctx = %{ctx | data: open_gate(data), rev: committed, fence: nil}
      answer(%{ctx | prepared: prepared_activation(ctx, committed)}, driver, :ok)
    else
      {:error, reason} ->
        failed(ctx, driver, reason)

      {{:error, reason}, _revision, _checkpoint} ->
        failed(ctx, driver, reason)
    end
  end

  # An inbound activation settles the retry state when its fence lands. After
  # an async result, the result commit that follows settles it and notifies.
  defp fence_landed(data, %{entry: :prefetch}), do: data

  defp fence_landed(data, _ctx) do
    data = reset_session_retry(data)
    notify_session_updated(data)
    data
  end

  # A failed fence cancels the speculative request of an inbound activation.
  # After an async result, the gated request stays pending: it blocks another
  # dispatch while the result commit retries, and that commit releases it.
  defp failed(%{entry: :prefetch} = ctx, driver, reason),
    do: answer(%{ctx | fence: nil}, driver, {:error, reason})

  defp failed(ctx, driver, reason) do
    data = ctx.data |> release_failed_prefetch() |> forget()
    answer(%{ctx | data: data, fence: nil}, driver, {:error, reason})
  end

  # The activation landed: a model call that started beside it may publish.
  defp open_gate(%{pending_llm: %{persistence_gate: gate} = llm} = data) do
    :ok =
      SalixAgent.ActivityEvent.thinking(
        data.agent_id,
        data.session_id,
        nil,
        llm[:visible_reply_scope]
      )

    send(llm.pid, {:persistence_fence, gate, true})
    %{data | pending_llm: Map.delete(llm, :persistence_gate)}
  end

  defp open_gate(data), do: data

  # ---- rounds ----

  # A round that the driver prepares is not the answered model call: its
  # failure recovers as a round failure.
  defp round_prepare(ctx, driver, :failure) do
    {config, host} = Round.failure_config(round_context(ctx), ctx.data.session_id)
    answer(%{ctx | host: host, kind: :failure, llm: nil}, driver, {:ok, config})
  end

  defp round_prepare(ctx, driver, kind) do
    case round_config(%{ctx | llm: nil}, kind) do
      {:ok, ctx} ->
        data = ctx.data
        started = data.activation_started_ms
        # The stamp belongs to exactly one dispatch; a later round on this
        # actor gets its own from its own processing entry.
        ctx = %{ctx | data: %{data | activation_started_ms: nil}, kind: kind}
        {context, opts} = round_opts(ctx, kind)
        opts = maybe_put_activation_started(opts, started)

        # The request is built over the session that the preparation
        # committed: its active status and prompt snapshot.
        case Round.prepare(context, data.session_id, opts) do
          {:guard, config, host} ->
            answer(
              %{ctx | host: host, rev: host.context[:revision] || ctx.rev},
              driver,
              {:ok, config}
            )

          {:request, config, prep} ->
            answer(
              %{ctx | prep: prep, rev: prep.context[:revision] || ctx.rev},
              driver,
              {:ok, config}
            )

          {:error, _} = error ->
            answer(ctx, driver, error)
        end

      {:error, reason, ctx} ->
        ctx = %{ctx | data: forget(ctx.data), result: {:error, reason}}
        answer(ctx, driver, {:error, unstarted(reason)})
    end
  end

  # A round on an activation uses the configuration its activation resolved;
  # any other round resolves its own.
  defp round_config(%{config: %{}, prepared: %{}} = ctx, kind)
       when kind in [:guard, :prepared, :speculative],
       do: {:ok, ctx}

  defp round_config(ctx, _kind) do
    case resolve_round_config(ctx.data, ctx.rev.state, nil) do
      {:ok, config, data} ->
        commit_miniskills(%{ctx | data: data, config: config, prepared: nil}, config)

      {:error, reason, data} ->
        {:error, reason, %{ctx | data: data}}
    end
  end

  defp round_opts(ctx, :speculative) do
    context = Map.put(round_context(ctx), :persistence_gate, ctx.gate)

    {context,
     [resolved_round_config: ctx.config, prepared_activation: ctx.prepared, speculative: true]}
  end

  defp round_opts(ctx, kind) do
    opts =
      [resolved_round_config: ctx.config, runtime_failure_reply: kind == :guard]
      |> maybe_put_prepared_activation(ctx.prepared)

    {round_context(ctx), Keyword.merge(ctx.ropts, opts)}
  end

  defp call_model(ctx, driver, request, facts) do
    data = ctx.data

    case Round.start(ctx.prep, request, facts) do
      # The speculative call waits for its activation's fence.
      {:ok, _context, {:llm_pending, pending}} when ctx.kind == :speculative ->
        data = %{data | pending_llm: Map.put(pending, :persistence_gate, ctx.gate)}
        answer(%{ctx | data: data, prep: nil}, driver, :started)

      {:ok, context, {:llm_pending, pending}} ->
        data = data |> retain(context) |> reset_session_retry()
        notify_session_updated(data)
        data = %{data | pending_llm: pending} |> stop_cancelled_pending_async_tools(context)
        answer(%{ctx | data: data, prep: nil, rev: context.revision}, driver, :started)

      {:error, {:dependency_saturated, :llm} = reason} ->
        Logger.warning(
          "internal session #{data.agent_id}/#{data.session_id} llm admission failed: #{inspect(reason)}"
        )

        answer(%{ctx | prep: nil, result: {:error, reason}}, driver, {:error, unstarted(reason)})

      {:error, _} = error ->
        answer(%{ctx | prep: nil}, driver, error)
    end
  end

  # A round's outcome, before the driver decides what follows it.
  defp round_outcome(ctx, driver, outcome) do
    result = Round.round_result(ctx.host, outcome)
    ctx = %{ctx | host: nil, result: result}

    case result do
      {:ok, context, outcome} ->
        data = ctx.data |> retain(context) |> reset_session_retry()

        answer(
          %{ctx | data: settle_round(data, context, outcome), rev: context.revision},
          driver,
          :ok
        )

      {:error, _reason} ->
        answer(ctx, driver, :ok)
    end
  end

  defp settle_round(data, context, {:async_tools_started, pending} = outcome) do
    pending_async_tools =
      Enum.reduce(pending, data.pending_async_tools, fn item, acc ->
        Map.put(acc, item.ref, item)
      end)

    notify_session_updated(data)

    %{data | pending_async_tools: pending_async_tools}
    |> stop_cancelled_pending_async_tools(context)
    |> reply_direct_round_waiter({:ok, context, outcome})
  end

  # Compaction follows an overflow. A candidate that cannot reserve a
  # disposition must not immediately redispatch; send refusals already
  # reserve and settle their source.
  defp settle_round(data, _context, outcome)
       when outcome in [:context_overflow, :guard_failure_parked],
       do: data

  defp settle_round(data, context, outcome) do
    notify_session_updated(data)
    _ = SalixAgent.Titles.maybe_generate_async(context, data.session_id)
    _ = TrajectoryEval.Runner.maybe_eval_async(context, data.session_id, outcome)

    data
    |> stop_cancelled_pending_async_tools(context)
    |> reply_direct_round_waiter({:ok, context, outcome})
  end

  # The events of a lost model call have landed, or could not.
  defp round_lost(%{lost: %{pending: pending, reason: reason}} = ctx, driver, committed) do
    data = ctx.data

    if committed do
      SalixAgent.RunTelemetry.emit_agent_run(
        (pending[:meter_ctx] || %{})
        |> Map.merge(%{
          agent_id: data.agent_id,
          salix_agent_id: data.agent_id,
          session_id: pending.session_id,
          session: ctx.rev.state,
          trace_ctx: pending[:trace_ctx],
          status: "actor_failed"
        })
      )
    end

    activity_scope = pending[:visible_reply_scope]
    SalixAgent.ActivityEvent.llm_failed(data.agent_id, pending.session_id, activity_scope)
    SalixAgent.ActivityEvent.idle(data.agent_id, pending.session_id, activity_scope)
    notify_session_updated(data)

    _ =
      TrajectoryEval.Runner.maybe_eval_async(
        %{agent_id: data.agent_id, session_id: pending.session_id},
        pending.session_id,
        {:error, reason}
      )

    answer(%{ctx | data: reply_direct_round_waiter(data, {:error, reason})}, driver, :ok)
  end

  # ---- model calls ----

  # A speculative request whose activation fence never landed is not the
  # session's model call: its gate stayed closed, so nothing it produced was
  # published. Its answer or failure is dropped, and processing continues.
  defp complete_llm_response(data, %{persistence_gate: _} = pending, _response, _ms, _meta),
    do: drop_unfenced_llm(data, pending)

  defp complete_llm_response(data, pending, response, duration_ms, meter_meta) do
    SalixStore.ReadScope.run(fn ->
      {revision, data} = resident_revision(data)

      llm = %{
        pending: pending,
        response: response,
        duration_ms: duration_ms,
        meter_meta: meter_meta
      }

      data
      |> driven(revision, :response, %{llm: llm})
      |> run(pending.driver, {:model, response})
      |> conclude()
    end)
  end

  # A failed provider call ends the current activation. The driver records the
  # failure at the round's transcript position and processes again only when
  # input arrived during the call, so the same transcript is not requested
  # again at once.
  defp fail_pending_llm(data, %{persistence_gate: _} = pending, _reason),
    do: drop_unfenced_llm(data, pending)

  defp fail_pending_llm(data, pending, reason) do
    # The job is already dead; the progress array it wrote to is not.
    progress = SalixAgent.StreamProgress.snapshot(pending[:stream_progress])

    Logger.warning(
      "internal session #{data.agent_id}/#{pending.session_id} llm task failed: #{inspect(reason)}" <>
        stream_progress_summary(progress),
      stream_progress: progress
    )

    record_killed_attempt(pending, reason, progress)

    case pending[:visible_reply_scope] do
      %{} = scope -> VisibleReply.cancel(data.agent_id, pending.session_id, scope)
      _ -> :ok
    end

    {revision, data} = resident_revision(data)

    facts = %{
      "detail" => llm_failure_detail(reason),
      "queue_snapshot" => pending[:next_queue_id_snapshot]
    }

    data
    |> driven(revision, :lost, %{lost: %{pending: pending, reason: reason}})
    |> run(pending.driver, {:model_lost, facts})
    |> conclude()
  end

  # A dependency failure can end an attempt the retry loop never saw return,
  # so the loop's per-attempt fact is written here instead, with what the
  # stream had received (see `SalixAgent.AttemptTelemetry`). An attempt that
  # already returned has its fact from the loop: the job died after it (a
  # retry backoff, an exhausted request re-raising, work after a completed
  # call), and writing it again would replace that row under the same key.
  defp record_killed_attempt(_pending, _reason, %{in_flight: false}), do: :ok

  defp record_killed_attempt(pending, reason, progress)
       when is_tuple(reason) and tuple_size(reason) >= 2 and
              elem(reason, 0) in [:dependency_timeout, :dependency_crashed] do
    _ =
      SalixAgent.AttemptTelemetry.emit_killed(
        pending[:meter_ctx] || %{},
        SalixAgent.Round.llm_request_max_attempts(),
        reason,
        progress
      )

    :ok
  end

  defp record_killed_attempt(_pending, _reason, _progress), do: :ok

  defp stream_progress_summary(nil), do: ""

  defp stream_progress_summary(progress) do
    state = if progress.in_flight, do: "in flight", else: "returned"

    " (attempt #{progress.attempt} #{state}, #{progress.elapsed_ms} ms in: " <>
      "#{progress.received_chunks || 0} body chunks / #{progress.received_bytes || 0} bytes, " <>
      "first at #{progress.first_body_ms || "-"} ms, last at #{progress.last_body_ms || "-"} ms; " <>
      "#{progress.content_deltas} content deltas, last at #{progress.last_content_ms || "-"} ms)"
  end

  defp drop_unfenced_llm(data, pending) do
    Logger.info(
      "internal session #{data.agent_id}/#{pending.session_id} dropped a speculative model call whose activation did not land"
    )

    request_process(data)
  end

  # A session that does not exist yet is born by its first commit.
  defp resident_or_new(data) do
    case owned_revision(data) do
      {:error, :not_found} -> {:ok, nil, forget(data)}
      other -> other
    end
  end

  defp resident_revision(data) do
    case owned_revision(data) do
      {:ok, revision, data} -> {revision, data}
      {:error, _} -> {nil, forget(data)}
    end
  end

  # ---- compaction ----

  defp start_compaction(data, mode, context, opts, continuation) do
    event = Compaction.event(mode, opts, elem(continuation, 0))

    data
    |> driven(data.revision, :compaction, %{
      ccontext: context,
      copts: opts,
      continuation: continuation
    })
    |> run(event)
    |> conclude()
  end

  # A compaction that maybe runs before a round, or recovers an overflow. A
  # session that was never stored compacts its new state.
  defp compaction_host(%{chost: nil} = ctx, state) do
    context = Map.put(ctx.ccontext || runtime_context(ctx.data), :revision, ctx.rev)
    Compaction.host(context, state, ctx.copts)
  end

  defp compaction_host(%{chost: chost, rev: %Revision{} = revision}, _state) do
    %{chost | context: Map.put(chost.context, :revision, revision), state: revision.state}
  end

  defp compaction_host(%{chost: chost}, _state), do: chost

  defp compaction_effect(ctx, driver, effect) do
    {ctx, state} = working_state(ctx)

    case Compaction.perform(compaction_host(ctx, state), driver, effect) do
      {:answer, value, chost, driver} ->
        answer(with_chost(ctx, chost), driver, value)

      {:rerouted, chost, driver, effect} ->
        ctx = with_chost(ctx, chost)
        {ctx, state} = working_state(ctx)
        perform(ctx, state, driver, effect)

      {:summarize, plan} ->
        summarize(%{ctx | chost: plan}, driver, plan)

      {:result, result} ->
        compacted(%{ctx | chost: nil}, driver, result)
    end
  end

  # Archiving writes the session again behind the committed revision; the
  # next step reads the archived state once.
  defp with_chost(ctx, chost), do: %{ctx | chost: chost, rev: chost.context[:revision]}

  defp summarize(ctx, driver, plan) do
    dependency = fn -> Compaction.execute_prepared(plan) end

    case DependencyJob.start(:compaction, plan.tenant_id, dependency) do
      {:ok, job} ->
        log_compaction_job(plan, "compaction_job_pending", job.timeout_ms)

        # Keep the actor-observable identity from #806 while fencing all
        # protocol messages on DependencyJob's exact token.
        pending = %{ref: job.ref, dependency_job: job, plan: plan}
        answer(%{ctx | data: %{ctx.data | pending_compaction: pending}}, driver, :started)

      # Admission failure is a typed dependency terminal too. The activation
      # continues only after its failure result is durable.
      {:error, :dependency_saturated} ->
        answer(
          ctx,
          driver,
          Compaction.summarized(plan, {:error, {:dependency_saturated, :compaction}})
        )

      {:error, reason} ->
        reason = {:dependency_start_failed, :compaction, reason}
        answer(ctx, driver, Compaction.summarized(plan, {:error, reason}))
    end
  end

  # The summary answered, or its dependency failed. A crash or timeout is a
  # user-dependency outcome, not an actor failure: the caller or activation
  # continues only after that exact failure has landed.
  defp finish_compaction(data, pending, outcome) do
    {revision, data} = resident_revision(data)
    ctx = Map.merge(pending.ctx, %{data: data, rev: revision, chost: pending.plan})

    ctx
    |> run(pending.driver, {:done, Compaction.summarized(pending.plan, outcome)})
    |> conclude()
  end

  defp fail_compaction(data, pending, reason) do
    Logger.warning(
      "internal session #{data.agent_id}/#{data.session_id} compaction dependency failed: #{inspect(reason)}"
    )

    finish_compaction(data, pending, {:error, reason})
  end

  # The compaction's result reaches its continuation before the driver
  # decides what follows it.
  defp compacted(ctx, driver, result) do
    data = retain_round_result(ctx.data, result)

    case {ctx.continuation, result} do
      # Explicit synchronous callers preserve Compaction's public return shape:
      # a durably committed dependency failure is an ordinary failed_* result;
      # only a failed owner/store commit is returned as {:error, reason}.
      {{:reply, from}, _result} ->
        GenServer.reply(from, result)

      {{:control, _entry}, {:ok, _context, _result}} ->
        notify_session_updated(data)

      # This control was already acknowledged. Bind a terminal to its source
      # if possible; unlike the overlapping-control branch, this is a real
      # commit failure rather than a semantic noop.
      {{:control, entry}, {:error, reason}} ->
        _ = commit_session_compact_hard_failure(data, entry, reason)

        Logger.warning(
          "internal session #{data.agent_id}/#{data.session_id} compact control failed: #{inspect(reason)}"
        )

      {_round, {:error, reason}} ->
        Logger.info(
          "internal session #{data.agent_id}/#{data.session_id} compaction did not commit: #{inspect(reason)}"
        )

      {_round, _ok} ->
        :ok
    end

    ctx = %{ctx | data: data, rev: data.revision}
    answer(ctx, driver, :ok)
  end

  # ---- the end of a step ----

  # The owner retains what the step left behind and applies the step's end.
  defp conclude({effect, ctx, driver}) do
    data = ctx.data

    case effect do
      :idle ->
        retain(data, ctx.rev)

      :reprocess ->
        data |> retain(ctx.rev) |> request_process()

      # A model call or summary is running; the driver continues when it
      # answers.
      :await ->
        data = retain(data, ctx.rev)

        case driver["phase"] do
          "model" ->
            %{data | pending_llm: Map.put(data.pending_llm, :driver, driver)}

          "compaction" ->
            pending = Map.merge(data.pending_compaction, %{driver: driver, ctx: suspended(ctx)})
            %{data | pending_compaction: pending}
        end

      {:apply_recovery, recovery} ->
        apply_recovery(ctx, recovery).data

      {:fast_end, _outcome} ->
        retain(data, ctx.rev)

      {:recovery_failure, stage, reason} ->
        Logger.warning(
          "internal session #{data.agent_id}/#{data.session_id} #{stage} failed: #{inspect(reason)}"
        )

        apply_session_recovery(
          forget(data),
          Recovery.failure(data.session_recovery, stage, reason)
        )

      {:activation_error, reason} ->
        apply_session_recovery(
          forget(data),
          Recovery.round_failure(data.session_recovery, reason)
        )

      {:round_failure, reason} ->
        round_failure(ctx, reason)
    end
  end

  defp suspended(ctx), do: Map.drop(ctx, [:data, :rev, :chost])

  defp round_failure(%{llm: %{pending: pending}} = ctx, reason) do
    data = ctx.data

    Logger.warning(
      "internal session #{data.agent_id}/#{data.session_id} llm response failed: #{inspect(reason)}"
    )

    context = %{agent_id: data.agent_id, session_id: data.session_id}
    _ = TrajectoryEval.Runner.maybe_eval_async(context, data.session_id, {:error, reason})

    data
    |> forget()
    |> apply_session_recovery(Recovery.handoff(pending, reason))
    |> reply_direct_round_waiter({:error, reason})
  end

  defp round_failure(ctx, reason) do
    data = ctx.data
    _ = if ctx.host, do: Round.round_failed(ctx.host, reason)

    Logger.warning(
      "internal session #{data.agent_id}/#{data.session_id} round failed: #{inspect(reason)}"
    )

    context = %{agent_id: data.agent_id, session_id: data.session_id}
    _ = TrajectoryEval.Runner.maybe_eval_async(context, data.session_id, {:error, reason})

    reconciliation = Recovery.round_failure(data.session_recovery, reason)
    data = apply_session_recovery(forget(data), reconciliation)

    if reconciliation.action == :error do
      :ok = SalixAgent.ActivityEvent.idle(data.agent_id, data.session_id)
    end

    data
  end

  # The processing entry that follows a delivery consults the agent's control
  # record (the Router check, the round's reply policy). Reading it while the
  # delivery commit is in flight takes that round trip off the path to the
  # model request; the entry's read scope starts from the prefetched record.
  defp start_control_prefetch(%{control_prefetch: nil} = data) do
    agent_id = data.agent_id

    task =
      Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
        SalixAgent.Control.get_record(agent_id)
      end)

    %{data | control_prefetch: task}
  rescue
    _ -> data
  catch
    :exit, _ -> data
  end

  defp start_control_prefetch(data), do: data

  defp join_control_prefetch(%{control_prefetch: {:done, result}} = data),
    do: {control_prefetch_seed(data.agent_id, result), %{data | control_prefetch: nil}}

  defp join_control_prefetch(%{control_prefetch: %Task{} = task} = data) do
    data = %{data | control_prefetch: nil}

    case Task.yield(task, @control_prefetch_join_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {control_prefetch_seed(data.agent_id, result), data}
      _late -> {%{}, data}
    end
  end

  defp join_control_prefetch(data), do: {%{}, data}

  defp control_prefetch_seed(agent_id, {:ok, record}) when is_map(record),
    do: %{{:record, SalixStore.Keys.ctl_agent(agent_id)} => {:ok, record}}

  defp control_prefetch_seed(_agent_id, _failed), do: %{}

  # A committed delivery into a cold actor starts the round configuration
  # build now, so its catalog, skill and plugin reads overlap the activation
  # commits that precede the first model request. The catalog context is the
  # same platform the activation derives from the session.
  defp prewarm_round_config({:ok, :committed}, %{revision: %Revision{state: session}} = data) do
    build = round_snapshot_builder(data.agent_id, round_config_context(session))

    %{
      data
      | round_config_cache: SalixAgent.RoundConfigCache.prewarm(data.round_config_cache, build)
    }
  end

  defp prewarm_round_config(_result, data), do: data

  # A build the delivery facade started for this agent is adopted first;
  # materialization applies this session's platform to either.
  defp round_snapshot_builder(agent_id, context) do
    catalog_context = Map.take(context, [:platform])

    fn ->
      SalixAgent.RoundConfigPrewarm.take(agent_id, fn ->
        SalixAgent.RoundConfig.build_round_snapshot(agent_id, catalog_context)
      end)
    end
  end

  defp prefetch_round_refresh(
         %{
           round_config_cache: %{current: %{role: "router"} = snapshot},
           revision: %Revision{state: session}
         } = data
       ) do
    SalixAgent.RoundConfig.prefetch_round_refresh(
      data.agent_id,
      snapshot,
      round_config_context(session)
    )
  end

  defp prefetch_round_refresh(_data), do: :ok

  defp resolve_round_config(data, projected, _previous) do
    context = round_config_context(projected)
    miniskill_deadline = System.monotonic_time(:millisecond) + 1_000

    case SalixAgent.RoundConfigCache.begin_round(
           data.round_config_cache,
           round_snapshot_builder(data.agent_id, context)
         ) do
      {:ok, snapshot, cache} ->
        data = %{data | round_config_cache: cache}

        miniskills =
          SalixAgent.MiniskillSelector.start(
            projected,
            snapshot.session_config,
            data.agent_id,
            data.session_id,
            miniskill_deadline
          )

        with {:ok, snapshot} <-
               SalixAgent.RoundConfig.join_round_refresh(data.agent_id, snapshot, context),
             {:ok, config} <-
               SalixAgent.RoundConfig.materialize_round_snapshot(
                 data.agent_id,
                 snapshot,
                 context
               ) do
          event = SalixAgent.MiniskillSelector.finish(miniskills, config.session_config)

          config = put_in(config.session_config[:miniskill_timing], event && event["timing"])

          {:ok, Map.put(config, :miniskill_event, event),
           %{data | round_config_cache: %{cache | current: snapshot}}}
        else
          {:error, reason} ->
            SalixAgent.MiniskillSelector.finish(miniskills, snapshot.session_config)
            {:error, reason, data}
        end

      {:error, reason, cache} ->
        {:error, reason, %{data | round_config_cache: cache}}
    end
  end

  defp commit_miniskills(ctx, %{miniskill_event: %{} = event}) do
    with {:ok, revision} <-
           InternalSessionStore.commit_revision(
             ctx.data.agent_id,
             ctx.data.session_id,
             ctx.rev,
             [event]
           ) do
      {:ok, %{ctx | rev: revision, data: retain(ctx.data, revision)}}
    else
      {:error, reason} -> {:error, reason, ctx}
    end
  end

  defp commit_miniskills(ctx, _), do: {:ok, ctx}

  # The round configuration receives plain data, never the session itself:
  # identity, platform, the admitted source ids, and the current turn's
  # trusted origins, which tool disclosure needs to see a Task-delegated
  # grant. One projection serves every configuration path.
  defp round_config_context(session) when InternalSession.is_session(session),
    do: SalixAgent.RoundConfig.round_session_context(session)

  defp run_session_activation(data, revision, args) do
    {result, committed, checkpoint} =
      InternalSession.Command.run(
        data.agent_id,
        data.session_id,
        revision,
        :activate,
        args,
        data.session_checkpoint
      )

    data = %{data | session_checkpoint: checkpoint}

    case result do
      :ok -> {:ok, retain(data, committed), committed}
      {:error, reason} -> {:error, reason, data}
    end
  end

  # The kernel reads the wait-extension ceiling from configuration.
  defp loop_facts, do: InternalSession.activation_facts()

  defp log_wait_yielded(started) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "router_wait_yield",
      "salix",
      "ok",
      System.monotonic_time() - started
    )

    Logger.info("router generic wait yielded to queued input",
      event: "router_wait_yielded",
      component: "salix_agent",
      outcome: "blocked"
    )
  end

  defp cancel_llm_retry_timer(%{llm_retry_timer: nil} = data), do: data

  defp cancel_llm_retry_timer(%{llm_retry_timer: {_token, timer}} = data) do
    Process.cancel_timer(timer)
    %{data | llm_retry_timer: nil}
  end

  defp schedule_llm_retry(data, retry_at) do
    data = cancel_llm_retry_timer(data)
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:llm_retry, token},
        max(0, retry_at - System.system_time(:millisecond))
      )

    %{data | llm_retry_timer: {token, timer}}
  end

  defp canonical_router_session?(data) do
    with {:ok, %{"role" => "router"} = agent} <- SalixAgent.Control.get(data.agent_id),
         {:ok, session_id} <- SalixStore.RuntimeIds.persisted_router_session_id(agent) do
      session_id == data.session_id
    else
      _ -> false
    end
  end

  defp log_wait_extended(agent_id, session_id, wait, path) do
    CommaLog.log("wait_timeout_extended", %{
      agent_id: agent_id,
      session_id: session_id,
      wait_id: wait["wait_id"],
      extended_from: wait["extended_from"],
      extensions: wait["extensions"],
      timeout_seconds: wait["timeout_seconds"],
      path: path
    })
  end

  defp prepare_session_activation(data, %Revision{} = revision) do
    run_session_activation(data, revision, {[], 0, nil, false})
  end

  defp log_compaction_job(prepared, event, timeout_ms) do
    SalixAgent.SubscriptionLog.emit(event,
      agent_id: prepared.agent_id,
      session_id: prepared.session_id,
      timeout_ms: timeout_ms
    )
  end

  defp maybe_put_prepared_activation(opts, nil), do: opts

  defp maybe_put_prepared_activation(opts, prepared),
    do: Keyword.put(opts, :prepared_activation, prepared)

  defp maybe_put_activation_started(opts, nil), do: opts

  defp maybe_put_activation_started(opts, started_ms) when is_integer(started_ms),
    do: Keyword.put(opts, :activation_started_ms, started_ms)

  defp reply_direct_round_waiter(%{direct_round_waiter: nil} = data, _result), do: data

  defp reply_direct_round_waiter(%{direct_round_waiter: from} = data, result) do
    GenServer.reply(from, result)
    %{data | direct_round_waiter: nil}
  end

  # A wake is level-triggered state, not a one-shot mailbox edge. Keep the bit
  # set while a dependency or retry fence parks the actor, and place at most
  # one process message in the mailbox once that fence clears.
  defp request_process(data) do
    data
    |> Map.put(:wake_pending, true)
    |> maybe_schedule_process()
  end

  defp maybe_schedule_process(data) do
    data =
      if map_size(data.source_waiters) > 0 and not process_blocked?(data) do
        Enum.each(data.source_waiters, fn {{owner, source}, _} ->
          send(owner, {:retry_conversation_source, source})
        end)

        %{data | source_waiters: %{}}
      else
        data
      end

    schedule_process(data)
  end

  defp schedule_process(%{wake_pending: true, process_scheduled: false} = data) do
    if process_blocked?(data) do
      data
    else
      send(self(), :process)
      %{data | process_scheduled: true}
    end
  end

  defp schedule_process(data), do: data

  defp process_blocked?(data) do
    is_map(data.pending_llm) or
      is_map(data.pending_compaction) or
      not is_nil(data.session_retry_timer)
  end

  defp noreply(data) do
    data = maybe_schedule_process(data)
    {:noreply, data, :infinity}
  end

  defp reply(response, data) do
    data = maybe_schedule_process(data)
    {:reply, response, data, :infinity}
  end

  defp idle?(%{llm_retry_timer: timer}) when not is_nil(timer), do: false

  defp idle?(%{session_retry_timer: timer}) when not is_nil(timer), do: false

  defp idle?(%{
         wake_pending: false,
         process_scheduled: false,
         pending_llm: nil,
         pending_compaction: nil,
         pending_async_tools: pending,
         pending_async_tool_commits: commits,
         ssh_sessions: ssh_sessions
       })
       when map_size(pending) == 0 and map_size(commits) == 0,
       do: not SalixAgent.SSH.Sessions.live?(ssh_sessions)

  defp idle?(_data), do: false

  defp apply_session_recovery(data, reconciliation) do
    data
    |> forget_unless_continuing(reconciliation)
    |> do_apply_session_recovery(reconciliation)
  end

  # A settlement, retry, or failure leaves the durable outcome of the last
  # write uncertain or behind a plain store write; the next entry reads.
  defp forget_unless_continuing(data, %Recovery{action: :continue}), do: data
  defp forget_unless_continuing(data, _reconciliation), do: forget(data)

  defp do_apply_session_recovery(data, %Recovery{action: :retry, checkpoint: checkpoint}),
    do: schedule_session_retry(data, checkpoint)

  defp do_apply_session_recovery(data, %Recovery{action: :settled}) do
    :ok = SalixAgent.ActivityEvent.idle(data.agent_id, data.session_id)
    notify_session_updated(data)

    data |> reset_session_retry() |> request_process()
  end

  defp do_apply_session_recovery(data, %Recovery{action: :continue, checkpoint: checkpoint})
       when not is_nil(checkpoint) do
    cancel_session_retry_timer(data) |> Map.put(:session_recovery, checkpoint)
  end

  defp do_apply_session_recovery(data, %Recovery{}),
    do: reset_session_retry(data)

  defp schedule_session_retry(
         %{session_retry_timer: {_token, _ref}, session_recovery: checkpoint} = data,
         checkpoint
       ),
       do: data

  defp schedule_session_retry(data, checkpoint) do
    data =
      if data.session_recovery in [nil, checkpoint],
        do: cancel_session_retry_timer(data),
        else: reset_session_retry(data)

    attempt = min(data.session_retry_attempt + 1, 32)
    exponent = min(attempt - 1, 16)
    delay_ms = min(@session_retry_max_ms, @session_retry_base_ms * Integer.pow(2, exponent))
    token = make_ref()
    timer_ref = Process.send_after(self(), {:session_retry, token}, delay_ms)

    %{
      data
      | session_retry_timer: {token, timer_ref},
        session_retry_attempt: attempt,
        session_recovery: checkpoint
    }
  end

  defp reset_session_retry(data) do
    data = cancel_session_retry_timer(data)
    %{data | session_retry_attempt: 0, session_recovery: nil}
  end

  defp cancel_session_retry_timer(data) do
    case data.session_retry_timer do
      {_token, timer_ref} -> Process.cancel_timer(timer_ref)
      nil -> :ok
    end

    %{
      data
      | session_retry_timer: nil
    }
  end

  # A fired wait timer: the kernel's loop delivers the timeout, or re-arms the
  # wait while its delegate is still busy without waking the model. The
  # effects need only the session's identity.
  defp commit_inbound_wait_timeout(agent_id, session_id, entry) do
    payload = inbound_payload(entry)
    wait_id = payload[:wait_id] || payload["wait_id"]
    event = {:wait_timeout, wait_id, inbound_source_message_id(entry), loop_facts()}
    data = %__MODULE__{agent_id: agent_id, session_id: session_id}

    case InternalSessionStore.read_revision(agent_id, session_id) do
      {:ok, revision} ->
        data
        |> driven(revision, :wait_timeout, %{result: {:ok, :ignored}})
        |> run({:loop, nil, event})
        |> wait_timeout_result(agent_id, session_id)
        |> log_wait_timeout_failure(agent_id, session_id)

      {:error, :not_found} ->
        {:ok, :ignored}

      {:error, _} = err ->
        err
    end
  end

  defp wait_timeout_result({{:loop_end, {:stop, :committed}}, %{result: {:ok, _}}, _}, a, s),
    do: notify_control_result({:ok, :committed}, a, s)

  defp wait_timeout_result({{:loop_end, {:stop, _}}, ctx, _driver}, _a, _s), do: ctx.result

  defp wait_timeout_result({{:round_failure, reason}, _ctx, _driver}, _a, _s),
    do: {:error, reason}

  defp log_wait_timeout_failure({:error, reason} = err, agent_id, session_id) do
    Logger.warning(
      "internal session #{agent_id}/#{session_id} wait timeout failed: #{inspect(reason)}"
    )

    err
  end

  defp log_wait_timeout_failure(result, _agent_id, _session_id), do: result

  defp commit_control_delivery(agent_id, session_id, entry) do
    payload = inbound_payload(entry)

    case payload[:kind] || payload["kind"] do
      "session_create" ->
        with {:ok, _session} <-
               InternalSessionStore.ensure(agent_id, session_id, session_created_attrs(payload)) do
          {:ok, :committed}
        end

      "session_update" ->
        update =
          %{
            "type" => "session_update",
            "session_id" => session_id,
            "name" => payload[:name] || payload["name"],
            "hidden" => payload[:hidden] || payload["hidden"],
            # Auto-title deliveries (SalixAgent.Titles) set if_unnamed so a
            # concurrent user rename wins at apply time.
            "if_unnamed" => payload[:if_unnamed] || payload["if_unnamed"],
            "updated_at" => payload[:updated_at] || payload["updated_at"]
          }

        with {:ok, _session} <- InternalSessionStore.commit(agent_id, session_id, [update]) do
          {:ok, :committed}
        end

      "session_fork" ->
        case fork_internal_session(
               agent_id,
               payload[:source_session_id] || payload["source_session_id"],
               session_id,
               %{
                 "message_id" => payload[:message_id] || payload["message_id"],
                 "name" => payload[:name] || payload["name"],
                 "created_at" => payload[:created_at] || payload["created_at"]
               }
             ) do
          {:ok, _session} -> {:ok, :committed}
          {:error, :exists} -> {:ok, :committed}
          {:error, _} = err -> err
        end

      "session_compact" ->
        stage_session_compact_control(entry)

      "session_microcompact" ->
        commit_session_microcompact_control(agent_id, session_id)

      "session_emergency_compact" ->
        commit_session_emergency_compact_control(agent_id, session_id)

      "session_log" ->
        commit_session_log_control(agent_id, session_id, entry, payload)

      kind ->
        {:error, {:unsupported_internal_session_control, kind}}
    end
  end

  defp commit_session_log_control(agent_id, session_id, entry, _payload) do
    with {:ok, revision} <- InternalSessionStore.read_or_new_revision(agent_id, session_id) do
      {result, _revision, _checkpoint} =
        InternalSession.Command.run(agent_id, session_id, revision, :log, entry)

      result
    end
  end

  defp stage_session_compact_control(entry) do
    case inbound_source_message_id(entry) do
      source when is_binary(source) and source != "" ->
        send(self(), {:run_session_compact, entry})
        {:ok, :committed}

      _ ->
        {:error, :missing_session_compact_source_message_id}
    end
  end

  defp commit_session_microcompact_control(agent_id, session_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      # The predicate is role-gated and message ids advance monotonically,
      # so the persisted id HWM expresses "every current tool message"
      # WITHOUT discovering them — no archive decode inside the session
      # actor, and no partial-cleanup failure mode to certify: the range
      # covers archived and windowed tool messages alike, and the read
      # side masks both tiers.
      through = (InternalSession.next_message_id(session) || 1) - 1

      if through <= 0 do
        {:ok, :committed}
      else
        event = %{
          "type" => "session_microcompact",
          "session_id" => session_id,
          "tool_messages_through" => through,
          "new_content" => "[microcompacted]"
        }

        with {:ok, _session} <- InternalSessionStore.commit(agent_id, session_id, [event]) do
          {:ok, :committed}
        end
      end
    end
  end

  defp commit_session_emergency_compact_control(agent_id, session_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      # The role/size predicate is applied read-side to both archive and window
      # records. Persisting one id HWM is O(1) and avoids an unbounded archive
      # scan on the actor/control path.
      through = max((InternalSession.next_message_id(session) || 1) - 1, 0)
      event = SalixAgent.EmergencyCompact.event(session_id, through)

      with {:ok, _session} <- InternalSessionStore.commit(agent_id, session_id, [event]) do
        {:ok, :committed}
      end
    end
  end

  defp commit_session_compact_hard_failure(data, entry, reason) do
    case inbound_source_message_id(entry) do
      source when is_binary(source) and source != "" ->
        case Compaction.commit_compact_hard_failure_result(
               data.agent_id,
               data.session_id,
               source,
               reason
             ) do
          {:ok, _result} ->
            notify_session_updated(data)
            :ok

          {:error, commit_reason} ->
            Logger.warning(
              "internal session #{data.agent_id}/#{data.session_id} failed to persist compact hard failure result: #{inspect(commit_reason)}"
            )

            {:error, commit_reason}
        end

      _ ->
        {:error, :missing_session_compact_source_message_id}
    end
  end

  defp fork_internal_session(agent_id, source_session_id, target_session_id, attrs)
       when is_binary(source_session_id) and is_binary(target_session_id) and is_map(attrs) do
    with {:ok, source_session} <- InternalSessionStore.read(agent_id, source_session_id) do
      seed_internal_session(agent_id, source_session, target_session_id, attrs)
    end
  end

  defp fork_internal_session(_agent_id, _source_session_id, _target_session_id, _attrs),
    do: {:error, :bad_session_fork}

  defp seed_internal_session(agent_id, source_session, target_session_id, attrs) do
    with {:ok, attrs} <- resolve_fork_inline_results(agent_id, source_session, attrs),
         {:ok, target} <-
           InternalSession.fork(source_session, target_session_id, attrs),
         :ok <- InternalSessionStore.seed(agent_id, target) do
      InternalSessionStore.read(agent_id, target_session_id)
    end
  end

  # Live-referenced results already archived at the source need a chunk read
  # before the pure fork copy can carry them (the covered-but-unarchived
  # remainder resolves inside fork_from itself).
  defp resolve_fork_inline_results(agent_id, source_session, attrs) do
    source_session
    |> InternalSession.fork_inline_result_seqs(attrs)
    |> Enum.reduce_while({:ok, []}, fn seq, {:ok, acc} ->
      case InternalSessionStore.fetch_archived_record(
             agent_id,
             InternalSession.session_id(source_session),
             source_session,
             seq
           ) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, {:fork_inline_resolve_failed, seq, reason}}}
      end
    end)
    |> case do
      {:ok, inline} -> {:ok, Map.put(attrs, :inline_results, inline)}
      {:error, _} = err -> err
    end
  end

  # The count before the seed is taken here, in the owner, after any
  # activation this actor is fencing: a caller-side read could observe the
  # session before that fence and report the activation's own messages as
  # appended by the seed.
  defp commit_transcript_seed(agent_id, session_id, event) do
    with {:ok, before} <- InternalSessionStore.ensure(agent_id, session_id, %{}),
         {:ok, session} <- InternalSessionStore.commit(agent_id, session_id, [stringify(event)]) do
      {:ok, session, InternalSession.total_message_count(before)}
    end
  end

  defp notify_control_result({:ok, :committed} = result, agent_id, session_id) do
    SalixAgent.Notifier.notify(agent_id, {:session_updated, session_id})
    SessionActivity.notify(agent_id, session_id)
    result
  end

  defp notify_control_result(result, _agent_id, _session_id), do: result

  defp notify_session_result({:ok, _session, _before_count} = result, agent_id, session_id) do
    SalixAgent.Notifier.notify(agent_id, {:session_updated, session_id})
    SessionActivity.notify(agent_id, session_id)
    result
  end

  defp notify_session_result({:ok, _session} = result, agent_id, session_id) do
    SalixAgent.Notifier.notify(agent_id, {:session_updated, session_id})
    SessionActivity.notify(agent_id, session_id)
    result
  end

  defp notify_session_result(result, _agent_id, _session_id), do: result

  # The owner admits and commits a delivery against its resident revision and
  # retains the native revision that the commit returns, including first creation.
  defp admit_conversation(data, entry) do
    if process_blocked?(data) do
      {{:error, :source_busy}, data}
    else
      case owned_revision(data) do
        {:ok, revision, data} ->
          stage_conversation(data, entry, revision)

        {:error, :not_found} ->
          case read_revision_or_new(data.agent_id, data.session_id, inbound_payload(entry)) do
            {:ok, revision} -> stage_conversation(data, entry, revision)
            error -> {error, forget(data)}
          end

        error ->
          {error, forget(data)}
      end
    end
  end

  defp stage_conversation(data, entry, revision) do
    case InternalSession.Command.run(
           data.agent_id,
           data.session_id,
           revision,
           :stage_conversation,
           {entry, is_nil(revision.etag)}
         ) do
      {{:ok, :staged, events}, staged, _} ->
        data = retain(data, staged)
        data = %{data | activation_started_ms: SalixAgent.PhaseTelemetry.now_ms()}

        # The kernel activates the admitted conversation on the fast path; an
        # activation that needs the full path runs on the next processing
        # entry.
        case span(:salix_session_activation, fn ->
               data |> driven(staged, :admission) |> run(:activate_fast)
             end) do
          {{:activation_error, reason}, ctx, _driver} ->
            {{:error, reason}, forget(ctx.data)}

          step ->
            finish_conversation_admission(conclude(step), events)
        end

      {result, _revision, _} ->
        {result, data}
    end
  end

  defp finish_conversation_admission(data, events) do
    # Even an idle or deferred activation must durably admit the source.
    # No source acknowledgment can escape with a working-only revision.
    with {:ok, revision, data} <- owned_revision(data),
         {:ok, committed} <-
           InternalSessionStore.durable_fence(data.agent_id, data.session_id, revision) do
      SalixAgent.RouterRequestMonitor.enqueued(data.agent_id, data.session_id, events)

      if is_map(data.pending_llm) do
        SalixAgent.RouterRequestMonitor.started(
          data.agent_id,
          data.session_id,
          InternalSession.current_source_ids(committed.state)
        )
      end

      {{:ok, :activated}, retain(data, committed) |> request_process()}
    else
      error -> {error, forget(data)}
    end
  end

  defp commit_inbound_delivery(%__MODULE__{} = data, entry) do
    payload = inbound_payload(entry)

    case owned_revision(data) do
      {:ok, revision, data} ->
        case commit_inbound_delivery(data.agent_id, data.session_id, entry, revision) do
          {:ok, %Revision{} = committed} -> {{:ok, :committed}, retain(data, committed)}
          {:ok, :duplicate} -> {{:ok, :duplicate}, data}
          {:error, :saturated} -> {{:error, :saturated}, data}
          other -> {other, forget(data)}
        end

      {:error, :not_found} ->
        with {:ok, revision} <- read_revision_or_new(data.agent_id, data.session_id, payload),
             {:ok, %Revision{} = committed} <-
               commit_inbound_delivery(data.agent_id, data.session_id, entry, revision) do
          {{:ok, :committed}, retain(data, committed)}
        else
          other -> {other, forget(data)}
        end

      {:error, _} = error ->
        {error, forget(data)}
    end
  end

  defp commit_inbound_delivery(agent_id, session_id, entry) do
    payload = inbound_payload(entry)

    with {:ok, revision} <- read_revision_or_new(agent_id, session_id, payload) do
      case commit_inbound_delivery(agent_id, session_id, entry, revision) do
        {:ok, %Revision{}} -> {:ok, :committed}
        other -> other
      end
    end
  end

  defp commit_inbound_delivery(agent_id, session_id, entry, revision) do
    {result, committed, _checkpoint} =
      InternalSession.Command.run(
        agent_id,
        session_id,
        revision,
        :input,
        {entry, is_nil(revision.etag)}
      )

    case {result, committed} do
      {{:ok, :committed}, %Revision{}} -> {:ok, committed}
      _ -> result
    end
  end

  defp read_revision_or_new(agent_id, session_id, payload) do
    InternalSessionStore.read_or_new_revision(
      agent_id,
      session_id,
      session_created_attrs(payload)
    )
  end

  defp session_created_attrs(payload) do
    InternalSession.initial_attributes(payload)
  end

  defp begin_async_tool_terminal(data, ref, pending, result) do
    SalixStore.ReadScope.run(fn ->
      prefetch_round_refresh(data)
      pickup_started_ms = async_result_completed_ms(pending, result)

      {revision, data} =
        case owned_revision(data) do
          {:ok, revision, data} -> {{:ok, revision}, data}
          {:error, _} = error -> {error, forget(data)}
        end

      if revision_has_terminal?(revision, pending.tool_call_id) do
        cancel_async_visible_reply(data, pending)
        data = delete_pending_async_tool(data, ref)

        if completion_activates?(pending), do: request_process(data), else: data
      else
        retired_pending = retire_dependency_identity(pending)

        # Archive boundary 5, async arm. Emitted on the settlement path (the
        # already-terminal branch above is a duplicate delivery, not a new
        # result), so a session using async tools has the same complete
        # boundary-5 record as one that does not.
        SalixAgent.EventArchive.Emit.async_tool_result(
          data.agent_id,
          retired_pending[:session_id],
          retired_pending,
          result
        )

        # The pickup ends here, after the archive emit, so the commit fact
        # that follows starts where this one stops.
        emit_async_phase(:async_pickup, data, retired_pending, revision, pickup_started_ms)
        stage_async_tool_terminal(data, ref, retired_pending, result, revision)
      end
    end)
  end

  defp stage_async_tool_terminal(data, ref, pending, result, revision) do
    data
    |> delete_pending_async_tool(ref)
    |> retain_async_tool_terminal(ref, pending, result)
    |> commit_async_tool_result(ref, pending, result, revision)
  end

  defp revision_has_terminal?({:ok, %{state: session}}, tool_call_id),
    do: terminal_async_call?(session, tool_call_id)

  defp revision_has_terminal?(_revision, _tool_call_id), do: false

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

  defp commit_async_tool_result(data, ref, pending, result, revision) do
    link =
      SystemsObservability.Trace.link_from(
        pending[:observability_link] || %{},
        %{:"async.kind" => "tool_completion", surface: "salix"}
      )

    SystemsObservability.Trace.with_span(
      :background_job,
      %{:"job.kind" => "tool_completion", component: "salix_agent", surface: "salix"},
      fn -> do_commit_async_tool_result(data, ref, pending, result, 0, revision) end,
      links: [link]
    )
  end

  # A failed commit must NOT drop the pending result — it is the only copy
  # of the terminal outcome, and an ambiguous/indeterminate storage error
  # says nothing about durability. The completion event is idempotent by
  # tool_call_id (a duplicate terminal apply is a no-op), so retrying the
  # commit is always safe; the result is only surrendered after the whole
  # retry budget is spent.
  @async_commit_retry_ms 1_000
  @async_commit_retry_budget 60

  defp do_commit_async_tool_result(data, ref, pending, result, attempts, revision \\ nil) do
    # A stale retry must never race a terminal that already committed: if the
    # call settled while this result was waiting to be retried, re-committing
    # would enqueue a second notification beside the durable terminal.
    case normalize_async_commit_revision(data, pending, revision) do
      {:ok, %{state: session} = revision} ->
        if terminal_async_call?(session, pending.tool_call_id) do
          Logger.info(
            "internal async tool result dropped: the exact call already has a durable terminal"
          )

          data
          |> retain(revision)
          |> delete_pending_async_tool_commit(ref)
          |> release_failed_prefetch()
          |> request_process()
        else
          attempt_async_tool_commit(data, ref, pending, result, attempts, revision)
        end

      {:error, reason} ->
        retry_async_tool_commit(data, ref, pending, result, attempts, :read, reason)
    end
  end

  defp attempt_async_tool_commit(data, ref, pending, result, attempts, revision) do
    commit_started_ms = SalixAgent.PhaseTelemetry.now_ms()

    case SessionToolExecution.prepare_internal_async_commit(
           data.agent_id,
           pending.session_id,
           pending,
           result,
           revision.state
         ) do
      {:ok, events, observed_result, workspace_commit} ->
        {events, continue?, speculate?} =
          SalixVerifiedKernel.AgentLoop.completion_wake(
            completion_owner(pending),
            sibling_completion_owners(data, ref),
            events
          )

        data = invalidate_round_config_after(data, result)

        prerequisite =
          if workspace_commit do
            fn ->
              SalixAgent.WorkspaceEvents.commit_prepared_result(
                data.agent_id,
                pending.session_id,
                workspace_commit
              )
            end
          end

        case commit_async_with_prefetch(data, speculate?, pending, revision, events, prerequisite) do
          {:ok, committed_revision, data} ->
            log_repeated_background_results(data, pending, committed_revision)

            config_started_ms =
              emit_async_phase(:async_commit, data, pending, revision, commit_started_ms)

            emit_async_phase(:async_config, data, pending, revision, config_started_ms)

            SessionToolExecution.emit_async(data.agent_id, pending, observed_result)
            cancel_async_visible_reply(data, pending)
            data = data |> retain(committed_revision) |> delete_pending_async_tool_commit(ref)
            notify_session_updated(data)

            if continue?,
              do: continue_after_async_settlement(data, committed_revision),
              else: data

          {:error, reason, data} ->
            retry_async_tool_commit(data, ref, pending, result, attempts, :commit, reason)
        end

      {:error, reason} ->
        retry_async_tool_commit(data, ref, pending, result, attempts, :staging, reason)
    end
  end

  # Keep the owner in this callback while the snapshot and provider run in
  # parallel. Other mailbox entries cannot write through the in-flight CAS.
  # The provider gate also retains fast responses until persistence settles.
  #
  # Speculation only starts when no sibling settlement is close: no other
  # process-local tool of this actor still running or retained for retry,
  # and nothing queued in the mailbox. Such a completion would land while the
  # provider computes, making the speculative response stale before it can
  # apply. The ordinary settlement path defers its activation the same way,
  # so one activation observes every result that has already arrived.
  #
  # A blocked session (a provider call or compaction in flight, or a session
  # retry timer pending) never speculates: the retry fence decides when the
  # next round may start, and settlement only persists the result.
  defp commit_async_with_prefetch(data, speculate?, pending, revision, events, prerequisite) do
    data = take_scheduled_process(data)

    with false <- process_blocked?(data),
         true <- speculate?,
         {:message_queue_len, 0} <- Process.info(self(), :message_queue_len),
         {:ok, written} <- InternalSessionStore.write_revision(revision, events) do
      prefetch_or_commit(data, pending, revision, written, events, prerequisite)
    else
      _ -> commit_without_prefetch(data, pending, revision, events, prerequisite)
    end
  end

  # The overlapped activation after an async result: the kernel's session
  # driver activates the written result on the fast path, and the result
  # events and the activation commit in one frozen CAS while the round
  # prepares and authorizes the provider. A round that did not start runs
  # again from the durable activation. Any other activation commits the
  # result alone. The answer carries the revision the owner retains.
  defp prefetch_or_commit(data, pending, revision, written, events, prerequisite) do
    fields = %{events: events, prerequisite: prerequisite}
    data = %{data | activation_started_ms: SalixAgent.PhaseTelemetry.now_ms()}

    case data |> driven(written, :prefetch, fields) |> run(:activate_fast) do
      {{:activation_error, reason}, %{gate: gate} = ctx, _driver} when is_reference(gate) ->
        {:error, reason, ctx.data}

      {{ended, _}, ctx, _driver} when ended in [:fast_end, :activation_error] ->
        commit_without_prefetch(ctx.data, pending, revision, events, prerequisite)

      step ->
        data = conclude(step)
        {:ok, data.revision, data}
    end
  end

  # Staging already committed the result's skill events. A snapshot built or
  # refreshed before that commit describes the old catalog, so the next round
  # (speculative or ordinary) rebuilds its configuration after the commit.
  defp invalidate_round_config_after(data, result) do
    if SalixAgent.WorkspaceEvents.runtime_configuration_neutral_result?(result) do
      data
    else
      SalixAgent.RoundConfigPrewarm.discard(data.agent_id)

      %{
        data
        | round_config_cache: SalixAgent.RoundConfigCache.invalidate(data.round_config_cache)
      }
    end
  end

  defp commit_without_prefetch(data, pending, revision, events, prerequisite) do
    case commit_session_revision_with_timers(
           data.agent_id,
           pending.session_id,
           revision,
           events,
           prerequisite
         ) do
      {:ok, committed} -> {:ok, committed, release_failed_prefetch(data)}
      {:error, reason} -> {:error, reason, data}
    end
  end

  # A scheduled wake is a coalesced hint for the work this callback is about
  # to process. Consume at most that one hint; keep real mailbox work ordered.
  defp take_scheduled_process(%{process_scheduled: true} = data) do
    receive do
      :process -> %{data | process_scheduled: false, wake_pending: true}
    after
      0 -> data
    end
  end

  defp take_scheduled_process(data), do: data

  # Facts for the kernel's completion_wake decision: the completion owner of
  # every other process-local call still running, or retained for a commit
  # retry. `ref` excludes the settling result's own retained commit.
  defp sibling_completion_owners(data, ref) do
    Enum.map(data.pending_async_tools, fn {_ref, pending} -> completion_owner(pending) end) ++
      for {commit_ref, commit} <- data.pending_async_tool_commits,
          commit_ref != ref,
          do: completion_owner(commit.pending)
  end

  defp completion_owner(pending) when is_map(pending),
    do: pending[:completion_owner] || pending["completion_owner"]

  defp completion_owner(_pending), do: nil

  # The speculative provider call stayed behind a fence that never opened.
  # Cancel it instead of parking the session behind an obsolete response: the
  # dependency job releases its admission, and a result that already reached
  # the mailbox no longer matches any pending dependency.
  defp release_failed_prefetch(%{pending_llm: %{persistence_gate: gate, pid: pid} = llm} = data) do
    send(pid, {:persistence_fence, gate, false})
    :ok = DependencyJob.cancel(llm.dependency_job)
    %{data | pending_llm: nil}
  end

  defp release_failed_prefetch(data), do: data

  # Phase facts for the background-result settlement path — the stretch
  # between a background tool finishing and the continuation's activation
  # that the Activity tab otherwise shows as unknown: `async_pickup` (the
  # tool's completion instant → the session revision read), `async_commit`
  # (staging the result, the workspace commit, the session CAS) and
  # `async_config` (waiting for the parallel round-config build past the
  # commit). Stamped on the round that started the tool (its trace context)
  # and keyed by the session's current activation, like Round's own facts;
  # the fact's identity also carries the tool call id, because a round that
  # ran several background tools settles each one separately and readers
  # converge facts on their key. Best-effort like every phase fact; returns
  # the end instant so the next phase starts where this one ended.
  defp emit_async_phase(phase, data, pending, revision, started_ms) do
    ended_ms = SalixAgent.PhaseTelemetry.now_ms()

    _ =
      SalixAgent.PhaseTelemetry.emit(
        phase,
        async_phase_meter_ctx(data, pending),
        async_phase_activation_key(revision),
        started_ms,
        ended_ms
      )

    ended_ms
  end

  defp async_phase_meter_ctx(data, pending) do
    trace = pfield(pending, :trace_ctx) || %{}
    billing = pfield(pending, :billing_context) || %{}

    %{
      agent_id: data.agent_id,
      salix_agent_id: data.agent_id,
      session_id: pfield(pending, :session_id) || data.session_id,
      tenant_id: pfield(pending, :tenant_id) || pfield(billing, :tenant_id),
      group_id: pfield(pending, :group_id) || pfield(billing, :group_id),
      round_id: pfield(trace, :round_id),
      trace_id: pfield(trace, :trace_id),
      request_id: pfield(trace, :request_id),
      billing_context: billing,
      actor_type: pfield(pending, :actor_type) || "tool",
      source_scope: pfield(pending, :tool_call_id)
    }
  end

  defp async_phase_activation_key({:ok, revision}), do: async_phase_activation_key(revision)

  defp async_phase_activation_key(%{state: session})
       when InternalSession.is_session(session),
       do: InternalSession.current_activation_key(session)

  defp async_phase_activation_key(_other), do: nil

  # The instant the background tool finished: its recorded start plus the
  # duration it measured. Without both, the pickup starts at the read.
  defp async_result_completed_ms(pending, result) do
    with started when is_integer(started) <- pfield(pending, :started_at),
         duration when is_integer(duration) and duration >= 0 <- pfield(result, :duration_ms) do
      started + duration
    else
      _ -> SalixAgent.PhaseTelemetry.now_ms()
    end
  end

  defp pfield(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp pfield(_other, _key), do: nil

  defp normalize_async_commit_revision(_data, _pending, {:ok, revision}), do: {:ok, revision}

  defp normalize_async_commit_revision(data, pending, nil),
    do: InternalSessionStore.read_revision(data.agent_id, pending.session_id)

  defp normalize_async_commit_revision(_data, _pending, {:error, _} = error), do: error

  # A background tool answered the same way once too often, or its round
  # used up the input's round budget. The owner next handles any eligible
  # runtime failure reply before parking model continuation; the activation
  # planner then idles through the loop's own wakes until fresh input.
  defp log_repeated_background_results(data, pending, %{state: session})
       when InternalSession.is_session(session) do
    cond do
      InternalSession.repeated_tool_results_exhausted?(session) ->
        tool = InternalSession.repeated_tool_result_tool(session)
        streak = InternalSession.consecutive_repeated_tool_results(session)

        Logger.error(
          "internal session #{data.agent_id}/#{pending.session_id} received #{streak} " <>
            "identical background results in a row from #{tool}; ending model continuation"
        )

        CommaLog.log("session_repeated_tool_result_parked", %{
          agent_id: data.agent_id,
          session_id: pending.session_id,
          tool_name: tool,
          consecutive_repeated_tool_results: streak
        })

      InternalSession.input_round_budget_exhausted?(session) ->
        rounds = InternalSession.rounds_since_fresh_input(session)

        Logger.error(
          "internal session #{data.agent_id}/#{pending.session_id} used #{rounds} model " <>
            "rounds on one input without fresh input; ending model continuation"
        )

        CommaLog.log("session_input_round_budget_parked", %{
          agent_id: data.agent_id,
          session_id: pending.session_id,
          rounds_since_fresh_input: rounds,
          input_round_cap: SalixAgent.InternalSession.State.input_round_cap()
        })

      true ->
        :ok
    end

    :ok
  end

  defp log_repeated_background_results(_data, _pending, _revision), do: :ok

  defp retry_async_tool_commit(data, ref, pending, result, attempts, stage, reason) do
    # The durable outcome of the failed step is unknown; the retry reads.
    data = forget(data)

    if SalixVerifiedKernel.AgentLoop.retry_failure(attempts, @async_commit_retry_budget) == :retry do
      Logger.warning(
        "internal async tool result #{stage} failed (attempt #{attempts + 1}); " <>
          "retaining the terminal result for retry: #{inspect(reason)}"
      )

      Process.send_after(
        self(),
        {:retry_async_tool_commit, ref, pending, result, attempts + 1},
        @async_commit_retry_ms
      )

      data
    else
      Logger.error(
        "internal async tool result #{stage} exhausted its retry budget; " <>
          "terminal result lost: #{inspect(reason)}"
      )

      delete_pending_async_tool_commit(data, ref)
    end
  end

  defp continue_after_async_settlement(
         %{
           pending_llm: pending_llm,
           pending_compaction: pending_compaction,
           session_retry_timer: session_retry_timer
         } = data,
         _revision
       )
       when is_map(pending_llm) or is_map(pending_compaction) or
              not is_nil(session_retry_timer),
       do: request_process(data)

  # The overlapped activation left no revision to continue from.
  defp continue_after_async_settlement(data, nil), do: request_process(data)

  defp continue_after_async_settlement(data, committed_revision) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, 0} ->
        data
        |> Map.put(:wake_pending, false)
        |> Map.put(:activation_started_ms, SalixAgent.PhaseTelemetry.now_ms())
        |> process_session(committed_revision)

      _queued_or_unavailable ->
        request_process(data)
    end
  end

  # A completion whose batch sibling is still settling in this actor is
  # queued without a wake: the auto-wait holds until the last sibling settles
  # (its completion wakes and materializes every queued result), the wait
  # deadline fires, or other input arrives. Activating on the first result
  # would only be steered as stale once the sibling lands. This is the
  # batching the pre-dispatch admission fence removed: the tool-result commit
  # that once followed dispatch let concurrent completions reach the mailbox
  # before the first one could activate. The flag is durable, so a stale
  # actor wake cannot bypass it.
  defp commit_session_revision_with_timers(
         agent_id,
         session_id,
         revision,
         events,
         prerequisite
       ) do
    with {:ok, committed_revision} <-
           InternalSessionStore.commit_revision(
             agent_id,
             session_id,
             revision,
             events,
             [hwm: async_completion_hwm(events), on_conflict: :error],
             prerequisite
           ) do
      register_committed_timers(agent_id, events)
      {:ok, committed_revision}
    end
  end

  defp commit_revision_events_with_timers(agent_id, session_id, revision, events) do
    with {:ok, committed} <-
           InternalSessionStore.commit_revision(agent_id, session_id, revision, events,
             hwm: async_completion_hwm(events)
           ) do
      register_committed_timers(agent_id, events)
      {:ok, committed}
    end
  end

  defp commit_session_events_with_timers(agent_id, session_id, events) do
    with {:ok, session} <-
           InternalSessionStore.commit(agent_id, session_id, events,
             hwm: async_completion_hwm(events)
           ) do
      register_committed_timers(agent_id, events)
      {:ok, session}
    end
  end

  defp live_process_tool_call_ids(pending_async_tools, pending_commits)
       when is_map(pending_async_tools) and is_map(pending_commits) do
    commit_pending = Enum.map(Map.values(pending_commits), & &1.pending)

    (Map.values(pending_async_tools) ++ commit_pending)
    |> Enum.map(&(&1[:tool_call_id] || &1["tool_call_id"]))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp live_process_tool_call_ids(_pending_async_tools, _pending_commits), do: []

  defp register_current_wait_timer(data, session) when InternalSession.is_session(session) do
    agent_id = data.agent_id
    session_id = InternalSession.session_id(session)

    case InternalSession.wait(session) do
      %{"source" => "auto_wait"} when map_size(data.pending_async_tools) > 0 ->
        # Round already registered this wait after committing the running tools.
        # Recovery, which has no live process-local jobs, still repairs timers.
        :ok

      %{} = wait ->
        case SalixAgent.Waits.register_timer_for_wait(agent_id, session_id, wait) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "internal session #{agent_id}/#{session_id} wait timer registration failed: #{inspect(reason)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  defp register_committed_timers(agent_id, events) do
    case SalixAgent.Waits.register_timers_from_events(agent_id, events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "internal session timer registration failed after commit: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp async_completion_hwm(events) do
    events
    |> Enum.map(fn event -> event["message_id"] || event[:message_id] || 0 end)
    |> Enum.max(fn -> 0 end)
  end

  defp async_tool_call_progress_event(session_id, tool_call_id, progress) do
    %{
      "type" => "async_tool_call_progress",
      "session_id" => session_id,
      "tool_call_id" => tool_call_id,
      "progress" => progress,
      "updated_at" => System.system_time(:millisecond)
    }
  end

  defp terminal_async_status?(status), do: status in ["completed", "failed", "cancelled"]

  defp terminal_async_call?(session, tool_call_id) do
    case InternalSession.lookup_async_call(session, tool_call_id) do
      {:ok, %{"status" => status}} -> terminal_async_status?(status)
      {:archived, _seq} -> true
      _other -> false
    end
  end

  defp runtime_context(data) do
    context = %{
      agent_id: data.agent_id,
      session_id: data.session_id
    }

    case data.revision do
      %Revision{} = revision -> Map.put(context, :revision, revision)
      nil -> context
    end
  end

  # ---- the owner's resident revision ----
  #
  # This actor is the only writer of its session (the store refuses any other
  # process), so the revision it last read or committed IS the session until
  # its next commit. Processing entries start from it, every commit hands the
  # next one back, and the store is read only when there is none: at actor
  # start, after a path that wrote through the plain store API, or after a
  # failure whose durable outcome is unknown. A foreign write (an ownership
  # transfer) surfaces as a CAS conflict, and the conflict forgets.

  defp owned_revision(%{revision: %Revision{} = revision} = data), do: {:ok, revision, data}

  defp owned_revision(data) do
    case InternalSessionStore.read_revision(data.agent_id, data.session_id) do
      {:ok, revision} -> {:ok, revision, %{data | revision: revision}}
      {:error, _} = error -> error
    end
  end

  defp retain(data, %Revision{} = revision), do: mark_durable(%{data | revision: revision})
  defp retain(data, %{revision: %Revision{} = revision}), do: %{data | revision: revision}
  defp retain(data, _without_revision), do: forget(data)

  defp forget(data), do: %{data | revision: nil}

  # A retained revision came from the internal store; publish that once so
  # a delivery facade can route to this session without a store probe.
  defp mark_durable(%{durable_marked: true} = data), do: data

  defp mark_durable(data) do
    _ =
      Registry.update_value(SalixAgent.Registry, key(data.agent_id, data.session_id), fn
        value when is_map(value) -> Map.put(value, :durable, true)
        _other -> %{durable: true}
      end)

    %{data | durable_marked: true}
  rescue
    ArgumentError -> data
  end

  defp retain_round_result(data, {:ok, context, _outcome}), do: retain(data, context)
  defp retain_round_result(data, _result), do: forget(data)

  defp with_owned_revision(context, %{revision: %Revision{} = revision}),
    do: Map.put(context, :revision, revision)

  defp with_owned_revision(context, _data), do: Map.delete(context, :revision)

  # A duplicate terminal event must stay a no-op wherever the terminal
  # result lives: the legacy in-map entry (format 1), the window result
  # record, the live-reference pointer, or the archive.
  defp completion_target(session, tool_call_id),
    do: InternalSession.query(session, :completion_target, tool_call_id)

  defp retire_repaired_async_tool_owners(data, %Revision{state: session}) do
    ids =
      Enum.map(data.pending_async_tools, fn {_ref, pending} -> pending.tool_call_id end) ++
        Enum.flat_map(data.pending_async_tool_commits, fn
          {_ref, %{pending: pending}} -> [pending[:tool_call_id] || pending["tool_call_id"]]
          {_ref, %{"pending" => pending}} -> [pending[:tool_call_id] || pending["tool_call_id"]]
          _ -> []
        end)

    Enum.reduce(Enum.uniq(ids), data, fn id, acc ->
      case InternalSession.lookup_async_call(session, id) do
        {:ok, %{"status" => status}} when status in ["completed", "failed", "cancelled"] ->
          retire_terminal_async_tool_owners(acc, id)

        {:archived, _} ->
          retire_terminal_async_tool_owners(acc, id)

        _ ->
          acc
      end
    end)
  end

  defp retire_repaired_async_tool_owners(data, _revision), do: data

  defp async_tool_cancelled?(nil, _pending), do: false

  defp async_tool_cancelled?(session, pending) do
    match?(
      {:ok, %{"status" => "cancelled"}},
      InternalSession.lookup_async_call(session, pending.tool_call_id)
    )
  end

  # The session the round just left behind says which pending background
  # calls it cancelled. A caller without that revision reads once, not once
  # per pending call.
  defp stop_cancelled_pending_async_tools(data, context) do
    if map_size(data.pending_async_tools) == 0 do
      data
    else
      session = context_session(context) || read_session_or_nil(data)

      Enum.reduce(data.pending_async_tools, data, fn {ref, pending}, acc ->
        if async_tool_cancelled?(session, pending) do
          Process.demonitor(ref, [:flush])
          stop_pending_task(pending)
          cancel_async_visible_reply(data, pending)
          %{acc | pending_async_tools: Map.delete(acc.pending_async_tools, ref)}
        else
          acc
        end
      end)
    end
  end

  defp context_session(%{revision: %Revision{state: session}}), do: session
  defp context_session(_context), do: nil

  defp read_session_or_nil(data) do
    case InternalSessionStore.read(data.agent_id, data.session_id) do
      {:ok, session} -> session
      _ -> nil
    end
  end

  # Modeled in tla/salix/InternalToolCompletionOwner.tla. A durable callback
  # terminal and revocation of every matching process-local producer are one
  # actor-owned transition. Once this turn returns, queued result, timeout,
  # down, and retained-retry messages are stale even after the hot terminal
  # pointer is later retired by compaction/archive.
  defp retire_terminal_async_tool_owners(data, tool_call_id) do
    pending_async_tools =
      Enum.reduce(data.pending_async_tools, data.pending_async_tools, fn {ref, pending}, acc ->
        if exact_async_tool_owner?(pending, data.session_id, tool_call_id) do
          if is_reference(ref), do: Process.demonitor(ref, [:flush])
          stop_pending_task(pending)
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    pending_async_tool_commits =
      Enum.reduce(
        data.pending_async_tool_commits,
        data.pending_async_tool_commits,
        fn
          {ref, %{pending: pending}}, acc ->
            if exact_async_tool_owner?(pending, data.session_id, tool_call_id),
              do: Map.delete(acc, ref),
              else: acc

          {ref, %{"pending" => pending}}, acc ->
            if exact_async_tool_owner?(pending, data.session_id, tool_call_id),
              do: Map.delete(acc, ref),
              else: acc

          _entry, acc ->
            acc
        end
      )

    %{
      data
      | pending_async_tools: pending_async_tools,
        pending_async_tool_commits: pending_async_tool_commits
    }
  end

  defp exact_async_tool_owner?(pending, session_id, tool_call_id) when is_map(pending) do
    SalixVerifiedKernel.AgentLoop.terminal_owner(
      pending[:session_id] || pending["session_id"],
      pending[:tool_call_id] || pending["tool_call_id"],
      session_id,
      tool_call_id
    )
  end

  defp exact_async_tool_owner?(_pending, _session_id, _tool_call_id), do: false

  defp cancel_async_visible_reply(data, pending) do
    case pending[:visible_reply_scope] || pending["visible_reply_scope"] do
      %{} = scope -> VisibleReply.cancel(data.agent_id, pending.session_id, scope)
      _ -> :ok
    end
  end

  defp stop_pending_task(%{dependency_job: %DependencyJob{} = job}) do
    DependencyJob.cancel(job)
  end

  defp stop_pending_task(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp stop_pending_task(_pending), do: :ok

  defp delete_pending_async_tool(data, ref) do
    %{data | pending_async_tools: Map.delete(data.pending_async_tools, ref)}
  end

  defp delete_pending_async_tool_commit(data, ref) do
    %{
      data
      | pending_async_tool_commits: Map.delete(data.pending_async_tool_commits, ref)
    }
  end

  # A direct Session-tool caller owns progress and terminal observation by
  # polling the exact durable tool_call_id. Starting, completing, cancelling,
  # or handing off that call must not become an unrelated model/repair wake.
  # Round-owned tools retain the normal wake path.
  # The kernel's completion_wake decision for one call with no siblings.
  defp completion_activates?(pending) do
    {_events, activates?, _speculate?} =
      SalixVerifiedKernel.AgentLoop.completion_wake(completion_owner(pending), [], [])

    activates?
  end

  defp notify_session_updated(data) do
    SalixAgent.Notifier.notify(data.agent_id, {:session_updated, data.session_id})
    SessionActivity.notify(data.agent_id, data.session_id)
    :ok
  end

  defp inbound_payload(%{payload: payload}) when is_map(payload), do: payload
  defp inbound_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp inbound_payload(_entry), do: %{}

  defp inbound_source_message_id(%{source_message_id: source}), do: source
  defp inbound_source_message_id(%{"source_message_id" => source}), do: source
  defp inbound_source_message_id(_entry), do: nil

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
