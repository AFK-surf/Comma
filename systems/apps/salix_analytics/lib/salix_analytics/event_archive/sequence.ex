defmodule SalixAnalytics.EventArchive.Sequence do
  @moduledoc """
  Per-stream monotonic sequence numbers, and the writer epoch that scopes them.

  Gap DETECTABILITY is what makes the archive's best-effort write path
  defensible. Every item carries a `seq`, and `mix salix.archive.verify` reports
  any break in the run — count, boundary, and time range — without needing a key.

  The claim is narrower than "never silently incomplete", which an earlier
  revision made and which is false: tail loss, loss before the query window,
  and a run lost in its entirety are all invisible. `Completeness` opens with
  that list. What holds is that within a run a reader can see, every interior
  gap is exact.

  The counter is atomic, so seqs are unique per stream even under concurrent
  writers — and there ARE concurrent writers on the session stream: title
  generation and the trajectory-eval judge each run in their own process and
  each passes the session id to the dispatch seam explicitly, so they allocate
  on that session's stream alongside the round. What that costs is ordering:
  `ts` is stamped after `seq`, so a higher seq can carry a lower ts.
  `Completeness` therefore orders by `seq` alone.

  An earlier revision said those two got onto the session stream by "carrying
  the session's billing context". They do carry it, but it is not what places
  them: no billing context in this system names a session, and believing
  otherwise is exactly how provider traffic came to be archived with empty
  identity. A stream is named from the identity fields on the item, and for
  boundaries 2 and 3 those come from the `identity` argument the call site
  passes to `SalixAgent.LLM` — never from the billing context alone.

  Streams are:

    * `agent:<agent_id>:inbox` — inbound deliveries, staged by the agent actor,
      which is the sole writer of that inbox.
    * `session:<session_id>:loop` — everything else for that session, async
      tool settlement included. OWNED by the session actor but not written by
      it alone; see the concurrent writers above.

  A third name is degenerate rather than designed: an item carrying neither a
  session nor an agent id falls back to `agent_stream/1` with an empty id and
  lands on `agent::inbox`, where every such item on the node shares one run.
  Dispatch callers must pass identity. Rows on this stream are unattributable
  and unerasable by tenant. Runtime tests must inspect the archived identity.

  ## The writer epoch

  Counters live in ETS on the node that owns the actor, so a node restart or an
  actor moving between nodes restarts the run at 1. Under the previous
  object-storage target that was merely ambiguous — `verify` guessed a reset
  from a repeated seq 1. Against a ReplacingMergeTree it is a **correctness
  problem**: `(stream, seq)` repeats across boots, and a dedup key that repeats
  makes the engine collapse two genuinely different events into one. Silent
  destruction of archived data, by the very mechanism that is supposed to make
  retries safe.

  So each BEAM instance draws one random `writer` id at boot and stamps it on
  every item. `(stream, writer, seq)` is then unique by construction, which buys
  three things at once:

    * a retried insert of the same item is idempotent — the engine collapses the
      duplicate, where object storage used to leave two copies of the line;
    * two different items can never merge;
    * a reset is an observed fact (a second writer on the stream) rather than an
      inference from a repeated seq.

  The id is drawn once and cached in `:persistent_term`: it must be stable for
  the life of the node, and it is read on every archived item.
  """

  @table __MODULE__
  @writer_key {__MODULE__, :writer}

  @doc "Create the counter table. Idempotent; called from the supervision root."
  @spec create_table() :: :ok
  def create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  This node's writer epoch: 128 random bits, hex, drawn once per boot.

  Random rather than derived from the node name, because a pod that restarts
  keeps its name but not its counters — deriving from identity would reuse the
  epoch across exactly the boundary it exists to distinguish.
  """
  @spec writer() :: String.t()
  def writer do
    case :persistent_term.get(@writer_key, :miss) do
      :miss ->
        id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
        # put/2 is idempotent under a race: both racers write a valid epoch and
        # whichever lands second is the one every subsequent read returns. A
        # racing pair can therefore stamp two epochs on the first few items,
        # which reads as one extra reset at boot — never as a collision.
        :persistent_term.put(@writer_key, id)
        :persistent_term.get(@writer_key, id)

      cached ->
        cached
    end
  end

  @doc "Drop the cached writer epoch. Tests only."
  @spec reset_writer() :: :ok
  def reset_writer do
    _ = :persistent_term.erase(@writer_key)
    :ok
  end

  @doc "Next sequence number for `stream`, starting at 1."
  @spec next(String.t()) :: pos_integer()
  def next(stream) when is_binary(stream) do
    :ets.update_counter(@table, stream, {2, 1}, {stream, 0})
  rescue
    ArgumentError ->
      # Table missing (a test process, or archiving before boot completed).
      # Creating it here keeps the emitter path total; the cost is that this
      # stream's run restarts, which verify reports as a reset, not a gap.
      create_table()
      :ets.update_counter(@table, stream, {2, 1}, {stream, 0})
  end

  @doc "Forget a stream's counter once its session is finished."
  @spec forget(String.t()) :: :ok
  def forget(stream) when is_binary(stream) do
    :ets.delete(@table, stream)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Stream name for an agent's inbox."
  @spec agent_stream(String.t()) :: String.t()
  def agent_stream(agent_id), do: "agent:" <> to_string(agent_id) <> ":inbox"

  @doc "Stream name for a session's loop."
  @spec session_stream(String.t()) :: String.t()
  def session_stream(session_id), do: "session:" <> to_string(session_id) <> ":loop"
end
