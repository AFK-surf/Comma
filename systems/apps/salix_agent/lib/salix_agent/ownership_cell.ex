defmodule SalixAgent.OwnershipCell do
  @moduledoc """
  Node-local runtime ownership cell, one entry per agent.

  The durable authority for agent ownership is the fenced root head
  (`SalixStore.Agent`); this cell is only its node-local, zero-I/O mirror so
  session-level code can (a) stamp the owner epoch into session commits and
  (b) refuse new LLM/tool dispatches the instant this node learns it was
  superseded — without adding any object-storage roundtrips.

  Entries are `{epoch, :owned | :fenced}`:

    * `install/2` — written by `SalixAgent.Server` when a claim lands.
    * `fence/2` — written on any fencing observation (fenced commit/renew,
      the new owner's takeover nudge). `observed_epoch` is the epoch the
      observation carried; a fence never regresses a newer installed epoch,
      an epoch-less fence never flips a currently `:owned` entry (no
      evidence beats a live claim), and `install` for a higher epoch
      re-owns a fenced entry.
    * Lifecycle bound: one row per agent with live runtime on this pod. A
      cleanly passivating Server `release/2`s its own `:owned` entry (guarded
      so a newer claim or fence is preserved), and a full superseded-runtime
      teardown `clear_superseded/1`s the `:fenced` residue once nothing is
      left for it to gate. Session actors that outlive the root Server do not
      need the entry to stamp safely: each actor freezes its own
      `runtime_epoch` (its Registry value) at start/first commit, so fencing
      admission compares against that immutable actor-scoped epoch, never
      against this mutable cell alone.

  Every function here is best-effort and fail-open BY DESIGN: this cell is a
  fast-path mirror, never the safety authority (the durable session-object
  epoch CAS is). A missing table or a dead GenServer must degrade to
  "absent" — i.e. legacy, unfenced behavior — rather than raise into the
  Server's claim path or a session actor's commit path.

  The table is owned by the application master (created in
  `SalixAgent.Application.start/2`, like the EventArchive accumulator), so
  a crash of this GenServer never drops recorded fences. Mutations are
  serialized through the GenServer so an out-of-order fence can never
  clobber a newer claim; reads are direct ETS lookups on the hot path.
  """

  use GenServer

  @table __MODULE__

  @type status :: :owned | :fenced

  @doc false
  def create_table do
    if :ets.whereis(@table) == :undefined do
      _ = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Record that this node claimed the agent root at `epoch`. Best-effort."
  @spec install(String.t(), non_neg_integer()) :: :ok
  def install(agent_id, epoch) when is_binary(agent_id) and is_integer(epoch),
    do: safe_call({:install, agent_id, epoch})

  @doc """
  Mark this node's runtime for the agent as superseded. Best-effort; see the
  moduledoc for the epoch guards.
  """
  @spec fence(String.t(), non_neg_integer() | nil) :: :ok
  def fence(agent_id, observed_epoch \\ nil) when is_binary(agent_id),
    do: safe_call({:fence, agent_id, observed_epoch})

  @doc """
  Current local ownership view for stamping/fencing session commits:
  `{:ok, epoch}` when this node holds (or last held) the agent at `epoch`,
  `:fenced` when this node knows it was superseded, `:absent` when the agent
  never ran here (legacy/single-purpose paths stay unfenced and unstamped) —
  and also when the table itself is unavailable, failing open to legacy
  behavior rather than raising into a commit path.
  """
  @spec fetch(String.t()) :: {:ok, non_neg_integer()} | :fenced | :absent
  def fetch(agent_id) when is_binary(agent_id) do
    case entry(agent_id) do
      {:ok, epoch, :owned} -> {:ok, epoch}
      {:ok, _epoch, :fenced} -> :fenced
      :absent -> :absent
    end
  end

  @doc """
  Like `fetch/1` but with the epoch of a fenced entry exposed, so callers can
  compare fence evidence against an actor-captured epoch (a fence recorded at
  an epoch BELOW a work item's own epoch is stale evidence for that item).
  """
  @spec entry(String.t()) :: {:ok, non_neg_integer(), status()} | :absent
  def entry(agent_id) when is_binary(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, epoch, status}] -> {:ok, epoch, status}
      [] -> :absent
    end
  rescue
    ArgumentError -> :absent
  end

  @doc """
  Cheap pre-dispatch gate for LLM/tool work: only a known-superseded runtime
  refuses. Absent or owned entries answer `:ok` — safety comes from the
  durable session fence, this is the fast local abort.
  """
  @spec check(String.t()) :: :ok | {:error, :fenced}
  def check(agent_id) when is_binary(agent_id) do
    case fetch(agent_id) do
      :fenced -> {:error, :fenced}
      _ -> :ok
    end
  end

  @doc false
  @spec clear(String.t()) :: :ok
  def clear(agent_id) when is_binary(agent_id),
    do: safe_call({:clear, agent_id})

  @doc """
  Bounded-lifecycle clear for a clean passivation: removes the entry only
  while it still records this owner's claim (`:owned` at or below `epoch`).
  A newer claim or a fence recorded meanwhile is preserved.
  """
  @spec release(String.t(), non_neg_integer()) :: :ok
  def release(agent_id, epoch) when is_binary(agent_id) and is_integer(epoch),
    do: safe_call({:release, agent_id, epoch})

  @doc """
  Bounded-lifecycle clear after a full superseded-runtime teardown: removes a
  `:fenced` entry (there is nothing left on this node for it to gate). An
  `:owned` entry — a claim that landed meanwhile — is preserved.
  """
  @spec clear_superseded(String.t()) :: :ok
  def clear_superseded(agent_id) when is_binary(agent_id),
    do: safe_call({:clear_superseded, agent_id})

  # A cell outage (missing process, timeout) must never raise into a claim
  # or commit path — the durable fences stay authoritative without it.
  defp safe_call(msg) do
    GenServer.call(__MODULE__, msg, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:install, agent_id, epoch}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, cur, _status}] when cur > epoch ->
        # A stale (delayed) install must not regress a newer claim/fence.
        :ok

      _ ->
        :ets.insert(@table, {agent_id, epoch, :owned})
    end

    {:reply, :ok, state}
  end

  def handle_call({:fence, agent_id, observed_epoch}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, cur, status}] ->
        cond do
          is_integer(observed_epoch) and observed_epoch < cur ->
            # Fence evidence about an epoch we already superseded locally
            # (this node re-claimed at a higher epoch): ignore.
            :ok

          is_nil(observed_epoch) and status == :owned ->
            # No epoch evidence never flips a live claim.
            :ok

          true ->
            :ets.insert(@table, {agent_id, max(cur, observed_epoch || 0), :fenced})
        end

      [] ->
        :ets.insert(@table, {agent_id, observed_epoch || 0, :fenced})
    end

    {:reply, :ok, state}
  end

  def handle_call({:clear, agent_id}, _from, state) do
    :ets.delete(@table, agent_id)
    {:reply, :ok, state}
  end

  def handle_call({:release, agent_id, epoch}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, cur, :owned}] when cur <= epoch -> :ets.delete(@table, agent_id)
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:clear_superseded, agent_id}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, _cur, :fenced}] -> :ets.delete(@table, agent_id)
      _ -> :ok
    end

    {:reply, :ok, state}
  end
end
