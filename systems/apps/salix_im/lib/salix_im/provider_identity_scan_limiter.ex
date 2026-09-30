defmodule SalixIM.ProviderIdentityScanLimiter do
  @moduledoc """
  Process-owned HARD concurrency bound for the IM identity fallback scan.

  The fallback scan is O(corpus) GETs against one shared prefix, reached
  pre-authentication by the webhook routes, so the bound must hold under
  every failure mode. The state-ownership SHAPE (round-11): the permit
  table is created by `SalixIM.Application.start/2`, so its owner is the
  application-start callback process — a process with **application
  lifetime** (linked into the application master pair; it hosts no
  supervised work and can only go down with the application itself,
  which a permanent release escalates to VM exit, taking every holder
  with it). No supervised worker owns occupancy; the limiter is the
  sole admission logic, and its crash/restart adopts the surviving
  rows.

    * **One supervised owner, started before the node serves** — every
      acquire is serialized through it, so N cold-start callers can
      never each allocate their own counter and all pass a cap of one.
    * **Monitor-tied permits** — a caller killed without running its
      `after` clause is reclaimed on `:DOWN`; slots cannot leak a pod
      into permanent starvation.
    * **Occupancy survives owner restarts** — a restarted limiter
      re-monitors the recorded holders. Adoption never re-inserts rows
      (a release that raced the restart stays released — no
      resurrection), and the monitor index lives in the owner's state,
      so a normal release always demonitors the CURRENT monitor.
    * **Fail closed, never open** — an absent, stopping, overloaded, or
      crashed owner yields `{:error, :scan_capacity_exhausted}` (the
      routes' retryable 503), never an unbounded scan. An invalid cap
      value (non-integer or negative) is treated as 0 — loud,
      retryable, observable — rather than silently admitting everything
      through an Erlang term comparison.
    * **Cancellable lease handoff (same-owner)** — a grant only counts
      once the caller actually received it. The caller names its permit
      ref in the request and sends a cancellation for that ref on call
      failure. While the SAME owner handles both messages, ordering
      between two processes guarantees the cancellation is processed
      after the acquire it cancels: it revokes a granted-but-undelivered
      row, or no-ops on a rejected call, so a rejected still-live caller
      leaves occupancy unchanged (round-12; a bare deadline check could
      not prove delivery). **Known accepted gap (round-13 owner
      disposition):** if the owner exits between inserting the row and
      replying, the cancellation targets a momentarily absent registered
      name and is dropped, so the replacement adopts a permit whose
      caller was told "rejected". The permit stays monitor-tied to that
      caller and is reclaimed when it exits — advisory capacity, briefly
      one lower, never a permanent leak. See the decision record.

  The cap is read live from `:salix_im, :identity_scan_max_concurrency`
  (config.json `im.identity_scan_max_concurrency`, default 4), so
  operators can retune without a restart.
  """
  use GenServer

  @default_cap 4
  @default_table :salix_im_identity_scan_permits
  @acquire_timeout 5_000

  @doc """
  Create the permit table. Called from `SalixIM.Application.start/2`, so
  the table's owner is the application-lifetime start-callback process:
  no supervised worker crash can reset occupancy while holders are
  still scanning. Idempotent.
  """
  def create_table!(table \\ @default_table) do
    if :ets.whereis(table) == :undefined do
      _ = :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, Keyword.get(opts, :table, @default_table),
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  Reserve one scan slot for the calling process. `{:ok, permit}` under
  the cap; `{:error, :scan_capacity_exhausted}` over it — and on EVERY
  owner failure (absent, stopping, call timeout, crash mid-call): the
  bound fails closed into the routes' retryable 503, never into an
  unbounded scan. The caller names its permit ref up front and cancels
  it on call failure, which revokes a grant it never received while the
  same owner is still serving (see the moduledoc for the accepted
  owner-exit gap).
  """
  def acquire(server \\ __MODULE__, timeout \\ @acquire_timeout) do
    permit_ref = make_ref()

    try do
      GenServer.call(server, {:acquire, self(), permit_ref}, timeout)
    catch
      :exit, _ ->
        GenServer.cast(server, {:cancel, permit_ref})
        {:error, :scan_capacity_exhausted}
    end
  end

  @doc """
  Release a permit from `acquire/2`. Deletes the row directly (works
  even while the owner is down or restarting) and tells the owner to
  drop its current monitor. Safe to call more than once.
  """
  def release(server \\ __MODULE__, {table, ref}) do
    _ = safe_delete(table, ref)
    GenServer.cast(server, {:released, ref})
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  def count(server \\ __MODULE__), do: GenServer.call(server, :count)

  @impl true
  def init(table) do
    create_table!(table)

    # Adopt permits that survived a previous owner: monitor each
    # recorded holder (a dead pid delivers an immediate :DOWN and is
    # cleaned), CONDITIONAL on the row still existing — a release that
    # raced this adoption already deleted it and must never be
    # resurrected. Rows are never re-inserted here.
    monitors =
      Enum.reduce(:ets.tab2list(table), %{}, fn {ref, pid}, acc ->
        mon = Process.monitor(pid)

        if :ets.member(table, ref) do
          Map.put(acc, ref, mon)
        else
          Process.demonitor(mon, [:flush])
          acc
        end
      end)

    {:ok, %{table: table, monitors: monitors}}
  end

  @impl true
  def handle_call({:acquire, pid, permit_ref}, _from, state) do
    if :ets.info(state.table, :size) < cap() do
      mon = Process.monitor(pid)
      :ets.insert(state.table, {permit_ref, pid})
      {:reply, {:ok, {state.table, permit_ref}}, put_in(state.monitors[permit_ref], mon)}
    else
      {:reply, {:error, :scan_capacity_exhausted}, state}
    end
  end

  def handle_call(:count, _from, state), do: {:reply, :ets.info(state.table, :size), state}

  @impl true
  def handle_cast({:released, ref}, state) do
    # The monitor index maps the permit ref to the CURRENT monitor
    # (which differs from the ref after an adoption), so a normal
    # release never leaves the replacement monitor attached.
    {mon, monitors} = Map.pop(state.monitors, ref)
    if mon, do: Process.demonitor(mon, [:flush])
    {:noreply, %{state | monitors: monitors}}
  end

  # A caller that never received its grant revokes by the permit ref it
  # named in the request. Message ordering guarantees this runs AFTER
  # that acquire was processed BY THE SAME OWNER: it deletes the
  # granted-but-undelivered row, or no-ops when the acquire was
  # rejected (no row) or the release already ran. A cast that arrives
  # while the registered name is absent (owner exited between insert
  # and reply) is dropped — the accepted round-13 gap.
  def handle_cast({:cancel, ref}, state) do
    _ = safe_delete(state.table, ref)
    {mon, monitors} = Map.pop(state.monitors, ref)
    if mon, do: Process.demonitor(mon, [:flush])
    {:noreply, %{state | monitors: monitors}}
  end

  @impl true
  def handle_info({:DOWN, down_mon, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_ref, mon} -> mon == down_mon end) do
      {ref, _mon} ->
        _ = safe_delete(state.table, ref)
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

      nil ->
        {:noreply, state}
    end
  end

  # Invalid cap config fails CLOSED (0): the fallback rejects loudly and
  # observably (rejected telemetry, retryable 503) instead of the silent
  # unbounded admission an Erlang term comparison against a string
  # would produce.
  defp cap do
    case Application.get_env(:salix_im, :identity_scan_max_concurrency, @default_cap) do
      cap when is_integer(cap) and cap >= 0 -> cap
      _invalid -> 0
    end
  end

  defp safe_delete(table, ref) do
    :ets.delete(table, ref)
  rescue
    ArgumentError -> :ok
  end
end
