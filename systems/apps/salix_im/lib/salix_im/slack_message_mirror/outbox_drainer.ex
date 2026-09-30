defmodule SalixIM.SlackMessageMirror.OutboxDrainer do
  @moduledoc """
  Moves Slack mirror rows from `SalixStore.SlackMirrorOutbox` into ClickHouse.

  One runs per Pod. Each tick claims the oldest batch, writes it through
  `SalixIM.SlackMessageMirror.write_batch/1`, and on `:ok` deletes the rows.
  On any failure the rows are deferred with a growing backoff and their
  attempt count; nothing here ever discards a row. Two Pods draining at once
  take different rows because the claim is `SKIP LOCKED`, and a Pod that dies
  mid-batch leaves its rows to be claimed again when the lease expires — at
  worst a duplicate insert, which the destination absorbs.

  The process holds no state worth keeping. Every tick reads the table afresh,
  so killing it or running it on every Pod at once changes throughput and
  nothing else. The drain runs in a monitored Task so a write that raises
  reschedules instead of taking the drainer with it.

  ## What bounds this

  One batch of `batch_size` rows per tick per Pod, and an immediate next tick
  only while batches come back full. A backlog therefore drains at
  `batch_size` rows per ClickHouse round trip and an idle outbox costs one
  cheap claim and one primary-key probe per `drain_ms`.

  Model: `tla/salix/SlackMirrorOutbox.tla`.
  """

  use GenServer

  require Logger

  alias SalixIM.SlackMessageMirror
  alias SalixStore.SlackMirrorOutbox

  @default_drain_ms 2_000
  @default_batch_size 200
  @default_claim_ttl_ms 60_000
  @default_max_backoff_ms 300_000
  @failure_backoff_ms 30_000

  @task_supervisor __MODULE__.Tasks

  def child_spec(opts) do
    %{id: opts[:name] || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Name of the supervisor that owns the drain tasks."
  @spec task_supervisor_name() :: atom()
  def task_supervisor_name, do: @task_supervisor

  @impl true
  def init(opts) do
    Process.send_after(self(), :tick, setting(opts, :start_delay_ms, 1_000))
    {:ok, %{opts: opts, task: nil}}
  end

  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    opts = state.opts

    task =
      Task.Supervisor.async_nolink(task_supervisor(state), fn -> drain_once(opts) end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :tick, next_delay(state.opts, result))
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("slack mirror outbox drain crashed: #{inspect(reason)}")
    Process.send_after(self(), :tick, @failure_backoff_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Claims and writes one batch. `:more` when the batch was full, `:idle` when
  the outbox had nothing claimable, `{:error, reason}` when the write failed
  and the rows were deferred.
  """
  @spec drain_once(keyword()) :: :more | :idle | {:error, term()}
  def drain_once(opts \\ []) do
    outbox = opts[:outbox] || SlackMirrorOutbox
    writer = opts[:writer] || SlackMessageMirror
    batch_size = setting(opts, :batch_size, @default_batch_size)

    if not writer_enabled?(writer) do
      :idle
    else
      report_lag(outbox)

      case outbox.claim(batch_size, setting(opts, :claim_ttl_ms, @default_claim_ttl_ms)) do
        {:ok, []} ->
          drain_source_writes(outbox, writer, batch_size, opts)

        {:ok, entries} ->
          ids = Enum.map(entries, & &1.id)

          messages =
            for entry <- entries, entry.kind == "message" do
              entry.row
              |> Map.put("_semantic_context", Map.get(entry, :context, %{}))
              |> Map.put("_mirror_outbox_id", entry.id)
            end

          reactions = for entry <- entries, entry.kind == "reaction", do: entry.row
          pins = for entry <- entries, entry.kind == "pin", do: entry.row
          metadata = for entry <- entries, entry.kind == "metadata", do: entry.row

          case write_claimed(writer, messages, reactions, pins, metadata) do
            :ok ->
              # A delete that fails leaves the rows to be written again after the
              # claim expires. That is a duplicate insert, not a loss.
              _ = outbox.delete(ids)
              emit(:drained, length(ids))
              if length(entries) >= batch_size, do: :more, else: :idle

            {:error, reason} ->
              attempts = entries |> Enum.map(& &1.attempts) |> Enum.max()
              _ = outbox.defer(ids, reason, backoff(attempts, opts))
              emit(:failed, length(ids))

              Logger.error(
                "slack mirror outbox write failed, #{length(ids)} rows deferred: #{inspect(reason)}"
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("slack mirror outbox claim failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp drain_source_writes(outbox, writer, batch_size, opts) do
    case outbox.claim_source_writes(
           batch_size,
           setting(opts, :claim_ttl_ms, @default_claim_ttl_ms)
         ) do
      {:ok, []} ->
        :idle

      {:ok, entries} ->
        ids = Enum.map(entries, & &1.id)

        rows =
          Enum.map(entries, fn entry ->
            entry.row
            |> Map.put("_semantic_context", entry.context)
            |> Map.put("_mirror_outbox_id", entry.id)
          end)

        # Source replay never calls the live event-trigger seam, including
        # after a crash or rollback. Old binaries cannot claim this table.
        case writer.write_batch(rows) do
          :ok ->
            _ = outbox.delete_source_writes(ids)
            emit(:drained, length(ids))
            if length(entries) >= batch_size, do: :more, else: :idle

          {:error, reason} ->
            attempts = entries |> Enum.map(& &1.attempts) |> Enum.max()
            _ = outbox.defer_source_writes(ids, reason, backoff(attempts, opts))
            emit(:failed, length(ids))
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp writer_enabled?(writer) do
    function_exported?(writer, :enabled?, 0) == false or writer.enabled?()
  end

  defp write_claimed(writer, messages, reactions, pins, metadata) do
    with :ok <- write_if_present(writer, :write_batch, messages),
         :ok <- write_if_present(writer, :write_event_triggers, event_triggers(messages)),
         :ok <- write_if_present(writer, :write_reaction_batch, reactions),
         :ok <- write_if_present(writer, :write_pin_batch, pins) do
      write_if_present(writer, :write_metadata_batch, metadata)
    end
  end

  defp event_triggers(messages) do
    messages
    |> Enum.reject(&(&1["ingest_source"] == "backfill"))
    |> Enum.map(fn row ->
      Map.take(row, ~w(event_date tenant_id workspace_id channel_id message_ts_us version))
    end)
  end

  defp write_if_present(_writer, _function, []), do: :ok
  defp write_if_present(writer, function, rows), do: apply(writer, function, [rows])

  # Doubles per attempt from the tick interval, so a poisoned row settles at
  # one failing batch per `max_backoff_ms` while a ClickHouse outage is retried
  # often enough that recovery is noticed within that same bound.
  defp backoff(attempts, opts) do
    base = setting(opts, :drain_ms, @default_drain_ms)

    min(
      base * Bitwise.bsl(1, min(attempts, 20)),
      setting(opts, :max_backoff_ms, @default_max_backoff_ms)
    )
  end

  defp next_delay(_opts, :more), do: 0
  defp next_delay(opts, :idle), do: setting(opts, :drain_ms, @default_drain_ms)
  defp next_delay(opts, {:error, _reason}), do: setting(opts, :drain_ms, @default_drain_ms)

  defp report_lag(outbox) do
    case outbox.oldest_pending_age_ms() do
      {:ok, age_ms} ->
        :telemetry.execute(
          [:salix, :slack_mirror, :outbox, :lag],
          %{oldest_age_seconds: (age_ms || 0) / 1_000},
          %{}
        )

      {:error, _reason} ->
        :ok
    end
  rescue
    _exception -> :ok
  end

  # Labels stay finite and carry no tenant, workspace, channel or content.
  defp emit(outcome, count) do
    :telemetry.execute([:salix, :slack_mirror, :outbox, :batch], %{count: count}, %{
      outcome: outcome
    })

    :ok
  rescue
    _exception -> :ok
  end

  defp task_supervisor(state), do: state.opts[:task_supervisor] || @task_supervisor

  defp setting(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> config(key, default)
    end
  end

  defp config(key, default) do
    :salix_im
    |> Application.get_env(:slack_message_mirror_outbox_drainer, [])
    |> Keyword.get(key, default)
  end
end
