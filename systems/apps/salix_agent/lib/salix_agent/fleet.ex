defmodule SalixAgent.Fleet do
  @moduledoc """
  Spawn-on-demand for agent Servers. `ensure_started/2` starts a
  `SalixAgent.Server` for an agent if one isn't already running on this node, and
  returns its pid. Idempotent: a concurrent start that loses the Registry race
  returns the existing pid.

  This module owns the node-local start. `SalixCluster.Placement` synchronously
  routes cluster-wide `ensure_started` calls to the ring-owner node before
  invoking it.
  """

  alias SalixAgent.{Control, Server}

  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id, opts \\ []), do: ensure_started(agent_id, opts, 5)

  defp ensure_started(agent_id, opts, attempts) do
    with :ok <- Control.ensure_not_stopped(agent_id) do
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
    DynamicSupervisor.start_child(SalixAgent.FleetSup, {Server, opts})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp maybe_retry_start(agent_id, opts, attempts, reason) do
    if retryable_start_error?(reason) do
      Process.sleep(20)
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
    do: Registry.lookup(SalixAgent.Registry, agent_id) != []

  @doc """
  Best-effort wait for the local Server's claim to reach the ownership cell,
  so a session actor started behind it binds its immutable generation to the
  installed claim instead of racing the claim and being pinned as legacy.
  Pure cell reads — never a call into the Server (which may itself be blocked
  in a call chain that started this actor). Zero-cost once the cell exists;
  bounded when a registered Server is still mid-claim; a Server that fails
  its claim stops and ends the wait. The store's first-resolution pin stays
  the safety net when the wait gives up.
  """
  @spec await_ownership_installed(String.t(), non_neg_integer()) :: :ok
  def await_ownership_installed(agent_id, timeout_ms \\ 500) when is_binary(agent_id) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_ownership_loop(agent_id, deadline)
  end

  defp await_ownership_loop(agent_id, deadline) do
    case SalixAgent.OwnershipCell.fetch(agent_id) do
      :absent ->
        if System.monotonic_time(:millisecond) < deadline and server_running?(agent_id) do
          Process.sleep(10)
          await_ownership_loop(agent_id, deadline)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  THE start boundary for session actors. Every creation path — the
  Internal/External session fleets, the Router owner's canonical start —
  creates its actor through this function, never through a bare
  `DynamicSupervisor.start_child`, so the generation contract holds on all
  of them: a NEW actor binds its immutable generation at init by reading
  the ownership cell, so its start first waits out a registered Server's
  in-flight claim (`await_ownership_installed/2`) — otherwise the actor
  would race the claim and be pinned as legacy epoch 0 forever, fencing
  valid work. Only an actor with an integer FROZEN generation skips the
  wait (the per-command hot path): an actor that is registered but still
  unbound — a replacement restarted while no root Server existed — waits
  like a fresh start, because its generation resolves at its next
  ownership resolution and must see the installed claim, not race it.

  This funnel is the CALLER-side boundary; the binding itself is also the
  actor's own first act (init → `handle_continue`, before any queued
  command), which is what covers the one creation path no call site can:
  a supervisor-driven restart of a crashed `:transient` actor, which
  re-runs the retained child_spec directly.
  """
  @spec start_session_actor(module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session_actor(module, opts) when is_atom(module) and is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    key = module.key(agent_id, Keyword.fetch!(opts, :session_id))

    # Three lifecycle states, not two: absent, registered-but-UNBOUND, and
    # frozen. A replacement restarted while NO root Server existed binds
    # nothing (its continue finds the cell absent and no claim to wait
    # for) and legitimately idles unbound — its generation resolves lazily
    # at its first commit. So "registered" must not be mistaken for
    # "already frozen": a command routed to an unbound actor while a NEW
    # Server's claim is in flight would freeze it at legacy 0 and fence
    # valid work. Only an integer frozen epoch skips the wait (the
    # per-command hot path); absent and unbound both wait out a registered
    # Server's in-flight claim so the eventual binding sees the installed
    # claim.
    needs_await =
      case Registry.lookup(SalixAgent.Registry, key) do
        [{_pid, %{runtime_epoch: frozen}}] when is_integer(frozen) -> false
        _absent_or_unbound -> true
      end

    if needs_await do
      :ok = await_ownership_installed(agent_id)
    end

    # Existing actors and supervisor-driven recovery are not new admission.
    # Resource pressure must not restart-loop a crashed transient child.
    admission =
      if module == SalixAgent.InternalSessionActor and
           Registry.lookup(SalixAgent.Registry, key) == [],
         do: SalixAgent.SessionResidency.admission(),
         else: :ok

    with :ok <- admission do
      case DynamicSupervisor.start_child(SalixAgent.FleetSup, {module, opts}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
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
        case Registry.lookup(SalixAgent.Registry, key) do
          [{pid, _}] -> SalixAgent.InternalSessionActor.busy?(pid)
          [] -> false
        end

      {:external_session, _agent, _session} = key ->
        case Registry.lookup(SalixAgent.Registry, key) do
          [{pid, _}] -> SalixAgent.ExternalSessionActor.busy?(pid)
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

  # Stop only session actors whose FROZEN epoch (their Registry value,
  # bound at the actor's first ownership resolution) is at or below the
  # superseding bound. An actor with no frozen value yet has done no
  # durable work and is treated as legacy epoch 0 — stopped conservatively
  # (it restarts through the owner-routed path and freezes the live claim).
  # `bound: nil` stops only such unfrozen/legacy actors.
  defp stop_session_actors_at_or_below(agent_id, bound) do
    bound = if is_integer(bound), do: bound, else: 0

    agent_id
    |> session_actor_keys()
    |> Enum.each(fn key ->
      frozen =
        case Registry.lookup(SalixAgent.Registry, key) do
          [{_pid, %{runtime_epoch: frozen}}] when is_integer(frozen) -> frozen
          [{_pid, _}] -> 0
          [] -> nil
        end

      if is_integer(frozen) and frozen <= bound, do: stop(key)
    end)

    :ok
  end

  @spec stop(term()) :: :ok
  def stop(key) do
    case Registry.lookup(SalixAgent.Registry, key) do
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
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] -> stop_pid(pid, opts)
      [] -> :ok
    end
  end

  @doc false
  @spec stop_pid(pid(), keyword()) :: :ok | {:error, term()}
  def stop_pid(pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    reason = Keyword.get(opts, :reason, :normal)
    timeout = Keyword.get(opts, :timeout, :infinity)

    try do
      :gen_statem.stop(pid, reason, timeout)
    catch
      :exit, {:timeout, _} ->
        if Keyword.get(opts, :force, false) do
          Process.exit(pid, :kill)
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
  def terminate_child(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(SalixAgent.FleetSup, pid)
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
    internal =
      Registry.select(SalixAgent.Registry, [
        {{{:internal_session, agent_id, :"$1"}, :"$2", :"$3"}, [],
         [{{:internal_session, agent_id, :"$1"}}]}
      ])

    external =
      Registry.select(SalixAgent.Registry, [
        {{{:external_session, agent_id, :"$1"}, :"$2", :"$3"}, [],
         [{{:external_session, agent_id, :"$1"}}]}
      ])

    Enum.uniq(internal ++ external)
  end
end
