defmodule SalixAgent.Fleet do
  require SystemsRuntime.Proc

  @moduledoc """
  Spawn-on-demand for agent Servers. `ensure_started/2` starts a
  `SalixAgent.Server` for an agent if one isn't already running on this node, and
  returns its pid. Idempotent: a concurrent start that loses the Registry race
  returns the existing pid.

  This module owns the node-local start. `SalixCluster.Placement` synchronously
  routes cluster-wide `ensure_started` calls to the ring-owner node before
  invoking it. `config :salix_agent, :start_admission` (a zero-arity function
  returning `:ok` or `{:error, reason}`) lets the cluster layer refuse a new
  Server on a node that is draining; a Server already running here is
  returned regardless.
  """

  alias SalixAgent.{Control, Server}

  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id, opts \\ []), do: ensure_started(agent_id, opts, 5)

  defp ensure_started(agent_id, opts, attempts) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- admit_start(agent_id) do
      opts = Keyword.put(opts, :agent_id, agent_id)

      case start_child(opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} when attempts > 1 -> maybe_retry_start(agent_id, opts, attempts, reason)
        other -> other
      end
    end
  end

  defp start_child(opts) do
    SystemsRuntime.DynamicSupervisor.start_child(SalixAgent.FleetSup, {Server, opts})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp admit_start(agent_id) do
    case SystemsRuntime.get_env(:salix_agent, :start_admission) do
      fun when is_function(fun, 0) -> if server_running?(agent_id), do: :ok, else: fun.()
      _none -> :ok
    end
  end

  defp maybe_retry_start(agent_id, opts, attempts, reason) do
    if retryable_start_error?(reason) do
      SystemsClock.sleep(20)
      ensure_started(agent_id, opts, attempts - 1)
    else
      {:error, reason}
    end
  end

  defp retryable_start_error?({:exit, _reason}), do: true
  defp retryable_start_error?({:shutdown, _reason}), do: true
  defp retryable_start_error?(_reason), do: false

  @doc """
  True while any runtime process for the agent is live on this node — the root
  Server OR a session actor. Session actors are runtime owners that can
  outlive a parked/crashed root Server, so liveness probes (notably
  `SalixCluster.Recovery`) must not re-home an agent whose session work is
  still executing here just because the root Server is momentarily gone.
  """
  @spec running?(String.t()) :: boolean()
  def running?(agent_id) do
    server_running?(agent_id) or session_work_running?(agent_id)
  end

  @doc """
  True while the root Server for the agent is registered on this node — i.e.
  a local claim is held or being taken. Narrower than `running?/1`: a
  lingering session actor without a root Server (the shape a wake-giveup
  release leaves behind) does not count. (The retired queue-sweep recovery
  fast path was this predicate's original consumer, A2 §3.4; `running?/1`
  still composes it.)
  """
  @spec server_running?(String.t()) :: boolean()
  def server_running?(agent_id) when is_binary(agent_id),
    do: SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) != []

  @doc """
  Wait for the registered Server to finish its claim and retire old session
  actors. Its Registry value records startup completion. The ownership cell
  can retain an earlier Server's claim and cannot prove this startup finished.
  No call enters the Server mailbox, which can depend on this actor's startup.
  A call made without a registered Server keeps the existing no-Server path.
  """
  @spec await_ownership_installed(String.t(), non_neg_integer()) :: :ok | {:error, :unavailable}
  def await_ownership_installed(agent_id, timeout_ms \\ 500) when is_binary(agent_id) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) do
      [{root, _value}] ->
        deadline = SystemsClock.monotonic_time(:millisecond) + timeout_ms
        await_ownership_loop(agent_id, root, deadline)

      [] ->
        :ok
    end
  end

  defp await_ownership_loop(agent_id, root, deadline) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) do
      [{^root, :ready}] ->
        :ok

      [{^root, _pending}] ->
        if SystemsClock.monotonic_time(:millisecond) < deadline do
          SystemsClock.sleep(10)
          await_ownership_loop(agent_id, root, deadline)
        else
          {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  @doc """
  Start or reuse a session actor after the registered Server finishes startup.
  This applies to frozen resident actors too. A new claim retires them before
  it admits commands to its replacement actors.

  The actor also binds its generation before it handles queued commands.
  That boundary covers supervisor restarts, which bypass this caller-side path.
  """
  @spec start_session_actor(module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session_actor(module, opts) when is_atom(module) and is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    key = module.key(agent_id, Keyword.fetch!(opts, :session_id))

    with :ok <- await_ownership_installed(agent_id),
         :ok <- session_actor_admission(module, key) do
      case SystemsRuntime.DynamicSupervisor.start_child(SalixAgent.FleetSup, {module, opts}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Existing actors and supervisor-driven recovery are not new admission.
  # Resource pressure must not restart-loop a crashed transient child.
  defp session_actor_admission(module, key) do
    if module == SalixAgent.InternalSessionActor and
         SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) == [],
       do: SalixAgent.SessionResidency.admission(),
       else: :ok
  end

  @doc "True while any session actor for the agent is registered on this node."
  @spec session_work_running?(String.t()) :: boolean()
  def session_work_running?(agent_id) when is_binary(agent_id),
    do: session_actor_keys(agent_id) != []

  @doc """
  True while any local session actor for the agent holds in-flight work
  (pending LLM call, compaction, or async tools). Idle-but-registered actors
  do not count: the root Server's lease keep-alive gates on this, so an agent
  whose sessions merely linger in their idle grace still passivates normally.
  """
  @spec session_work_busy?(String.t()) :: boolean()
  def session_work_busy?(agent_id) when is_binary(agent_id) do
    agent_id
    |> session_actor_keys()
    |> Enum.any?(fn
      {:internal_session, _agent, _session} = key ->
        case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
          [{pid, _}] -> SalixAgent.InternalSessionActor.busy?(pid)
          [] -> false
        end
    end)
  end

  @doc """
  This node's runtime for the agent was superseded (a session commit or root
  commit/renew came back fenced, or the new owner's takeover nudge arrived):
  mark the node-local ownership cell fenced so new LLM/tool dispatches
  refuse immediately, then stop the superseded session actors — which kills
  their in-flight LLM/tool `DependencyJob` tasks through the existing
  owner-death monitor.

  Abort-only-runtime-at-or-below-the-observed-epoch contract: when the cell
  holds a claim NEWER than `observed_epoch` (a delayed nudge about an epoch
  this node already superseded by re-claiming), the current runtime is
  valid and survives — only actors whose frozen epoch is at or below the
  evidence are stopped, and the Server is untouched. `stop_server: false`
  lets the root Server call this from inside its own callback and stop
  itself afterwards.
  """
  @spec abort_agent_runtime(String.t(), non_neg_integer() | nil, term(), keyword()) :: :ok
  def abort_agent_runtime(agent_id, observed_epoch, reason, opts \\ [])
      when is_binary(agent_id) do
    :ok = SalixAgent.OwnershipCell.fence(agent_id, observed_epoch)

    # The kill bound is resolved from the cell AT the kill boundary, not
    # from the branch that was true when the evidence arrived: a claim that
    # lands between the fence attempt and the teardown re-owns the cell at
    # a higher epoch, and its runtime — Server, AgentActor, and any actor
    # frozen above the bound — must survive. Every stop below is therefore
    # epoch-conditional per work item, never a blanket "stop everything".
    case SalixAgent.OwnershipCell.entry(agent_id) do
      {:ok, current, :owned} when is_integer(observed_epoch) and current > observed_epoch ->
        # Stale evidence: this node holds a claim NEWER than the reported
        # takeover (e.g. a delayed nudge about an epoch we already
        # superseded by re-claiming). Only work items frozen at or below
        # the observed epoch are superseded.
        _ = stop_session_actors_at_or_below(agent_id, observed_epoch)

        CommaLog.log("agent_runtime_abort_partial", %{
          agent_id: agent_id,
          observed_epoch: observed_epoch,
          current_epoch: current,
          reason: reason
        })

      entry ->
        # The whole fenced runtime is superseded — up to the fenced epoch
        # (>= observed; the cell keeps the max evidence). Actors frozen
        # ABOVE that bound belong to a claim racing in during this
        # teardown and survive; likewise the Server/AgentActor are only
        # stopped while the cell is still fenced (a re-own downgrades the
        # next abort to partial, and a Server that claims after this look
        # re-installs the cell it finds fenced).
        bound =
          case entry do
            {:ok, fenced_epoch, :fenced} -> fenced_epoch
            _ -> observed_epoch
          end

        _ = stop_session_actors_at_or_below(agent_id, bound)

        # Root Server: the kill decision is evaluated by the Server process
        # itself (`Server.stop_if_at_or_below/3`), so it serializes in the
        # Server's mailbox against its own in-flight claim — a claim PUT
        # that lands after this abort started completes first, and a claim
        # above the bound refuses the stop. The cell pre-check only saves
        # the call when a newer claim is already visibly installed. The
        # role actor is stopped only when the Server is gone or agreed to
        # stop: a refusing Server's runtime (role actor included) is the
        # newer claim's and survives. (Session actors above need no such
        # protocol: their frozen epochs are immutable, so the per-item
        # bound is race-free.)
        server_outcome =
          cond do
            SalixAgent.OwnershipCell.entry(agent_id) |> owned_entry?() ->
              {:refused, :reowned}

            Keyword.get(opts, :stop_server, true) ->
              Server.stop_if_at_or_below(agent_id, bound)

            true ->
              # The Server called this from its own callback and stops
              # itself afterwards; its runtime is the superseded one.
              :caller_stops_itself
          end

        case server_outcome do
          {:refused, _newer} ->
            :ok

          {:error, :timeout} ->
            # The Server is mid-cycle and did not answer. NEVER kill it
            # out-of-band — that reintroduces the check/kill race this
            # protocol closes. The fenced cell already refuses new
            # dispatches and every durable write CAS-fences, so a genuinely
            # superseded Server aborts itself at its next boundary.
            :ok

          _stopped_or_absent ->
            _ = SalixAgent.AgentActor.stop(agent_id)
        end

        # Bounded cell lifecycle: once nothing remains for the fence to
        # gate, drop the residue. A claim that lands meanwhile is preserved
        # (clear_superseded only removes a :fenced entry).
        unless session_work_running?(agent_id) or server_running?(agent_id) do
          :ok = SalixAgent.OwnershipCell.clear_superseded(agent_id)
        end

        CommaLog.log("agent_runtime_aborted", %{
          agent_id: agent_id,
          observed_epoch: observed_epoch,
          bound: bound,
          server_outcome: inspect(server_outcome),
          reason: reason
        })
    end

    :ok
  end

  defp owned_entry?({:ok, _epoch, :owned}), do: true
  defp owned_entry?(_entry), do: false

  @doc false
  def retire_superseded_session_actors(agent_id, claimed_epoch)
      when is_binary(agent_id) and is_integer(claimed_epoch) and claimed_epoch > 0 do
    stop_session_actors_matching(agent_id, fn frozen ->
      is_integer(frozen) and frozen < claimed_epoch
    end)
  end

  # Stop only session actors whose FROZEN epoch (their Registry value,
  # bound at the actor's first ownership resolution) is at or below the
  # superseding bound. An actor with no frozen value yet has done no
  # durable work and is treated as legacy epoch 0 — stopped conservatively
  # (it restarts through the owner-routed path and freezes the live claim).
  # `bound: nil` stops only such unfrozen/legacy actors.
  defp stop_session_actors_at_or_below(agent_id, bound) do
    bound = if is_integer(bound), do: bound, else: 0

    stop_session_actors_matching(agent_id, fn frozen -> (frozen || 0) <= bound end)
  end

  defp stop_session_actors_matching(agent_id, predicate) do
    agent_id
    |> session_actor_keys()
    |> Enum.each(fn key ->
      case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
        [{pid, value}] ->
          frozen =
            case value do
              %{runtime_epoch: epoch} when is_integer(epoch) -> epoch
              _ -> nil
            end

          if predicate.(frozen), do: terminate_child(pid)

        [] ->
          :ok
      end
    end)

    :ok
  end

  @spec stop(term()) :: :ok
  def stop(key) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] -> terminate_child(pid)
      [] -> :ok
    end

    :ok
  end

  @doc false
  @spec stop_existing(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_existing(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    # The coordinator can recreate session owners while completing a queued
    # wake. Fence that producer before taking the session-actor snapshot.
    with :ok <- stop_server(agent_id, opts) do
      stop_session_actors(agent_id)
    end
  end

  @doc false
  @spec stop_server(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_server(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] -> stop_pid(pid, opts)
      [] -> :ok
    end
  end

  @doc false
  @spec stop_pid(pid(), keyword()) :: :ok | {:error, term()}
  def stop_pid(pid, opts \\ []) when SystemsRuntime.Proc.is_process(pid) and is_list(opts) do
    reason = Keyword.get(opts, :reason, :normal)
    timeout = Keyword.get(opts, :timeout, :infinity)

    try do
      SystemsRuntime.StateMachine.stop(pid, reason, timeout)
    catch
      :exit, {:timeout, _} ->
        if Keyword.get(opts, :force, false) do
          SystemsRuntime.Proc.exit(pid, :kill)
          :ok
        else
          {:error, :timeout}
        end

      :exit, _ ->
        :ok
    end
  end

  @doc false
  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) when SystemsRuntime.Proc.is_process(pid) do
    SystemsRuntime.DynamicSupervisor.terminate_child(SalixAgent.FleetSup, pid)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Stop currently running session actors for one agent.

  Agent lifecycle operations own compute lifecycle at the agent boundary. Durable
  session records remain in their runtime stores; this only removes live owner
  processes so cancelled/archived agents do not keep executing session work.
  """
  @spec stop_session_actors(String.t()) :: :ok
  def stop_session_actors(agent_id) when is_binary(agent_id) do
    _ = SalixAgent.AgentActor.stop(agent_id)

    stop_local_session_actors(agent_id)
  end

  @doc false
  @spec stop_local_session_actors(String.t()) :: :ok
  def stop_local_session_actors(agent_id) when is_binary(agent_id) do
    agent_id
    |> session_actor_keys()
    |> Enum.each(&stop/1)

    :ok
  end

  defp session_actor_keys(agent_id) do
    SystemsRuntime.Registry.select(SalixAgent.Registry, [
      {{{:internal_session, agent_id, :"$1"}, :"$2", :"$3"}, [],
       [{{:internal_session, agent_id, :"$1"}}]}
    ])
  end
end
