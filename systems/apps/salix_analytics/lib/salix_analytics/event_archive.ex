defmodule SalixAnalytics.EventArchive do
  @moduledoc """
  Production adapter for `SalixAgent.EventArchive`, writing to ClickHouse.

  Duck-typed against that behaviour — salix_analytics does not depend on
  salix_agent, the same arrangement `SalixAnalytics.TrajectoryEvalRecorder`
  uses. Production wires it in via `:salix_agent, :event_archive_mod`.

  ## Why this lives in salix_analytics

  ClickHouse belongs to this app: the migrations, the connection config, the
  readiness probes and the existing narrow HTTP sinks are all here, and
  `salix_analytics` depends on `salix_store` rather than the reverse. Putting
  the adapter anywhere else would mean either a dependency cycle or a second,
  divergent copy of the ClickHouse plumbing.

  The crypto stayed behind in `SalixStore.Age`, because it is pure and has no
  business knowing where ciphertext lands.

  Nothing on the agent side moved. `SalixAgent.EventArchive.Emit` and the
  boundary emitters are unchanged by this retarget, which is the seam design
  doing its job: the loop knows it archives, not what it archives to.

  ## The one structural rule

  `record/1` SEALS IN THE CALLING PROCESS and hands the worker ciphertext.
  Everything downstream — the buffer, the mailbox, a crash dump — holds age
  files only. Moving the seal into the worker would put plaintext agent traffic
  in a queue and defeat the whole design.

  ## Delivery is best-effort, and that is the only mode

  A full buffer drops the item and emits `[:salix_analytics, :event_archive,
  :dropped]`; a failed write emits `[…, :lost]`. The loop never waits on the
  archive and never learns whether an item landed.

  What it gets back is narrower than "every drop is detectable", and the
  difference matters. Every item consumes a `seq` before sealing, so a drop
  BRACKETED BY TWO ITEMS THAT DID LAND leaves a gap
  `mix salix.archive.verify` reports. A drop at the END of a run does not:
  consuming the seq is necessary but not sufficient, because there is no later
  row to bound the hole. A run whose last stored item is seq 1 and whose seq 2
  was dropped queries identically to a run that simply ended at seq 1 — the
  report returns no findings for either. Whole-run loss is invisible for the
  same reason: nothing to group by.

  So the telemetry above is not redundant with the gap report — but it does not
  cover everything the report misses either, and must not be described as if it
  did. `:dropped` and `:lost` both fire from a live node that NOTICED: a full
  buffer, a failed write. Two cases produce neither. `reserve/1` emits nothing
  and nothing later notices an unredeemed reservation, because the process that
  held it is gone; and a node that dies takes its ETS buffer with it, so no
  process survives to count what was in it. Some tail loss therefore has no live
  signal at all.

  See `reserve/1` for what reserving does and does not buy, and
  `SalixAnalytics.EventArchive.Completeness` for the full list of what the
  report cannot see.

  There used to be a disk spill under the buffer. It was answering a question
  nobody asked: the durable store IS a database now, and a second unreplicated
  queue on one pod's local disk in front of it added a failure surface — and a
  second copy of every sealed item to erase on a tenant purge — without adding
  durability.

  There used to be a `:strict` mode promising the opposite. It never worked:
  every emitter call site discards the emitter's return value, so a rejection
  had no path back into the loop. Wiring one up would have contradicted the rule
  in `systems/AGENTS.md` that archiving must never change a business result — so
  the mode is gone rather than repaired. An archive that can fail a user's turn
  is a different feature with a different risk profile; it needs its own
  decision, not a config flag that quietly reverses this one.
  """

  require Logger

  alias SalixAnalytics.EventArchive.{Item, Recipients, Sequence, Worker}

  @behaviour_boundaries ~w(delivery llm_request llm_response tool_call tool_result egress)a

  @doc """
  Can this adapter actually archive? False when no usable recipients are
  configured, so the emitter side skips payload assembly entirely.
  """
  @spec active?() :: boolean()
  def active?, do: Recipients.get() != []

  @doc """
  Archive one boundary crossing.

  Returns `:ok` for anything the caller could act on, because no caller acts on
  it — the return exists only to report an unknown boundary, which is a
  programming error rather than a runtime condition.
  """
  @spec record(map()) :: :ok | {:error, term()}
  def record(%{boundary: boundary} = fact) when boundary in @behaviour_boundaries do
    case Recipients.get() do
      [] -> :ok
      recipients -> seal_and_enqueue(fact, recipients)
    end
  end

  def record(%{boundary: boundary}), do: {:error, {:unknown_boundary, boundary}}

  @doc """
  Take the stream position an item will occupy, before it is produced.

  See `SalixAgent.EventArchive.reserve/1` for why. The reservation carries the
  writer epoch it was taken under so that a redemption after a restart — which
  cannot happen for the process-death case this exists for, but can happen if
  someone stores one — is caught rather than writing under a stale epoch.

  Returns `nil` when there is nothing to archive, so no counter is bumped on a
  node with no recipients.
  """
  @spec reserve(map()) :: map() | nil
  def reserve(%{boundary: _boundary} = fact) do
    case Recipients.get() do
      [] ->
        nil

      _recipients ->
        stream = stream_for(fact)
        %{stream: stream, writer: Sequence.writer(), seq: Sequence.next(stream)}
    end
  end

  def reserve(_fact), do: nil

  defp seal_and_enqueue(fact, recipients) do
    {stream, seq} = position(fact)
    attrs = attrs(fact, stream, seq)

    case Item.seal(attrs, fact.payload, recipients) do
      {:ok, row} ->
        deliver(%{row: row, stream: stream, header: attrs})

      {:error, reason} ->
        # A seal failure is never silent: it is the one error that means an
        # item exists nowhere at all, with no gap marker to find it by.
        Logger.error("event archive seal failed: #{inspect(reason)}")
        emit(:seal_error, fact)
        :ok
    end
  end

  defp deliver(sealed) do
    case Worker.enqueue(sealed) do
      :ok ->
        :ok

      {:error, reason} ->
        emit(:dropped, sealed.header)
        Logger.warning("event archive dropped item: #{inspect(reason)}")
        :ok
    end
  end

  # An item belongs to the stream of the actor that OWNS it: inbound deliveries
  # are staged by the agent actor before any session actor exists, everything
  # else belongs to the session. Ownership, not exclusivity — the session stream
  # has concurrent writers: title generation and the trajectory-eval judge each
  # run in their own process and each passes the session id to the dispatch
  # seam. (Not, as this comment used to say, by "carrying the session's billing
  # context" — no billing context in this system names a session, and assuming
  # one did is how provider traffic came to be archived with empty identity.)
  # The counter is atomic so seqs stay unique; what it costs is ordering, which
  # is why `Completeness` orders by `seq` rather than `ts`.
  #
  # The last clause is a fallback, not a design: an item with neither id lands
  # on `agent::inbox`, one shared run for the whole node. See
  # `SalixAnalytics.EventArchive.Sequence`.
  defp stream_for(%{boundary: :delivery, agent_id: agent_id}),
    do: Sequence.agent_stream(agent_id)

  defp stream_for(%{session_id: session_id}) when is_binary(session_id) and session_id != "",
    do: Sequence.session_stream(session_id)

  defp stream_for(%{agent_id: agent_id}), do: Sequence.agent_stream(agent_id)

  # Redeem a reservation when it is for this stream and this boot, otherwise
  # allocate fresh. A mismatch is not a reason to refuse the item: writing it at
  # a fresh position leaves the reserved one unfilled, which is the honest
  # outcome, since something did go missing. Whether that shows up in `verify`
  # depends on where it falls — reportable if a later item lands on the stream,
  # invisible if nothing does.
  defp position(fact) do
    stream = stream_for(fact)
    writer = Sequence.writer()

    case fact[:reservation] do
      %{stream: ^stream, writer: ^writer, seq: seq} when is_integer(seq) -> {stream, seq}
      _other -> {stream, Sequence.next(stream)}
    end
  end

  defp attrs(fact, stream, seq) do
    %{
      stream: stream,
      writer: Sequence.writer(),
      seq: seq,
      boundary: fact.boundary,
      direction: fact.direction,
      tenant_id: fact[:tenant_id],
      agent_id: fact[:agent_id],
      session_id: fact[:session_id],
      round_id: fact[:round_id],
      app_revision: fact[:app_revision],
      ts: fact[:ts]
    }
  end

  defp emit(event, context) do
    :telemetry.execute(
      [:salix_analytics, :event_archive, event],
      %{count: 1},
      %{boundary: context[:boundary], stream: context[:stream]}
    )
  rescue
    _ -> :ok
  end
end
