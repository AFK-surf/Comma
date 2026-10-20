defmodule SalixIM.FeishuMessageMirror.OutboxDrainer do
  @moduledoc """
  Moves Feishu mirror rows from `SalixStore.FeishuMirrorOutbox` into ClickHouse.

  One runs per Pod, on the same protocol as
  `SalixIM.SlackMessageMirror.OutboxDrainer`: claim the oldest batch, write it
  through `SalixIM.FeishuMessageMirror.write_batch/1`, delete on `:ok`, and
  otherwise defer the rows with a growing backoff. Nothing here discards a row.
  Two Pods take different rows (`SKIP LOCKED`), and a Pod that dies mid-batch
  leaves its rows to be claimed again when the lease expires.

  Bound: one batch of `batch_size` rows per tick per Pod, and an immediate
  next tick only while batches come back full.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.FeishuMessageMirror
  alias SalixStore.FeishuMirrorOutbox

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
      nil -> SystemsRuntime.Server.start_link(__MODULE__, opts)
      name -> SystemsRuntime.Server.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Name of the supervisor that owns the drain tasks."
  @spec task_supervisor_name() :: atom()
  def task_supervisor_name, do: @task_supervisor

  @impl true
  def init(opts) do
    SystemsClock.send_after(
      SystemsRuntime.Proc.self(),
      :tick,
      setting(opts, :start_delay_ms, 1_000)
    )

    {:ok, %{opts: opts, task: nil}}
  end

  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    opts = state.opts

    task =
      SystemsRuntime.TaskSupervisor.async_nolink(task_supervisor(state), fn ->
        drain_once(opts)
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, next_delay(state.opts, result))
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("feishu mirror outbox drain crashed: #{inspect(reason)}")
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, @failure_backoff_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Claims and writes one batch. `:more` when the batch was full, `:idle` when
  nothing was claimable, `{:error, reason}` when the rows were deferred.
  """
  @spec drain_once(keyword()) :: :more | :idle | {:error, term()}
  def drain_once(opts \\ []) do
    outbox = opts[:outbox] || FeishuMirrorOutbox
    writer = opts[:writer] || FeishuMessageMirror
    batch_size = setting(opts, :batch_size, @default_batch_size)

    if not writer.enabled?() do
      :idle
    else
      report_lag(outbox)

      case outbox.claim(batch_size, setting(opts, :claim_ttl_ms, @default_claim_ttl_ms)) do
        {:ok, []} ->
          :idle

        {:ok, entries} ->
          ids = Enum.map(entries, & &1.id)

          case writer.write_batch(Enum.map(entries, & &1.row)) do
            :ok ->
              # A failed delete leaves the rows to be written again after the
              # claim expires: a duplicate insert, not a loss.
              _ = outbox.delete(ids)
              emit(:drained, length(ids))
              if length(entries) >= batch_size, do: :more, else: :idle

            {:error, reason} ->
              attempts = entries |> Enum.map(& &1.attempts) |> Enum.max()
              _ = outbox.defer(ids, reason, backoff(attempts, opts))
              emit(:failed, length(ids))

              Logger.error(
                "feishu mirror outbox write failed, #{length(ids)} rows deferred: #{inspect(reason)}"
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("feishu mirror outbox claim failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp backoff(attempts, opts) do
    base = setting(opts, :drain_ms, @default_drain_ms)

    min(
      base * Bitwise.bsl(1, min(attempts, 20)),
      setting(opts, :max_backoff_ms, @default_max_backoff_ms)
    )
  end

  defp next_delay(_opts, :more), do: 0
  defp next_delay(opts, _idle_or_error), do: setting(opts, :drain_ms, @default_drain_ms)

  defp report_lag(outbox) do
    case outbox.oldest_pending_age_ms() do
      {:ok, age_ms} ->
        SystemsRuntime.Telemetry.execute(
          [:salix, :feishu_mirror, :outbox, :lag],
          %{oldest_age_seconds: (age_ms || 0) / 1_000},
          %{}
        )

      {:error, _reason} ->
        :ok
    end
  rescue
    _exception -> :ok
  end

  # Labels stay finite and carry no tenant, app, chat or content.
  defp emit(outcome, count) do
    SystemsRuntime.Telemetry.execute(
      [:salix, :feishu_mirror, :outbox, :batch],
      %{count: count},
      %{
        outcome: outcome
      }
    )

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
    |> SystemsRuntime.get_env(:feishu_message_mirror_outbox_drainer, [])
    |> Keyword.get(key, default)
  end
end
