defmodule SalixCluster.Recovery do
  @moduledoc """
  The recovery singleton is the durable backstop that makes wake hints losable.
  Periodically, while holding the double-gated `:recovery` S3 singleton lease,
  it sweeps:

    * Postgres eager/deferred candidate lanes — bounded, token-addressed
      projections for durable non-stable sessions.
      Eager work is paginated independently; deferred waits are ordered by
      exact deadline and are not hydrated before they are due. Recovery
      validates every hint against the session state that owns the token before
      waking its exact target. Callback-only work has no global recovery scan;
      its callback API remains the sole wake authority.
    * connector run mappings, two-tier: every tick walks the keys-only
      by-node index and sweeps runs owned by dead BEAM nodes
      (each snapshotted run resolved fresh and disconnected under an
      owner + connection_generation fence); a low-frequency deep pass
      (every `@deep_sweep_every` ticks, and on every direct `sweep_once/1`
      call) additionally scans the authoritative records for aged connected
      runs whose live owner lost its socket, and reconciles the by-node
      index (a marker whose run record is gone is deletion residue and is
      pruned; a run whose marker never landed is only reachable by this
      scan and is swept here — missing markers are not recreated. The index
      may lie in both directions, so the deep pass is the correctness
      backstop and the fast path is only an optimization).

  This is the single-node realization; the multi-node version additionally checks
  dist-liveness of the head's `owner_node` and steals stale `ctl/leases/` entries.

  `sweep_once/1` runs one pass deterministically (tests call it directly). The
  GenServer holds the lease and ticks `sweep_once` on an interval.

  The queued-marker and recent-strand lanes (the fair RecoveryWake action of
  the archived staged-delivery spec, A2 §3.5) retired with the staged delivery
  protocol (A2 §3.4): deliveries commit into session ledgers at deliver time,
  so lost wakes are rediscovered exclusively through the candidate
  projections. The notification listener subscribes before requesting catch-up;
  durable candidate discovery repairs lost hints. The retired notification
  model is historical evidence, not a current machine-checked guarantee.
  """
  use GenServer
  require Logger

  alias SalixCluster.S3Lease
  alias SalixAgent.SessionWorkRecovery

  @interval_ms 10_000

  # Every Nth tick runs the deep env sweep (authoritative-record scan +
  # by-node index reconciliation) instead of only the keys-only fast path.
  # The stale-owner deep check already carries a 30s registration grace, so
  # raising its cadence from 10s to ~60s costs one extra minute of detection
  # latency for a rare crash shape, and saves 2N record GETs on 5 of 6 ticks.
  @deep_sweep_every 6

  # The OAuth auth-state purge is retention housekeeping (10min pending TTL,
  # 24h terminal retention), not a recovery path: nothing waits on a purge,
  # and a deferred pass only delays deletions. Running it on every 10s tick
  # re-read the whole 24h corpus ~8,640×/day for work a 10-minute cadence
  # does equally well, so the ticker gates it to every Nth tick. Direct
  # `sweep_once/1` callers (tests, operators) keep the purge by default.
  @oauth_purge_every 60

  # ---- API ----

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc """
  Run one recovery pass. Returns `{:ok, summary_map}`.
  Options: `:now` (clock injection). Does not require the singleton lease (the
  GenServer gates on it; direct callers are responsible).
  """
  @spec sweep_once(keyword()) :: {:ok, map()} | {:error, term()}
  def sweep_once(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    session_work =
      if Keyword.get(opts, :session_work, true),
        do: SessionWorkRecovery.sweep(opts),
        else: SessionWorkRecovery.empty_summary()

    # The queue-marker and recent-touch lanes retired with the staged delivery
    # protocol (A2 §3.4): deliveries commit into session ledgers at deliver
    # time, and lost wakes are rediscovered through the PG candidate
    # projection lanes — there is no agent-level staging left to re-home.

    # Run resolution prunes mappings that no longer match the stable device.
    # A current connector whose owning node is gone has lost its socket, so
    # mark its stable device disconnected.
    env_disconnected = sweep_envs(opts)
    # OAuth auth-state retention (willow PurgeExpiredOAuthAuthStates, run
    # from its GC sweep): expired/terminal ctl/oauth/auth_states/ records are
    # deleted under CAS. Best-effort — a purge failure never blocks recovery.
    # The ticker passes `oauth_purge: false` off-cadence (@oauth_purge_every).
    oauth_states_purged =
      if Keyword.get(opts, :oauth_purge, true), do: sweep_oauth_auth_states(now), else: 0

    local_file_refs_cleaned =
      if Keyword.get(opts, :local_file_ref_cleanup, true),
        do: sweep_local_file_refs(now),
        else: 0

    {:ok,
     %{
       session_work_rewoken: session_work.rewoken,
       session_work_scanned: session_work.scanned,
       session_work_cleaned: session_work.cleaned,
       session_work_failed: session_work.failed,
       session_work_unproven_retained: session_work.unproven_retained,
       session_work_cursor: session_work.next,
       session_work_deferred_cursor: session_work.deferred_next,
       session_work_last_attempted_lane: session_work.last_attempted_lane,
       env_disconnected: env_disconnected,
       oauth_states_purged: oauth_states_purged,
       local_file_refs_cleaned: local_file_refs_cleaned
     }}
  end

  @doc """
  Purge expired/terminal OAuth auth-state records
  (`SalixStore.OAuth.AuthState.purge_expired/1` — willow's
  `PurgeExpiredOAuthAuthStates`). Returns the purge count; never raises.
  """
  @spec sweep_oauth_auth_states(integer()) :: non_neg_integer()
  def sweep_oauth_auth_states(now) do
    case SalixStore.OAuth.AuthState.purge_expired(now) do
      {:ok, count} -> count
      _ -> 0
    end
  catch
    kind, reason ->
      Logger.warning("oauth auth-state purge failed: #{inspect({kind, reason})}")
      0
  end

  @doc "Run one bounded cleanup pass for expired registered/bound local-file refs."
  @spec sweep_local_file_refs(integer()) :: non_neg_integer()
  def sweep_local_file_refs(now) do
    case SalixStore.LocalFileRefs.cleanup_expired(now) do
      {:ok, count} -> count
      _ -> 0
    end
  catch
    kind, reason ->
      Logger.warning("local-file ref cleanup failed: #{inspect({kind, reason})}")
      0
  end

  @doc "Request a lease-gated durable Session-work catch-up after LISTEN succeeds."
  @spec request_session_work_catchup(GenServer.server()) :: :ok | {:error, :not_running}
  def request_session_work_catchup(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      _pid -> GenServer.cast(server, :session_work_catch_up)
    end
  end

  # A connected record younger than this may belong to a socket still
  # registering its owner; never deep-check inside the window.
  @ownerless_grace_ms 30_000

  @doc """
  Mark stale `connected` env records as disconnected. Two staleness classes:

    * owner node is not in the live set;
    * owner node is live (this node or a connected peer) but **no socket
      owner is registered there** (`SalixEnv.Bridge.live_on?/2`) and the
      record is older than a grace window — the crash-skipped-terminate case
      (e.g. a node restart under the same name), which node liveness alone
      cannot catch.

  Returns the list of disconnected env ids. `:live_nodes` overrides the
  live-set (tests); defaults to `[node() | Node.list()]`. `:now` injects the
  clock (ms).

  Pass `deep: false` for the keys-only fast path (dead-node markers only) —
  the production tick does this on 5 of 6 intervals. The default keeps the
  full semantics for direct callers and tests.
  """
  @spec sweep_envs(keyword()) :: [String.t()]
  def sweep_envs(opts \\ []) do
    live = live_node_set(opts)

    # The marker snapshot is taken BEFORE the deep pass lists the
    # authoritative records: connect writes the run record first and the
    # marker second, so with this ordering a marker-without-record observation
    # can only be deletion residue, never a mid-connect window.
    markers = list_node_markers()

    fast = sweep_dead_node_markers(markers, live, opts)

    if Keyword.get(opts, :deep, true) do
      Enum.uniq(fast ++ sweep_envs_deep(markers, live, opts))
    else
      fast
    end
  end

  # ---- fast path: keys-only by-node index walk ----

  defp list_node_markers do
    case SalixStore.S3.list_all(SalixStore.Keys.connector_runs_by_node_all_prefix()) do
      {:ok, objects} -> Enum.flat_map(objects, &parse_node_marker_key/1)
      _ -> []
    end
  end

  defp parse_node_marker_key(%{key: key}) do
    rest =
      String.replace_prefix(key, SalixStore.Keys.connector_runs_by_node_all_prefix(), "")

    case String.split(rest, "/") do
      [node, file] when node != "" and file != "" ->
        [{node, String.trim_trailing(file, ".json")}]

      _ ->
        []
    end
  end

  # Destructive action is taken ONLY on the snapshotted {node, run_id} pairs,
  # resolved fresh through the same fenced pipeline as the deep pass. A
  # re-listing here would widen the race to runs born AFTER the snapshot: a
  # node that rejoins under the same name passes an owner-only fence and its
  # healthy generation-2 run would be torn down. Acting on snapshot members is
  # safe by construction — run ids are never reused, so a snapshotted id is
  # either already retired (fresh resolve returns nothing → no-op) or still
  # the stale generation the connection_generation fence expects.
  defp sweep_dead_node_markers(markers, live, opts) do
    now = opts[:now] || System.system_time(:millisecond)

    markers
    |> Enum.reject(fn {node, _id} -> node in live end)
    |> Enum.flat_map(fn {_node, id} -> connector_run_summary(%{key: run_record_key(id)}) end)
    |> Enum.filter(&stale_connected?(&1, live, now))
    |> Enum.flat_map(&disconnect_if_still_stale(&1, opts, now))
  end

  defp run_record_key(id), do: SalixStore.Keys.connector_run(id)

  # ---- deep pass: authoritative-record scan + index reconciliation ----

  defp sweep_envs_deep(markers, live, opts) do
    now = opts[:now] || System.system_time(:millisecond)

    case SalixStore.S3.list_all(SalixStore.Keys.connector_runs_prefix()) do
      {:ok, objects} ->
        reconcile_node_markers(markers, objects)

        objects
        |> Enum.flat_map(&connector_run_summary/1)
        |> Enum.filter(&stale_connected?(&1, live, now))
        |> Enum.flat_map(&disconnect_if_still_stale(&1, opts, now))

      _ ->
        []
    end
  end

  # The destructive-action gate shared by both tiers. The owner + generation
  # fence protects against a reconnect AFTER this resolve, but it cannot
  # protect a reconnect the resolve itself already observed: the deep pass
  # lists the authoritative records AFTER the liveness snapshot, so a node
  # that rejoined in between would present its healthy new generation as
  # exactly what the fence expects. Liveness is therefore re-taken
  # immediately before every disconnect (zero-IO node-list locally; an
  # injected :live_nodes list stays fixed by design, and tests model a
  # rejoin with a function). A run whose owner is alive again is left to the
  # ownerless deep check, which requires a real socket-registry miss plus
  # the registration grace.
  defp disconnect_if_still_stale(summary, opts, now) do
    if stale_connected?(summary, live_node_set(opts), now) do
      disconnect_stale_run(summary, opts)
    else
      []
    end
  end

  # Owner AND the connection_generation observed in the fresh resolve, so a
  # reconnect racing in after the gate can never be matched.
  defp disconnect_stale_run(
         {id, _transport_id, _status, owner, _updated, connection_generation},
         opts
       ) do
    case SalixEnv.Registry.mark_disconnected(
           id,
           opts
           |> Keyword.put(:owner_node, owner)
           |> Keyword.put(:connection_generation, connection_generation)
         ) do
      {:ok, %{"status" => "disconnected"}} -> [id]
      _ -> []
    end
  end

  # A by-node marker whose authoritative run record is gone is deletion
  # residue (run ids are never reused; connect writes record-then-marker and
  # the marker snapshot predates the record listing). Without this the index
  # leaks forever whenever a cleanup deleted the record but lost the marker
  # delete.
  defp reconcile_node_markers(markers, record_objects) do
    live_ids =
      MapSet.new(record_objects, fn %{key: key} ->
        key
        |> String.replace_prefix(SalixStore.Keys.connector_runs_prefix(), "")
        |> String.trim_trailing(".json")
      end)

    orphans = Enum.reject(markers, fn {_node, id} -> MapSet.member?(live_ids, id) end)

    if orphans != [] do
      Logger.info("recovery: pruning #{length(orphans)} orphaned by-node connector markers")
      Enum.each(orphans, fn {node, id} -> SalixEnv.Registry.prune_node_marker(node, id) end)
    end

    :ok
  end

  # `:live_nodes` accepts a zero-arity function so tests can model liveness
  # CHANGING between the sweep's snapshot and the destructive-action gate
  # (a same-name node rejoining). A plain list stays fixed across re-reads;
  # the production default re-derives from the real distribution every call.
  defp live_node_set(opts) do
    case opts[:live_nodes] do
      fun when is_function(fun, 0) -> fun.() |> to_live_set()
      list when is_list(list) -> to_live_set(list)
      nil -> to_live_set([node() | Node.list()])
    end
  end

  defp to_live_set(nodes), do: nodes |> Enum.map(&to_string/1) |> MapSet.new()

  defp stale_connected?(
         {_id, transport_id, status, owner, updated_at, _connection_generation},
         live,
         now
       ) do
    status == "connected" and
      (owner not in live or verifiably_ownerless?(transport_id, owner, updated_at, now))
  end

  # Deep-check only owners we can actually interrogate: this node's local
  # bridge registry, or a connected BEAM peer via :erpc. Other "live" nodes
  # (e.g. a test-injected live set) are left alone — absence of proof is not
  # staleness.
  defp verifiably_ownerless?(id, owner, updated_at, now) do
    checkable =
      owner == to_string(node()) or owner in Enum.map(Node.list(), &to_string/1)

    checkable and now - (updated_at || 0) > @ownerless_grace_ms and
      not SalixEnv.Bridge.live_on?(owner, id)
  end

  defp connector_run_summary(%{key: key}) do
    id =
      key
      |> String.replace_prefix(SalixStore.Keys.connector_runs_prefix(), "")
      |> String.trim_trailing(".json")

    with {:ok, transport_id, rec} <- SalixEnv.Registry.get_by_connector_run_id(id) do
      [
        {id, transport_id, rec["status"], rec["node"], rec["updated_at"] || rec["registered_at"],
         rec["connection_generation"]}
      ]
    else
      _ -> []
    end
  end

  # ---- GenServer (lease-gated periodic sweep) ----

  @impl true
  def init(opts) do
    state = %{
      node: Keyword.get(opts, :node, to_string(node())),
      interval: Keyword.get(opts, :interval_ms, @interval_ms),
      lease: nil,
      # Tick counter for the deep-sweep cadence; the first held tick is deep.
      tick_count: 0,
      # Domain worker target. Production uses the supervised singleton; tests
      # may isolate cadence/failure behavior behind a separate name.
      session_work_recovery:
        Keyword.get(opts, :session_work_recovery, SalixAgent.SessionWorkRecovery),
      # A listener may reconnect on a follower Pod. Retain its catch-up request
      # until this local Recovery owns the singleton lease; the current leader's
      # periodic sweep remains the independent completeness backstop.
      session_work_catch_up_pending: false
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_cast(:session_work_catch_up, %{lease: nil} = state) do
    {:noreply, %{state | session_work_catch_up_pending: true}}
  end

  def handle_cast(:session_work_catch_up, state) do
    pending = not request_session_work_sweep(state.session_work_recovery)
    {:noreply, %{state | session_work_catch_up_pending: pending}}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  # Late messages from a task generation already replaced (or any stray
  # message): ignore rather than crash the singleton.
  def handle_info(_msg, state), do: {:noreply, state}

  defp tick(state) do
    state = acquire_or_renew(state)

    state =
      if state.lease do
        deep? = rem(state.tick_count, @deep_sweep_every) == 0
        oauth_purge? = rem(state.tick_count, @oauth_purge_every) == 0

        # Shared correctness sweeps run synchronously under the lease. Slow
        # SessionActor wakes run in their owning single-flight worker so they
        # cannot stall renewal or the next tick.
        {:ok, result} =
          sweep_once(
            deep: deep?,
            local_file_ref_cleanup: oauth_purge?,
            oauth_purge: oauth_purge?,
            session_work: false
          )

        log_sweep(result)

        session_work_catch_up_pending =
          not request_session_work_sweep(state.session_work_recovery)

        state
        |> Map.put(:session_work_catch_up_pending, session_work_catch_up_pending)
        |> then(&%{&1 | tick_count: &1.tick_count + 1})
      else
        state
      end

    Process.send_after(self(), :tick, state.interval)
    state
  end

  defp log_sweep(%{session_work_rewoken: s}) do
    if s != [] do
      Logger.info("recovery: session-work #{inspect(s)}")
    end
  end

  defp request_session_work_sweep(server) do
    case SessionWorkRecovery.request_sweep(server) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("session-work recovery request failed: #{reason}")
        false
    end
  end

  defp acquire_or_renew(%{lease: nil} = state) do
    case S3Lease.acquire(:recovery, state.node) do
      {:ok, token} ->
        %{state | lease: token}

      _ ->
        state
    end
  end

  defp acquire_or_renew(%{lease: token} = state) do
    case S3Lease.renew(token) do
      {:ok, token} ->
        %{state | lease: token}

      # Fail-closed: drop leadership; a later tick re-acquires if eligible.
      _ ->
        %{state | lease: nil}
    end
  end
end
