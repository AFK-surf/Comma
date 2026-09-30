defmodule SalixAgent do
  @moduledoc """
  Public façade for agent delivery and low-level runtime commands.

  Runtime session projection for product surfaces goes through
  `SalixAgent.Runtime`. Code that explicitly needs raw internal session state
  should depend on `SalixAgent.InternalSessionStore`.
  """

  alias SalixAgent.{
    AgentActor,
    AgentActor.SessionDelivery,
    Control,
    State
  }

  @doc """
  Deliver a user/runtime message to an agent: stage it directly into the
  owner-routed role actor over RPC (`AgentActor.stage_delivery/3`) and ack
  only after the session-ledger commit is durable. The RPC itself is the
  wake; a deferred wake falls back to the session work projection.
  Idempotent on `source_message_id`.

  This function is the single delivery ingress: every writer (API, dashboard,
  IM bindings, timers, schedules) delivers through it. The staged inbox
  protocol is gone entirely (§3.2 step 4 deleted the write path, §3.4 the
  engine, absorb, and the inbox/queue-marker/recent-touch prefixes). Caller
  divergence is declared here, per option, instead of living in per-caller
  wrappers (the A2 prerequisite in `docs/storage-search.md`):

    * `:source_message_id` — **required** (here or in the payload), and it must
      be the caller's stable source identity. There is no generated default: a
      manufactured random id would turn upstream retries into new messages and
      re-execute side effects. Missing/blank ids are rejected with
      `{:error, {:bad_request, _}}`.
    * `:session_check` — `:required` (default): a router agent must have its
      persisted router session, any other role must carry a valid payload
      `session_id`. `:staging`: skip this pre-check — the stage still resolves
      a router's canonical session and refuses any other session-less payload
      with `{:error, :missing_session_id}`. Timers and schedules declare
      `:staging` — their payloads were validated when armed.
    * `:create` — passed to placement for the wake (default `true`); internal
      periodic writers pass `false` so a wake never creates an agent server.
    * `:no_wake` — commit durably but schedule no round (plan §1.7); carried
      on the staged entry.
    * `:reason`, `:now` — retired staging options: every caller has shed
      them (§3.4); an unknown option arriving anyway is ignored.

  One implementation lives behind this contract. The `:staged` inbox
  protocol and its `:salix_agent, :delivery_mode` switch were deleted in A2
  §3.2 step 4 (`docs/salix/conversation-owner-actor.md`), after both environments
  ran `:rpc` for over a release cycle: direct staging into the owner-routed
  role actor (`AgentActor.stage_delivery/3`) for **every** delivery (plan
  §1.1, widened by #870 and #871). No inbox object, queue marker, or
  recent-touch write is ever made. The session-side dedupe ledger — the
  internal session's `input_dedupe`, or the external session's `state.json`
  ledger — commits atomically with the queue append and replies only after
  the durable commit, so `{:ok, _}` carries the ack guarantee. Session-less
  payloads are resolved at deliver time by the role actor (a router rewrites
  the delivery onto its persisted canonical router session); a role that
  cannot resolve one answers `{:error, :missing_session_id}` synchronously.
  """
  # RPC deliver timeout: longer than one S3 CAS p99, and deliberately longer
  # than the webhook handler's own 2.5s wait budget — the HTTP boundary gives
  # up first and answers 5xx for the platform to retry (plan §1.9).
  @rpc_deliver_timeout_ms 5_000

  # The refusal an archived target answers with. More than one predicate
  # produces the same shape — the front-door
  # `ensure_delivery_allowed/1` below, and `AgentControl.ensure_not_stopped/1`
  # deeper in the stage — so callers classify the VALUE, not the producer:
  # `SalixCluster.Schedules.classify_delivery_result/1` matches it to keep a
  # blocked occurrence armed, and `activation_outcome/1` to keep it out of the
  # error counter. Named here so the refusal and its classification here
  # cannot drift apart.
  @archived_delivery_error {:bad_request, "agent is archived"}

  @spec deliver(String.t(), map(), keyword()) :: {:ok, :created | :duplicate} | {:error, term()}
  def deliver(agent_id, payload, opts \\ []) do
    started = System.monotonic_time()

    # Phase telemetry: the instant the input reached the runtime, carried on
    # the queued item into the transcript so the round it wakes can report
    # how long it waited for activation. Callers that already stamp it win.
    payload = stamp_delivered_at(payload)

    payload =
      if is_map(payload),
        do: Map.put(payload, :input_time, SalixAgent.InputTime.capture(payload)),
        else: payload

    result = deliver_rpc_mode(agent_id, payload, opts)

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "activation",
      delivery_surface(payload, opts),
      activation_outcome(result),
      System.monotonic_time() - started
    )

    result
  end

  defp stamp_delivered_at(payload) when is_map(payload) do
    if is_integer(payload[:delivered_at_ms] || payload["delivered_at_ms"]),
      do: payload,
      else: Map.put(payload, :delivered_at_ms, System.system_time(:millisecond))
  end

  defp stamp_delivered_at(payload), do: payload

  # The A2 boundary (plan §1.1; widened by #870 and #871): the rpc contract
  # — one deadline, ledger dedupe, bounded admission — covers EVERY rpc-mode
  # delivery. Session resolution happens at deliver time inside the stage:
  # the router role actor rewrites the delivery onto its persisted canonical
  # router session before the session commit, so session-less payloads need
  # no staged detour. A session-less delivery to a role that cannot resolve
  # one answers {:error, :missing_session_id} synchronously — the retired
  # staged path accepted it and dead-lettered it at absorb, same loss,
  # silent (see the schedules receiver for the caller-side classification).
  #
  # The deadline wraps the whole chain: read-only classification (source id,
  # control record, validation) and the ledgered stage. A timeout can only
  # ever abandon reads, which wrote nothing, or a ledgered stage, where the
  # same-id retry dedupes (plan §1.8 ambiguity row).
  defp deliver_rpc_mode(agent_id, payload, opts) do
    with_delivery_deadline(opts, fn -> classify_and_stage_rpc(agent_id, payload, opts) end)
  end

  # Read-only until the decision point: classification then the ledgered
  # rpc stage, all inside the caller's deadline.
  defp classify_and_stage_rpc(agent_id, payload, opts, reclassified \\ false) do
    with {:ok, source_id} <- require_source_message_id(payload, opts),
         {:ok, agent} <- Control.get_record(agent_id),
         :ok <- ensure_delivery_allowed(agent),
         :ok <- validate_delivery_session(agent, payload, opts),
         :ok <- require_resolvable_session(agent, payload) do
      runtime_kind = Control.runtime_kind(agent)
      # A delivery that wakes an internal session nobody here holds needs a
      # round configuration next; building it from here overlaps placement,
      # the claim and the stage. A resident session actor keeps its own.
      if runtime_kind != "external" and not Keyword.get(opts, :no_wake, false) and
           not resident_session?(agent_id, payload),
         do: SalixAgent.RoundConfigPrewarm.start(agent_id)

      prefetch_session_birth_probe(agent_id, payload)

      case deliver_via_rpc(agent_id, source_id, payload, opts, runtime_kind) do
        # The runtime flipped between this classification and the stage's
        # own routing read (the internal-only fence refused): re-classify
        # ONCE with the fresh record, inside the same deadline — both
        # stores are ledgered, so the retry stays on the rpc contract
        # instead of detouring through the inbox (#870 round 2: the staged
        # detour acked at inbox durability, the AckImpliesDurable
        # counterexample). A second refusal returns as-is; the caller
        # retries with the same source id.
        {:error, :runtime_changed} when not reclassified ->
          classify_and_stage_rpc(agent_id, payload, opts, true)

        other ->
          other
      end
    end
  end

  defp resident_session?(agent_id, payload) do
    session_id = payload[:session_id] || payload["session_id"]

    is_binary(session_id) and SalixStore.Ids.valid_session_id?(session_id) and
      SalixAgent.InternalSessionActor.resident_durable?(agent_id, session_id)
  end

  # The stage routes a delivery by the session's birth store; that probe is
  # a store round trip the stage otherwise pays after placement and the
  # claim. A session already resident here with a durable revision is known
  # internal; any other target's probe starts now and is joined at the stage.
  defp prefetch_session_birth_probe(agent_id, payload) do
    session_id = payload[:session_id] || payload["session_id"]

    if is_binary(session_id) and SalixStore.Ids.valid_session_id?(session_id) and
         not SalixAgent.InternalSessionActor.resident_durable?(agent_id, session_id) do
      key = SalixStore.Keys.agent_internal_runtime_session(agent_id, session_id)

      SalixStore.ReadScope.prefetch({:probe, key}, fn ->
        SalixAgent.InternalSessionStore.probe_key(key)
      end)
    end

    :ok
  end

  # A session-less payload is only deliverable when the target role can
  # resolve a session at stage time (a router rewrites onto its persisted
  # canonical session). Any other role would refuse at the stage with
  # :missing_session_id — but by then placement has already woken and
  # claimed a cold agent (review finding: the rejection claimed a durable
  # head and started a Server). The facade already holds the control
  # record, so the truthful answer costs zero side effects HERE, before
  # placement. The stage-side require_session_id stays as the backstop.
  defp require_resolvable_session(agent, payload) do
    if blank_session_id?(payload) and agent["role"] != "router",
      do: {:error, :missing_session_id},
      else: :ok
  end

  defp blank_session_id?(payload) when is_map(payload) do
    value = payload[:session_id] || payload["session_id"]
    not is_binary(value) or String.trim(value) == ""
  end

  # One deadline for the whole rpc chain: classification reads plus the
  # ledgered stage on either store, session resolution included — there is
  # NO staged fallback (#871; the staged path itself is gone since §3.2
  # step 4).
  # The abandoned attempt may still commit — {:error, :timeout} is the plan
  # §1.8 ambiguity row and the same-id retry dedupes on the ledger.
  defp with_delivery_deadline(opts, fun) do
    budget = opts[:rpc_timeout] || @rpc_deliver_timeout_ms
    # Classification, placement and the local stage each read the agent's
    # control record; one read scope serves the whole chain, and a caller
    # that already resolved the agent (a provider callback) hands in the
    # reads it has back. A read of its still in flight is not waited for:
    # the deadline below is the whole of this call.
    read_scope = SalixStore.ReadScope.capture() || %{}
    task = Task.async(fn -> SalixStore.ReadScope.run(read_scope, fun) end)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:unavailable, {:exit, reason}}}
      nil -> {:error, :timeout}
    end
  end

  # The deadline lives in with_delivery_deadline/2, wrapping the whole chain.
  defp deliver_via_rpc(agent_id, source_id, payload, opts, runtime_kind) do
    entry =
      %{
        source_message_id: source_id,
        payload: rpc_delivery_body(payload, opts)
      }
      |> tag_runtime_fence(runtime_kind)

    rpc_stage_attempts(agent_id, entry, opts, 2)
  end

  # Runtime authority (owner ruling 2026-08-15, plan clause 2b): runtime is
  # a property of the SESSION, fixed at its birth; the agent record governs
  # only new-session placement and this best-effort ADMISSION fence. The
  # stage resolves the target session to its birth store FIRST (session-
  # grain routing, SessionDelivery.session_birth_runtime/2), so an entry
  # addressed to an existing session never consults the fence or the agent
  # record. The fence guards only new-session placement (two-step, like
  # the owner fence — RpcDeliver.tla StageRouteRead): an internal-
  # classified entry REFUSES (:runtime_changed) when the placement read
  # sees external, and the facade re-classifies once in-deadline.
  # External-classified entries are
  # untagged — both stores are ledgered, so a same-id retry dedupes
  # wherever it lands. A flip that wins the admission race (between the
  # routing read and the session CAS) lands the commit in a truthfully
  # old-runtime session, which then EXECUTES there — specified behavior,
  # not a defect (RpcDeliver_LateFlipResidual.cfg is the race boundary;
  # ExecutionOnSessionRuntime is the invariant that holds).
  defp tag_runtime_fence(entry, "external"), do: entry
  defp tag_runtime_fence(entry, _internal), do: Map.put(entry, :require_runtime, :internal)

  # Stale placement is reject-and-re-resolve, bounded to 2 hops (plan §1.3):
  # the fenced target refuses with :not_owner, a fresh placement resolution
  # finds the current owner, and a second refusal is returned to the caller's
  # own retry machinery.
  defp rpc_stage_attempts(agent_id, entry, opts, attempts_left) do
    case rpc_stage_once(agent_id, entry, opts) do
      {:error, :not_owner} when attempts_left > 1 ->
        # The refusal re-resolves placement; the head it was judged by is
        # no longer this delivery's observation.
        SalixStore.ReadScope.invalidate({:head, agent_id})
        rpc_stage_attempts(agent_id, entry, opts, attempts_left - 1)

      other ->
        other
    end
  end

  defp rpc_stage_once(agent_id, entry, opts) do
    stage_opts = [
      timeout: opts[:rpc_timeout] || @rpc_deliver_timeout_ms,
      create: Keyword.get(opts, :create, true)
    ]

    try do
      case AgentActor.stage_rpc_delivery(agent_id, entry, stage_opts) do
        {:ok, :committed, _targets} -> {:ok, :created}
        {:ok, :duplicate} -> {:ok, :duplicate}
        {:ok, :ignored} -> {:ok, :created}
        {:error, :stage_timeout} -> {:error, :timeout}
        {:error, _reason} = error -> error
      end
    catch
      # :erpc.call raises on timeout/noconnection instead of returning. Both
      # land in the failure matrix's ambiguity row (plan §1.8): the commit may
      # or may not have landed, the caller must retry with the SAME source id,
      # and the actor's dedupe ledger resolves the ambiguity.
      :error, {:erpc, :timeout} -> {:error, :timeout}
      :error, {:erpc, reason} -> {:error, {:unavailable, {:erpc, reason}}}
      :exit, reason -> {:error, {:unavailable, {:exit, reason}}}
    end
  end

  # The staged entry shape (atom :kind / :no_wake keys are what
  # SessionDelivery.stage pattern-matches on); inherited verbatim from the
  # retired staged engine so pre-cutover ledger entries stay shape-identical.
  defp rpc_delivery_body(payload, opts) do
    payload
    |> Map.put(:no_wake, !!opts[:no_wake])
    |> Map.put(:kind, opts[:kind] || payload[:kind] || "user")
  end

  # `system` is the fallback for "nobody set a surface" — it is not a label
  # for internal writers. The timers sweeper, the schedules sweeper and
  # auto-title each pass their own (`Salix.Telemetry` keeps the finite set),
  # so a sweeper-driven volume is one query away instead of a catch-all
  # bucket to trace through (#928).
  defp delivery_surface(payload, opts) do
    billing = payload[:billing_context] || payload["billing_context"] || %{}

    opts[:surface] || payload[:surface] || payload["surface"] || billing[:surface] ||
      billing["surface"] || "system"
  end

  defp ensure_delivery_allowed(agent) do
    if SalixAgent.AgentControl.archived?(agent),
      do: {:error, @archived_delivery_error},
      else: :ok
  end

  @doc """
  Is this `deliver/3` result a refusal that is a property of the TARGET's
  state rather than a delivery failure? The target is archived, or it has no
  control record at all.

  Callers use it to decide whether re-attempting can ever pay off:
  `SalixCluster.Schedules` keeps a blocked occurrence armed because unarchive
  is a live route and the claim outlives the outage, while
  `SalixCluster.Timers` cannot make that promise — its lookback window closes
  first — and settles the marker instead. `activation_outcome/1` uses it to
  keep both out of the delivery error counter.
  """
  @spec target_state_refusal?(term()) :: boolean()
  def target_state_refusal?({:error, @archived_delivery_error}), do: true
  def target_state_refusal?({:error, :not_found}), do: true
  def target_state_refusal?(_result), do: false

  # A refusal that is a property of the TARGET's state — archived, or no
  # control record — is not a delivery failure and must not be counted as one.
  # `SalixCluster.Schedules` deliberately re-attempts the SAME blocked
  # occurrence every sweep until the target is unarchived
  # (`POST /v1/runtime/agents/:id/unarchive`), and a sweeper that finds the
  # occurrence already claimed still delivers it (the `:exists` path), so
  # every pod re-attempts it every sweep. Counting that as "error" turns one
  # archived target into a permanent error floor: a single archived staging
  # agent produced ~5,400 activation errors/day across two pods — 100% of the
  # error volume on that surface — and buried every real signal under it
  # (#928). `rejected` keeps the volume visible without claiming a failure.
  #
  # Everything else stays "error", `{:error, :missing_session_id}` included:
  # the sweeper advances past that one and the occurrence is really lost.
  defp activation_outcome({:ok, _}), do: "ok"

  defp activation_outcome(result),
    do: if(target_state_refusal?(result), do: "rejected", else: "error")

  # The caller's stable source identity is the delivery dedupe key. It is
  # accepted from opts or either payload key shape, never manufactured: the
  # A2 delivery contract forbids a generated default (an upstream retry would
  # become a new message). The value is passed through unchanged so existing
  # callers' dedupe keys stay stable.
  defp require_source_message_id(payload, opts) do
    case opts[:source_message_id] || payload[:source_message_id] ||
           (is_map(payload) && payload["source_message_id"]) do
      id when is_binary(id) ->
        if String.trim(id) == "",
          do: {:error, {:bad_request, "source_message_id is required"}},
          else: {:ok, id}

      _ ->
        {:error, {:bad_request, "source_message_id is required"}}
    end
  end

  defp validate_delivery_session(agent, payload, opts) do
    case Keyword.get(opts, :session_check, :required) do
      :staging -> :ok
      :required -> validate_delivery_session(agent, payload)
    end
  end

  defp validate_delivery_session(%{"role" => "router"} = agent, _payload) do
    case SalixStore.RuntimeIds.persisted_router_session_id(agent) do
      {:ok, _session_id} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_delivery_session(_agent, payload),
    do: SessionDelivery.validate_payload(payload)

  @doc """
  Read the agent root state shell.

  Runtime sessions are not part of this state. Product-facing callers that need
  runtime sessions should use `SalixAgent.Runtime.get_session/2` or
  `SalixAgent.Runtime.list_sessions/2`.
  """
  @spec get_state(String.t(), keyword()) :: {:ok, SalixAgent.State.t()} | {:error, term()}
  def get_state(agent_id, opts \\ []) do
    _opts = opts

    with {:ok, _head} <- SalixStore.Agent.peek(agent_id) do
      {:ok, %State{agent_id: agent_id}}
    end
  end

  @doc """
  Execute a single runtime-requested tool through the agent owner boundary and
  then the owning runtime session actor. Tool results are session events.
  """
  @spec execute_session_tool(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :not_running | :busy | :not_found | term()}
  def execute_session_tool(agent_id, session_id, tool_name, attrs, opts \\ [])
      when is_map(attrs) do
    AgentActor.execute_session_tool(agent_id, session_id, tool_name, attrs, opts)
  end

  @doc """
  Resolve a session-scoped async tool call through the agent owner boundary and
  then the owning runtime session actor. User-interaction surfaces use this when
  the final result arrives outside the original tool process.
  """
  @spec complete_async_tool_call(String.t(), String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_async_tool_call(
        agent_id,
        session_id,
        tool_call_id,
        result,
        meta \\ %{},
        opts \\ []
      )
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(result) and is_map(meta) do
    AgentActor.complete_async_tool_call(agent_id, session_id, tool_call_id, result, meta, opts)
  end

  @doc """
  Update progress for a session-scoped background tool call.

  Progress is best-effort: if the tool call has not been durably parked yet, or
  has already reached a terminal state, the owning session ignores the update.
  """
  @spec update_async_tool_call_progress(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_async_tool_call_progress(agent_id, session_id, tool_call_id, progress, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(progress) do
    AgentActor.update_async_tool_call_progress(agent_id, session_id, tool_call_id, progress, opts)
  end

  @doc """
  Operator break-glass recovery for a wedged internal runtime.

  Intended for IEx. Pass `session_id: "..."` to recover one known stuck session,
  or omit it to recover active, wakeable, or waiting internal sessions.
  """
  @spec force_recover(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def force_recover(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Control.force_recover(agent_id, opts)
  end
end
