defmodule SalixAnalytics.EventArchive.Worker do
  @moduledoc """
  Batches sealed archive rows into ClickHouse inserts.

  Everything this process holds is ALREADY SEALED — `SalixAnalytics.EventArchive`
  encrypts in the caller. Its mailbox, buffer, and any crash dump therefore hold
  ciphertext plus plaintext headers, never payloads.

  ## The buffer is ETS, not this process's mailbox

  `enqueue/2` does not call this GenServer at all. It writes one ETS row and
  returns.

  Replying-before-flushing is not sufficient and was measured not to be: a
  GenServer is single-threaded, so while it performs a slow insert every
  *subsequent* caller sits in its mailbox until the client timeout — 1000ms per
  archived boundary, ~6 per round. Only taking the worker off the enqueue path
  entirely makes "the loop never waits on the archive" true.

  So the loop's cost per item is an `:ets.insert` plus a counter bump. This
  process drains that buffer on its own timer.

  ## Overflow drops, and says so

  When the buffer is full or an insert fails, the items are DROPPED and counted.
  There is no local-disk spill: an archive that writes to the node's disk to
  survive a storage outage trades a bounded, observable loss for an unbounded
  one that ends in a full disk, and it puts a per-tenant session index on every
  pod. Dropping is the honest failure, and `mix salix.archive.verify` reports
  the resulting gap where it can — see `Completeness` for what it can and
  cannot see.

  ## The layout gate

  Before the first insert this process probes the table's ENGINE, partition key
  and sorting key. The migration is `CREATE TABLE IF NOT EXISTS`, so a
  precreated table with the right column names and a different sorting key
  satisfies it — and on a ReplacingMergeTree a wrong sorting key is not a
  failed query, it is the engine merging away rows it believes are duplicates.
  Writing into that destroys archived events with no error anywhere.

  So a CONFIRMED mismatch stops the writes and says so on every flush. An
  unreachable server does not: that is an outage, not a wrong table, and
  refusing to write through an outage would turn a recoverable condition into a
  permanent one. The probe repeats until it answers `:ok`, so a corrected table
  recovers without a restart.

  ## Batching, and why it still exists

  Under object storage, batching avoided per-item PUT cost and kept a segment
  from spanning two tenants or two days. Neither applies to a table insert — but
  batching matters MORE here, not less: ClickHouse creates a part per insert, and
  a stream of single-row inserts at loop frequency drives the merge scheduler
  into the ground. The grouping is gone; the batching is load-bearing.
  """

  use GenServer

  require Logger

  alias SalixAnalytics.EventArchive.Sink

  @default_batch_size 200
  @default_batch_bytes 4 * 1024 * 1024
  @default_flush_ms 2_000
  @default_max_buffer 5_000

  @buffer __MODULE__.Buffer
  @index_key :__next_index__

  def child_spec(opts) do
    %{
      id: opts[:name] || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # A slow ClickHouse at shutdown must not get the buffer brutally killed
      # inside the default 5s budget.
      shutdown: 30_000
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Async path. Never calls this process, so a stalled ClickHouse cannot block the
  loop at any archived boundary.
  """
  @spec enqueue(map(), keyword()) :: :ok | {:error, term()}
  def enqueue(sealed, opts \\ []) do
    table = opts[:table] || @buffer

    ensure_buffer(table)

    if buffered(table) >= max_buffer(opts) do
      {:error, :buffer_full}
    else
      index = :ets.update_counter(table, @index_key, {2, 1}, {@index_key, 0})
      :ets.insert(table, {index, sealed})

      # Nudge the worker once the batch threshold is crossed, so a burst does
      # not sit until the next timer tick. A CAST, never a call: it returns
      # immediately and cannot be blocked by a slow flush already in progress.
      if rem(index, batch_size(opts)) == 0 do
        GenServer.cast(opts[:server] || __MODULE__, :flush)
      end

      :ok
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc "Flush everything buffered. Used by tests and graceful shutdown."
  @spec flush(keyword()) :: :ok
  def flush(opts \\ []) do
    GenServer.call(opts[:server] || __MODULE__, :flush, opts[:timeout] || 30_000)
  catch
    :exit, _ -> :ok
  end

  @doc false
  def ensure_buffer(table \\ @buffer) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :ordered_set, {:write_concurrency, true}])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp buffered(table) do
    # The index row is not an item.
    max(:ets.info(table, :size) - 1, 0)
  end

  # These are properties of the BUFFER, not of the worker process, because the
  # enqueue path no longer talks to the worker. Tests set them through
  # application config like production does.
  defp batch_size(opts) do
    opts[:batch_size] ||
      :salix_analytics
      |> Application.get_env(:event_archive, [])
      |> Keyword.get(:batch_size, @default_batch_size)
  end

  defp max_buffer(opts) do
    opts[:max_buffer] ||
      :salix_analytics
      |> Application.get_env(:event_archive, [])
      |> Keyword.get(:max_buffer, @default_max_buffer)
  end

  defp take_buffer(table) do
    items =
      :ets.select(table, [{{:"$1", :"$2"}, [{:is_integer, :"$1"}], [{{:"$1", :"$2"}}]}])
      |> Enum.sort_by(&elem(&1, 0))

    Enum.each(items, fn {index, _} -> :ets.delete(table, index) end)
    Enum.map(items, &elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:salix_analytics, :event_archive, [])

    Process.flag(:trap_exit, true)
    table = opts[:table] || @buffer
    ensure_buffer(table)

    # Arm the periodic flush immediately. Without this the timer only ever
    # existed as a side effect of a flush that had already happened, so a
    # deployment quiet enough never to cross `batch_size` buffered its items in
    # ETS and wrote NOTHING until shutdown. Low traffic is exactly when an
    # archive looks healthiest and is least likely to be checked.
    {:ok,
     %{
       table: table,
       timer: nil,
       layout: :unchecked,
       writer: opts[:writer] || Keyword.get(config, :writer, Sink),
       batch_size: opts[:batch_size] || Keyword.get(config, :batch_size, @default_batch_size),
       batch_bytes: opts[:batch_bytes] || Keyword.get(config, :batch_bytes, @default_batch_bytes),
       flush_ms: opts[:flush_ms] || Keyword.get(config, :flush_ms, @default_flush_ms),
       max_buffer: opts[:max_buffer] || Keyword.get(config, :max_buffer, @default_max_buffer)
     }, {:continue, :arm_timer}}
  end

  @impl true
  def handle_continue(:arm_timer, state), do: {:noreply, arm_timer(state)}

  @impl true
  def handle_cast(:flush, state), do: {:noreply, flush_all(state)}

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_all(state)}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_all(%{state | timer: nil})}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_all(state)
    :ok
  end

  defp flush_all(state) do
    state = check_layout(state)
    rows = state.table |> take_buffer() |> Enum.map(& &1.row)

    case state.layout do
      :mismatch -> refuse(rows)
      _usable -> rows |> chunk_by_bytes(state.batch_bytes) |> Enum.each(&write(state.writer, &1))
    end

    state |> cancel_timer() |> arm_timer()
  end

  # Only the real sink has a layout to check, and only a CONFIRMED mismatch
  # latches. `:archive_table_unavailable` is an outage — retried on the next
  # flush, never a reason to stop writing.
  defp check_layout(%{layout: :ok} = state), do: state
  defp check_layout(%{writer: writer} = state) when writer != Sink, do: state

  defp check_layout(state) do
    case Sink.readiness() do
      :ok ->
        if state.layout == :mismatch,
          do: Logger.info("event archive table layout is correct again; resuming writes")

        %{state | layout: :ok}

      {:error, {:archive_table_layout_mismatch, table}} ->
        Logger.error(
          "event archive REFUSING to write: #{table} exists with the wrong engine, " <>
            "partition key or sorting key. A ReplacingMergeTree on the wrong sorting key " <>
            "merges away rows it believes are duplicates, so writing would destroy " <>
            "archived events silently. Fix the table; writes resume on their own."
        )

        %{state | layout: :mismatch}

      {:error, _unavailable} ->
        # Do not latch. The server is unreachable, which says nothing about the
        # table, and refusing forever over one outage is worse than retrying.
        state
    end
  rescue
    _exception -> state
  end

  defp refuse([]), do: :ok

  defp refuse(rows) do
    :telemetry.execute(
      [:salix_analytics, :event_archive, :lost],
      %{count: length(rows)},
      %{reason: :table_layout_mismatch}
    )

    :ok
  end

  # ClickHouse rejects an over-large HTTP body outright, and a rejected insert
  # loses the WHOLE batch — so one oversized flush would drop everything in it.
  # Splitting on the accumulated byte budget keeps each insert
  # within what the server will accept. A single row larger than the budget
  # still goes on its own, which is the honest outcome: it is either accepted or
  # reported, never silently regrouped into something equally doomed.
  defp chunk_by_bytes([], _budget), do: []

  defp chunk_by_bytes(rows, budget) do
    {batches, last, _} =
      Enum.reduce(rows, {[], [], 0}, fn row, {batches, current, bytes} ->
        size = row_bytes(row)

        if current != [] and bytes + size > budget do
          {[Enum.reverse(current) | batches], [row], size}
        else
          {batches, [row | current], bytes + size}
        end
      end)

    Enum.reverse([Enum.reverse(last) | batches])
  end

  defp row_bytes(row), do: byte_size(row["e"] || "") + 512

  defp arm_timer(%{timer: nil, flush_ms: flush_ms} = state),
    do: %{state | timer: Process.send_after(self(), :flush, flush_ms)}

  defp arm_timer(state), do: state

  # Every flush re-arms, and a flush can be triggered by cast or call as well
  # as by the timer itself — so the old timer must be cleared or each batch
  # threshold crossing leaks one. `info: false` plus the mailbox sweep stops an
  # already-fired timer causing a redundant drain cycle.
  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer, info: false)

    receive do
      :flush -> :ok
    after
      0 -> :ok
    end

    %{state | timer: nil}
  end

  defp write(_writer, []), do: :ok

  defp write(writer, rows) do
    case writer.write(rows) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} = error ->
        Logger.error("event archive insert failed: #{inspect(reason)}")
        lost(rows, :write_error)
        error
    end
  rescue
    exception ->
      # The batch is already out of the buffer, so a raise here loses it just
      # as completely as a returned error — and a malformed ClickHouse URL
      # raises rather than returning. Counting only the error tuple meant this
      # path went by with a log line and no metric, which is exactly the
      # "silent" the archive is not allowed to be.
      Logger.error("event archive insert raised: #{Exception.message(exception)}")
      lost(rows, :write_raised)
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.error("event archive insert exited: #{inspect(kind)}")
      lost(rows, :write_exited)
      {:error, {kind, reason}}
  end

  # Every path that discards a batch goes through here, so the two counters
  # cannot drift apart again. `reason` distinguishes them for an operator
  # without splitting the count.
  defp lost(rows, reason) do
    count = length(rows)

    :telemetry.execute(
      [:salix_analytics, :event_archive, :write_error],
      %{count: count},
      %{reason: reason}
    )

    :telemetry.execute(
      [:salix_analytics, :event_archive, :lost],
      %{count: count},
      %{reason: reason}
    )

    :ok
  rescue
    _exception -> :ok
  end
end
