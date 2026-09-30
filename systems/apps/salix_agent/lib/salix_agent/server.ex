defmodule SalixAgent.Server do
  @moduledoc """
  The per-agent runtime process. It owns the `SalixStore.Agent`
  commit handle and drives the wake → targeted session wake cycle on the
  validated storage kernel: deliveries commit straight into session ledgers at
  deliver time (A2, rpc-direct-delivery.md), so a wake starts the touched and
  indexed session actors and parks. Per-session runtime work is owned by the
  corresponding session actor.

  ## Lifecycle states

    * `:recovering` — claim (or create) the head, load state by replay, then
      process any pending work.
    * `:serving` — actively processing: wake the deferred and indexed target
      session actors; `:settled` parks.
    * `:parked` — hibernated grace window (≤ `park_ms`); a `wake` returns to
      `:serving`. On grace expiry → passivate, UNLESS local session actors
      still hold in-flight work: then the lease is renewed from the in-memory
      handle and the Server re-parks, so the durable lease spans session
      execution.
    * `:passivating` — release this Server's lease (head CAS clears owner; lease
      index deleted) and stop this process. Role-specific agent and session
      actors have independent supervision and lifecycle rules.

  Any `{:error, :fenced}` from a commit or renew means the lease was stolen;
  the Server aborts the agent's whole local runtime (ownership cell fenced,
  session actors stopped — killing their in-flight LLM/tool jobs) and stops
  (the fencing token is the head ETag, validated per write).

  The park/passivate boundary was modeled with the retired staged protocol's
  archived delivery spec (A2 §3.5). The lease guard before coordinator work
  and the lease-bounded parked timeout are modeled in
  tla/salix/TimedScheduling.tla.
  """
  @behaviour :gen_statem

  require Logger
  alias SalixStore.Agent
  alias CommaLog

  alias SalixAgent.{
    AgentActor,
    SessionWorkIndex
  }

  @park_ms 60_000
  @lease_guard_ms 5_000
  @deferred_wake_retry_ms 1_000
  @deferred_wake_max_ms 30_000
  @deferred_wake_max_attempts 8
  @work_index_page_size 100
  @work_index_pages_per_reconcile 1
  @max_work_index_pages_per_reconcile 10

  defmodule Data do
    @moduledoc false
    defstruct [
      :agent_id,
      :node_id,
      :sm,
      :owned,
      :park_ms,
      :lease_guard_ms,
      :lease_ttl_ms,
      :create,
      :startup_mode,
      :work_index_page_size,
      :work_index_pages_per_reconcile,
      work_index_cursor: nil,
      wake_requested: false,
      deferred_wake_targets: [],
      deferred_wake_attempts: 0,
      reconciled_wakes: false
    ]
  end

  # ---- API ----

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:agent_id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    :gen_statem.start_link(via(agent_id), __MODULE__, opts, [])
  end

  @doc "Nudge the agent to process pending work (a delivery arrived)."
  def wake(agent_id) when is_binary(agent_id) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] -> :gen_statem.cast(pid, :wake)
      [] -> {:error, :not_running}
    end
  end

  def wake(pid) when is_pid(pid), do: :gen_statem.cast(pid, :wake)

  @doc false
  def wake_confirm(pid, timeout \\ 5_000) when is_pid(pid) do
    :gen_statem.call(pid, :wake, timeout)
  end

  @doc false
  @spec recover_session_work(pid(), [SalixAgent.AgentActor.wake_target()], timeout()) ::
          :ok | {:error, term()}
  def recover_session_work(pid, targets, timeout \\ 5_000)
      when is_pid(pid) and is_list(targets) do
    :gen_statem.call(pid, {:recover_session_work, targets}, timeout)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Current lifecycle state + a snapshot of the owned head (tests/introspection).
  By agent id this is passivation-tolerant: a parked agent is respawned
  (create: false) and a server stopping mid-call is retried once — callers
  polling around park/passivate boundaries get an answer, not a crash.

  `timeout` bounds the call: the statem runs the wake→target-session-wake
  cycle inline. Actual LLM/runtime work happens in session actors, so readers
  that can serve committed state pass a finite timeout and fall back to the
  durable S3 read on `:exit`; control flows that NEED the live lease handle
  keep the default `:infinity`.
  """
  def info(pid_or_agent_id, timeout \\ :infinity)

  def info(pid, timeout) when is_pid(pid), do: call(pid, :info, timeout)

  def info(agent_id, timeout) when is_binary(agent_id), do: info_retry(agent_id, 2, timeout)

  defp info_retry(agent_id, attempts, timeout) do
    case SalixAgent.Fleet.ensure_started(agent_id, create: false) do
      {:ok, pid} ->
        try do
          call(pid, :info, timeout)
        catch
          :exit, _ when attempts > 1 ->
            Process.sleep(50)
            info_retry(agent_id, attempts - 1, timeout)
        end

      {:error, reason} ->
        raise "no running server for #{agent_id}: #{inspect(reason)}"
    end
  end

  def stop(agent_or_pid), do: :gen_statem.stop(pid_of(agent_or_pid))

  @doc """
  Generation-conditional stop, the only way a superseded-runtime abort may
  take this Server down. The decision is evaluated BY the Server process,
  so it linearizes in the Server's own mailbox against its in-flight
  claim: a stop requested while the claim PUT is in the air is processed
  only after the claim completes, and a claim that landed at an epoch
  above `bound` refuses the stop (`{:refused, epoch}`) — the runtime
  belongs to the newer claim. A Server holding no claim above the bound
  stops normally and replies `:stopping`. Callers must treat a timeout as
  "leave it alone", never as license to kill out-of-band: the durable
  fence and the fenced ownership cell already contain a superseded Server
  until its next boundary aborts it.
  """
  @spec stop_if_at_or_below(String.t(), non_neg_integer() | nil, timeout()) ::
          :ok | {:refused, non_neg_integer()} | {:error, :timeout}
  def stop_if_at_or_below(agent_id, bound, timeout \\ 5_000) when is_binary(agent_id) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [] ->
        :ok

      [{pid, _}] ->
        try do
          case :gen_statem.call(pid, {:stop_if_at_or_below, bound}, timeout) do
            :stopping -> :ok
            {:refused, epoch} -> {:refused, epoch}
          end
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          # Already stopping/stopped — the goal state.
          :exit, _ -> :ok
        end
    end
  end

  defp call(agent_or_pid, msg, timeout),
    do: :gen_statem.call(pid_of(agent_or_pid), msg, timeout)

  defp pid_of(pid) when is_pid(pid), do: pid

  defp pid_of(agent_id) when is_binary(agent_id) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] -> pid
      [] -> raise "no running server for #{agent_id}"
    end
  end

  defp via(agent_id), do: {:via, Registry, {SalixAgent.Registry, agent_id}}

  # ---- gen_statem ----

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(opts) do
    data = %Data{
      agent_id: Keyword.fetch!(opts, :agent_id),
      node_id: Keyword.get(opts, :node_id, default_node()),
      sm: Keyword.get(opts, :sm, SalixAgent.State),
      park_ms: Keyword.get(opts, :park_ms, @park_ms),
      lease_guard_ms: Keyword.get(opts, :lease_guard_ms, @lease_guard_ms),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms),
      create: Keyword.get(opts, :create, false),
      startup_mode: Keyword.get(opts, :startup_mode, :active),
      work_index_page_size: Keyword.get(opts, :work_index_page_size, @work_index_page_size),
      work_index_pages_per_reconcile:
        opts
        |> Keyword.get(:work_index_pages_per_reconcile, @work_index_pages_per_reconcile)
        |> max(1)
        |> min(@max_work_index_pages_per_reconcile)
    }

    {:ok, :recovering, data, [{:next_event, :internal, :claim}]}
  end

  # ---- :recovering ----

  def recovering(:internal, :claim, data) do
    case claim(data) do
      {:ok, owned} ->
        CommaLog.log("server_claimed", %{
          agent_id: data.agent_id,
          node_id: data.node_id,
          epoch: owned.epoch
        })

        :ok = SalixAgent.OwnershipCell.install(data.agent_id, owned.epoch)
        nudge_superseded_owner(data, owned)
        # Background Loops follow the lease: the node that holds the root
        # head runs the Agent's Loops (docs/salix/tasks-background-execution.md).
        SalixAgent.Loops.Reconciler.adopt(data.agent_id)

        data = %{data | owned: owned}

        if data.startup_mode == :passive and not data.wake_requested do
          park_passive_claim(data)
        else
          {:next_state, :serving, %{data | startup_mode: :active},
           [{:next_event, :internal, :process}]}
        end

      {:error, reason} ->
        Logger.warning("salix agent #{data.agent_id} could not claim: #{inspect(reason)}")
        CommaLog.log("server_claim_failed", %{agent_id: data.agent_id, reason: reason})
        log_stale_local_session_work(data, reason)
        # Losing the claim is an expected terminal condition (another node owns
        # the lease), exactly like being fenced mid-cycle. Stop with a
        # `:shutdown`-class reason so the `:transient` child is NOT restarted:
        # an abnormal `{:claim_failed, _}` exit makes the supervisor restart the
        # server into a claim crash-loop that can exhaust `FleetSup`'s restart
        # intensity and take sibling agent actors down with it. Callers that
        # want a retry already unwrap `{:shutdown, _}` (see
        # `SalixAgent.retryable_start_error?/1`).
        {:stop, {:shutdown, {:claim_failed, reason}}}
    end
  end

  def recovering(:cast, :wake, data) do
    {:keep_state, %{data | wake_requested: true}}
  end

  def recovering({:call, from}, :wake, data) do
    {:keep_state, %{data | wake_requested: true}, [{:reply, from, :ok}]}
  end

  def recovering({:call, from}, {:recover_session_work, targets}, data) do
    data = merge_recovery_targets(data, targets)
    {:keep_state, %{data | wake_requested: true}, [{:reply, from, :ok}]}
  end

  def recovering(_event_type, _msg, _data) do
    # Hold casts/calls (e.g. a wake) that arrive before we finish recovering.
    {:keep_state_and_data, [{:postpone, true}]}
  end

  # ---- :serving ----

  def serving(:internal, :process, data), do: run_cycle(data)

  def serving(:state_timeout, :retry_deferred_wake, data) do
    CommaLog.log("server_retry_deferred_wake", %{agent_id: data.agent_id})
    run_cycle(data)
  end

  def serving(:cast, :wake, data) do
    CommaLog.log("server_wake", %{agent_id: data.agent_id, state: "serving"})
    run_cycle(%{data | reconciled_wakes: false})
  end

  def serving({:call, from}, :wake, data) do
    CommaLog.log("server_wake", %{agent_id: data.agent_id, state: "serving"})

    {:keep_state, %{data | reconciled_wakes: false},
     [{:reply, from, :ok}, {:next_event, :internal, :process}]}
  end

  def serving({:call, from}, {:recover_session_work, targets}, data) do
    data = merge_recovery_targets(data, targets)
    {:keep_state, data, [{:reply, from, :ok}, {:next_event, :internal, :process}]}
  end

  def serving({:call, from}, :info, data),
    do: {:keep_state_and_data, [{:reply, from, {:serving, data.owned}}]}

  def serving({:call, from}, {:stop_if_at_or_below, bound}, data),
    do: handle_conditional_stop(from, bound, data)

  def serving(_t, _m, _d), do: :keep_state_and_data

  # ---- :parked ----

  def parked(:cast, :wake, data) do
    CommaLog.log("server_wake", %{agent_id: data.agent_id, state: "parked"})

    {:next_state, :serving, %{data | reconciled_wakes: false},
     [{:next_event, :internal, :process}]}
  end

  def parked({:call, from}, :wake, data) do
    CommaLog.log("server_wake", %{agent_id: data.agent_id, state: "parked"})

    {:next_state, :serving, %{data | reconciled_wakes: false},
     [{:reply, from, :ok}, {:next_event, :internal, :process}]}
  end

  def parked({:call, from}, {:recover_session_work, targets}, data) do
    data = merge_recovery_targets(data, targets)
    {:next_state, :serving, data, [{:reply, from, :ok}, {:next_event, :internal, :process}]}
  end

  def parked(:state_timeout, :passivate, data) do
    if SalixAgent.Fleet.session_work_busy?(data.agent_id) or
         SalixAgent.Loops.retains_owner?(data.agent_id) do
      # Session actors are still executing under this node's ownership, or
      # the Agent has active background Loops that run only while this
      # lease is held: the grace expiry renews instead of releasing, so the
      # durable lease keeps naming this node for as long as the work
      # actually runs.
      renew_and_park(data)
    else
      CommaLog.log("server_passivating", %{agent_id: data.agent_id, park_ms: data.park_ms})
      {:next_state, :passivating, data, [{:next_event, :internal, :release}]}
    end
  end

  def parked({:call, from}, :info, data),
    do: {:keep_state_and_data, [{:reply, from, {:parked, data.owned}}]}

  def parked({:call, from}, {:stop_if_at_or_below, bound}, data),
    do: handle_conditional_stop(from, bound, data)

  def parked(_t, _m, _d), do: :keep_state_and_data

  # ---- :passivating ----

  def passivating(:internal, :release, data) do
    SalixAgent.Loops.Reconciler.release(data.agent_id)
    _ = Agent.release(data.owned)
    # Bounded cell lifecycle: a cleanly released claim drops its ownership
    # entry (guarded — a newer claim or a fence recorded meanwhile is
    # preserved). Lingering session actors keep their own frozen epochs, so
    # they never needed this entry to stamp safely.
    _ = SalixAgent.OwnershipCell.release(data.agent_id, data.owned.epoch)
    CommaLog.log("server_passivated", %{agent_id: data.agent_id})
    {:stop, :normal}
  end

  def passivating({:call, from}, :info, data),
    do: {:keep_state_and_data, [{:reply, from, {:passivating, data.owned}}]}

  def passivating({:call, from}, :wake, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :passivating}}]}

  def passivating({:call, from}, {:recover_session_work, _targets}, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :passivating}}]}

  def passivating({:call, from}, {:stop_if_at_or_below, bound}, data),
    do: handle_conditional_stop(from, bound, data)

  def passivating(_t, _m, _d), do: :keep_state_and_data

  # The conditional-stop decision runs inside the Server's own event loop:
  # by the time it is evaluated the claim has fully resolved (a mid-claim
  # request is postponed in :recovering / queued behind the claim's internal
  # event), so comparing the held epoch against the bound is race-free.
  defp handle_conditional_stop(from, bound, %Data{} = data) do
    bound = if is_integer(bound), do: bound, else: 0
    epoch = data.owned && data.owned.epoch

    if is_integer(epoch) and epoch > bound do
      {:keep_state_and_data, [{:reply, from, {:refused, epoch}}]}
    else
      CommaLog.log("server_stopped_superseded", %{
        agent_id: data.agent_id,
        epoch: epoch,
        bound: bound
      })

      {:stop_and_reply, :normal, [{:reply, from, :stopping}]}
    end
  end

  # ---- core cycle ----

  # One cycle reads the agent's control record at several seams (the wake
  # gate, settlement); the read scope serves them from one read.
  defp run_cycle(data), do: SalixStore.ReadScope.run(fn -> do_run_cycle(data) end)

  defp do_run_cycle(data) do
    CommaLog.log("server_cycle_start", %{agent_id: data.agent_id})

    case verify_work_owner(data) do
      :ok ->
        case wake_deferred_targets(data) do
          {:ok, data} -> reconcile_then_process(data)
          {:deferred, data, reason} -> defer_wake_retry(data, reason)
          {:error, reason} -> {:stop, {:cycle_error, reason}}
        end

      {:error, :lease_expiring} ->
        passivate_expiring_lease(data, "cycle_start")

      {:error, :fenced} ->
        stop_fenced(data)

      {:error, reason} ->
        {:stop, {:cycle_error, reason}}
    end
  end

  # Re-waking indexed non-stable sessions is a recovery action for wakes lost by
  # a prior incarnation. The index is not the source of truth; it only tells the
  # Server which session actors to start so they can re-check their own durable
  # session state. (Deliveries commit into session ledgers at deliver time —
  # A2 §3.4 — so there is no earlier agent-level stage left to cover.)
  defp reconcile_then_process(%Data{reconciled_wakes: true} = data), do: finish_settled(data)

  defp reconcile_then_process(%Data{} = data) do
    reconcile_indexed_then_settle(data)
  end

  defp reconcile_indexed_then_settle(%Data{} = data) do
    case wake_indexed_sessions(data) do
      {:ok, data} ->
        finish_settled(%{data | reconciled_wakes: true})

      {:deferred, data, targets, reason} ->
        data =
          %{data | reconciled_wakes: true}
          |> Map.update!(:deferred_wake_targets, &merge_wake_targets(&1, targets))

        defer_wake_retry(data, reason)

      {:error, reason} ->
        {:stop, {:cycle_error, reason}}
    end
  end

  defp stop_fenced(data) do
    Logger.info("salix agent #{data.agent_id} fenced; terminating")
    CommaLog.log("server_fenced", %{agent_id: data.agent_id, during: "cycle"})
    SalixAgent.Loops.Reconciler.release(data.agent_id)
    # Another node owns the agent now. Stopping this Server is not enough:
    # session actors and their in-flight LLM/tool jobs are the concurrent
    # runners — abort them before this process exits.
    abort_runtime(data, :fenced)
    {:stop, :normal}
  end

  defp finish_settled(%Data{} = data) do
    if data.wake_requested do
      {:keep_state, %{data | wake_requested: false}, [{:next_event, :internal, :process}]}
    else
      CommaLog.log("server_settled", %{
        agent_id: data.agent_id
      })

      # Broadcast a stream hint (best-effort) so SSE subscribers refresh.
      _ = SalixAgent.CloudVM.mark_agent_settled(data.owned.agent_id)
      _ = SalixAgent.Notifier.notify(data.owned.agent_id, {:settled, %{}})
      # Park with a bounded hibernation grace; expiry passivates fully.
      park_or_passivate(data)
    end
  end

  defp park_passive_claim(%Data{} = data) do
    CommaLog.log("server_passive_claim_settled", %{agent_id: data.agent_id})

    data
    |> Map.put(:startup_mode, :active)
    |> park_or_passivate()
  end

  defp defer_wake_retry(data, reason) do
    attempts = (data.deferred_wake_attempts || 0) + 1

    if attempts >= @deferred_wake_max_attempts do
      escalate_deferred_wake(data, reason)
    else
      delay = min(@deferred_wake_max_ms, @deferred_wake_retry_ms * Integer.pow(2, attempts - 1))

      CommaLog.log("server_wake_deferred", %{
        agent_id: data.agent_id,
        reason: reason,
        attempt: attempts,
        delay_ms: delay,
        target_count: length(data.deferred_wake_targets || [])
      })

      {:keep_state, %{data | deferred_wake_attempts: attempts},
       [{:state_timeout, delay, :retry_deferred_wake}]}
    end
  end

  # Repeated wake failures are not recoverable on this node right now (e.g. a
  # session whose actor cannot start). Stop the fast local retry loop and
  # release. Rediscovery is owned by the session work projection: every failed
  # target still has durable session state and a PG candidate row, and the
  # recovery lanes re-wake it through placement — which claims a fresh owner
  # once this lease is gone. (The queue-marker re-home breadcrumb this path
  # used to write retired with its lane, A2 §3.4.)
  defp escalate_deferred_wake(data, reason) do
    CommaLog.log("server_wake_giveup", %{
      agent_id: data.agent_id,
      reason: reason,
      target_count: length(data.deferred_wake_targets || [])
    })

    # Failure path: release even under busy-looking local work — a wedged
    # actor must not pin its agent to this node, and the session-epoch fence
    # makes a takeover of still-executing work safe (the new owner's first
    # stamp fences it and the abort path stops it).
    {:next_state, :passivating, data, [{:next_event, :internal, :release}]}
  end

  # Post-A2 cycle (§3.4 retired the absorb→settle inbox loop): deliveries
  # commit straight into session ledgers at deliver time, so the Server's
  # remaining job on a wake is to start the touched session actors — the
  # deferred targets carried from commits, plus the indexed non-stable
  # sessions — and then park. The settle handshake (marker delete +
  # fresh-inbox re-check) retired with the protocol it guarded.

  defp wake_deferred_targets(%Data{deferred_wake_targets: []} = data), do: {:ok, data}

  defp wake_deferred_targets(%Data{} = data) do
    case AgentActor.wake_targets_after_commit(data.agent_id, data.deferred_wake_targets) do
      :ok -> {:ok, %{data | deferred_wake_targets: [], deferred_wake_attempts: 0}}
      {:deferred, reason} -> {:deferred, data, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wake_indexed_sessions(%Data{} = data) do
    with {:ok, records, next_cursor} <- list_work_index_pages(data) do
      targets =
        records
        |> Enum.reject(&retire_router_work/1)
        |> Enum.map(&indexed_wake_target/1)
        |> Enum.reject(&is_nil/1)

      data = %{data | work_index_cursor: next_cursor}

      case AgentActor.wake_targets_after_commit(data.agent_id, targets) do
        :ok -> {:ok, data}
        {:deferred, reason} -> {:deferred, data, targets, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Local markers include callback-only work that global discovery does not
  # scan. Retire only the listed generation, and never delete session history.
  defp retire_router_work(record) do
    if SessionWorkIndex.retired_router_session?(record) do
      _ = SessionWorkIndex.delete_stale_record(record)
      true
    else
      false
    end
  end

  defp list_work_index_pages(%Data{} = data) do
    do_list_work_index_pages(
      data.agent_id,
      data.work_index_cursor,
      data.work_index_page_size,
      data.work_index_pages_per_reconcile,
      []
    )
  end

  defp do_list_work_index_pages(agent_id, cursor, page_size, pages_left, pages) do
    opts =
      [max_keys: page_size]
      |> maybe_put_work_index_cursor(cursor)

    case SessionWorkIndex.list_page(agent_id, opts) do
      {:ok, %{records: records, next: next}} ->
        pages = [records | pages]

        if is_nil(next) or pages_left == 1 do
          {:ok, pages |> Enum.reverse() |> List.flatten(), next}
        else
          do_list_work_index_pages(agent_id, next, page_size, pages_left - 1, pages)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_put_work_index_cursor(opts, cursor) when is_binary(cursor) and cursor != "",
    do: Keyword.put(opts, :continuation_token, cursor)

  defp maybe_put_work_index_cursor(opts, _cursor), do: opts

  defp indexed_wake_target(%{
         "runtime_kind" => runtime_kind,
         "session_id" => session_id,
         "reasons" => reasons
       })
       when runtime_kind in ["internal", "external"] do
    runtime = if runtime_kind == "internal", do: :internal, else: :external

    if SessionWorkIndex.immediate_recovery_reasons?(reasons),
      do: %{runtime: runtime, session_id: session_id},
      else: nil
  end

  defp indexed_wake_target(_record), do: nil

  defp merge_wake_targets(left, right) do
    (left || [])
    |> Kernel.++(right || [])
    |> Enum.uniq()
  end

  defp merge_recovery_targets(%Data{} = data, targets) do
    Map.update!(
      data,
      :deferred_wake_targets,
      &merge_wake_targets(&1, targets)
    )
  end

  defp claim(%Data{create: true} = data) do
    case Agent.create(data.agent_id, data.node_id, data.sm, claim_opts(data)) do
      {:ok, owned} -> {:ok, owned}
      {:error, :exists} -> Agent.claim(data.agent_id, data.node_id, data.sm, claim_opts(data))
      other -> other
    end
  end

  defp claim(%Data{} = data) do
    Agent.claim(data.agent_id, data.node_id, data.sm, claim_opts(data))
  end

  # The ownership cell is installed as soon as the fenced head names this
  # node, before the store writes its lease index: session actors waiting to
  # bind their generation start one round trip earlier. The install after
  # `claim/1` returns is the same epoch again.
  defp claim_opts(%Data{lease_ttl_ms: ttl_ms} = data) when is_integer(ttl_ms) and ttl_ms > 0,
    do: [ttl_ms: ttl_ms, on_claimed: install_on_claimed(data)]

  defp claim_opts(%Data{} = data), do: [on_claimed: install_on_claimed(data)]

  defp install_on_claimed(%Data{agent_id: agent_id}) do
    fn owned -> :ok = SalixAgent.OwnershipCell.install(agent_id, owned.epoch) end
  end

  defp lease_guard_opts(%Data{} = data),
    do: [guard_ms: max(data.lease_guard_ms, 0)]

  defp verify_work_owner(%Data{} = data) do
    Agent.verify_work_owner(data.owned, lease_guard_opts(data))
  end

  defp park_or_passivate(%Data{} = data) do
    if SalixAgent.Fleet.session_work_busy?(data.agent_id) do
      renew_and_park(data)
    else
      remaining =
        data.owned.head.lease_until -
          System.system_time(:millisecond) -
          max(data.lease_guard_ms, 0)

      if remaining > 0 do
        timeout = min(data.park_ms, remaining)
        {:next_state, :parked, data, [{:state_timeout, timeout, :passivate}, :hibernate]}
      else
        passivate_expiring_lease(data, "park_boundary")
      end
    end
  end

  # Keep-alive while session work is live: renew from the in-memory handle
  # (one conditional PUT, no GET) and re-park at ~ttl/3 so the lease never
  # goes stale under a healthy runner. Fail-closed: a fenced renew means
  # another node owns the agent — abort the local runtime immediately; a
  # transient store failure retries on a short park while lease time remains
  # and aborts once the guard boundary is reached.
  @renew_retry_ms 5_000

  defp renew_and_park(%Data{} = data) do
    now = System.system_time(:millisecond)
    ttl = data.owned.ttl_ms
    lease_until = data.owned.head.lease_until
    # The PUT budget is one renew per agent per ~ttl/3, not one per settle:
    # a lease with less than ttl/3 elapsed (more than 2*ttl/3 remaining) is
    # still fresh — just park until the renew point. Frequent wakes while a
    # session is busy therefore cost no extra root PUTs.
    renew_due_at = if is_integer(lease_until), do: lease_until - ttl + div(ttl, 3), else: now

    if now < renew_due_at do
      timeout = min(data.park_ms, max(renew_due_at - now, 1_000))
      {:next_state, :parked, data, [{:state_timeout, timeout, :passivate}, :hibernate]}
    else
      do_renew_and_park(data)
    end
  end

  defp do_renew_and_park(%Data{} = data) do
    case Agent.renew(data.owned) do
      {:ok, owned} ->
        data = %{data | owned: owned}
        timeout = min(data.park_ms, max(div(owned.ttl_ms, 3), 1_000))
        {:next_state, :parked, data, [{:state_timeout, timeout, :passivate}, :hibernate]}

      {:error, :fenced} ->
        CommaLog.log("server_fenced", %{agent_id: data.agent_id, during: "renew"})
        abort_runtime(data, :renew_fenced)
        {:stop, :normal}

      {:error, reason} ->
        remaining =
          data.owned.head.lease_until -
            System.system_time(:millisecond) -
            max(data.lease_guard_ms, 0)

        if remaining > @renew_retry_ms do
          CommaLog.log("server_renew_retry", %{agent_id: data.agent_id, reason: reason})

          {:next_state, :parked, data,
           [{:state_timeout, @renew_retry_ms, :passivate}, :hibernate]}
        else
          CommaLog.log("server_renew_failed", %{agent_id: data.agent_id, reason: reason})
          abort_runtime(data, {:renew_failed, reason})
          {:stop, :normal}
        end
    end
  end

  defp abort_runtime(%Data{} = data, reason) do
    epoch = data.owned && data.owned.epoch

    SalixAgent.Fleet.abort_agent_runtime(data.agent_id, epoch, reason, stop_server: false)
  end

  # A claim refused because another holder owns the lease is NOT proof of a
  # takeover: direct `Agent.claim` holders (drain's Owned handoff, migration
  # imports, tests/tooling) legitimately hold the lease while local session
  # work proceeds, and staging lazily starts a Server whose losing claim
  # would otherwise shoot the very actors doing that work. Supersession is
  # only ever acted on through its deterministic signals — a fenced session
  # commit, a fenced renew, or the new owner's nudge — so here we only log.
  defp log_stale_local_session_work(%Data{} = data, {:held_by, holder, _until})
       when is_binary(holder) do
    if holder != data.node_id and SalixAgent.Fleet.session_work_running?(data.agent_id) do
      CommaLog.log("server_claim_lost_with_local_session_work", %{
        agent_id: data.agent_id,
        holder: holder
      })
    end

    :ok
  end

  defp log_stale_local_session_work(_data, _reason), do: :ok

  # Best-effort takeover nudge: when this claim superseded a live remote
  # owner (its lease had expired but the node is still connected), tell that
  # node to abort the agent's runtime now instead of waiting for its next
  # fenced write or renew. Safety never depends on this cast.
  defp nudge_superseded_owner(%Data{} = data, %Agent.Owned{} = owned) do
    prev = owned.prev_owner_node

    if is_binary(prev) and prev != data.node_id do
      case Enum.find(Node.list(), &(to_string(&1) == prev)) do
        nil ->
          :ok

        node ->
          :erpc.cast(node, SalixAgent.Fleet, :abort_agent_runtime, [
            data.agent_id,
            owned.epoch,
            :superseded
          ])
      end
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp passivate_expiring_lease(%Data{} = data, boundary) do
    CommaLog.log("server_lease_guard", %{
      agent_id: data.agent_id,
      boundary: boundary,
      lease_guard_ms: data.lease_guard_ms
    })

    # I3: an expiring lease under live session work is renewed, not
    # surrendered; renew_and_park fail-closes into the abort path if the
    # lease is genuinely lost.
    if SalixAgent.Fleet.session_work_busy?(data.agent_id) do
      renew_and_park(data)
    else
      {:next_state, :passivating, data, [{:next_event, :internal, :release}]}
    end
  end

  defp default_node, do: to_string(node())
end
