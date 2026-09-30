defmodule BillingCore.Metering.PendingChargeWorker do
  @moduledoc """
  Periodically retries pending meter charges after pricing or normalization fixes.
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000
  @default_limit 250
  @default_stuck_sweep_threshold 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def run_once(opts \\ []) do
    BillingCore.Metering.PricingBackfill.run(%{
      repo: opts[:repo] || Application.fetch_env!(:billing_core, :repo),
      sql_runner: opts[:sql_runner] || Ecto.Adapters.SQL,
      now: opts[:now] || DateTime.utc_now(),
      limit: opts[:limit] || @default_limit
    })
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, config(:enabled, true)),
      interval_ms: Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms)),
      limit: Keyword.get(opts, :limit, config(:limit, @default_limit)),
      stuck_sweep_threshold:
        Keyword.get(
          opts,
          :stuck_sweep_threshold,
          config(:stuck_sweep_threshold, @default_stuck_sweep_threshold)
        ),
      stuck_sweeps: 0,
      run: Keyword.get(opts, :run, &run_once/1)
    }

    if state.enabled do
      Process.send_after(self(), :run, state.interval_ms)
    else
      Logger.warning("billing pending charge worker disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:run, state) do
    state = run_safely(state)
    if state.enabled, do: Process.send_after(self(), :run, state.interval_ms)
    {:noreply, state}
  end

  defp run_safely(state) do
    started = System.monotonic_time()

    case state.run.(limit: state.limit) do
      %{charged_count: charged, pending_count: pending, expired_count: expired} = summary ->
        # Always emit the sweep summary so a stuck sweep (selected > 0 but
        # charged == 0 every cycle) is observable/alertable.
        Logger.info(
          "billing pending charge replay completed" <>
            " selected=#{Map.get(summary, :selected_count, 0)}" <>
            " charged=#{charged}" <>
            " backed_off=#{Map.get(summary, :backed_off_count, 0)}" <>
            " failed=#{Map.get(summary, :failed_count, 0)}" <>
            " pending=#{pending} expired=#{expired}"
        )

        BillingTelemetry.emit_operation(
          :pending_charge,
          "system",
          :ok,
          System.monotonic_time() - started
        )

        update_stuck_sweeps(state, summary)

      {:error, reason} ->
        BillingTelemetry.emit_operation(
          :pending_charge,
          "system",
          :error,
          System.monotonic_time() - started
        )

        Logger.warning("billing pending charge replay failed: #{inspect(reason)}")
        %{state | stuck_sweeps: 0}
    end
  rescue
    exception ->
      Logger.warning("billing pending charge replay crashed: #{Exception.message(exception)}")
      %{state | stuck_sweeps: 0}
  catch
    kind, reason ->
      Logger.warning("billing pending charge replay failed: #{inspect({kind, reason})}")
      %{state | stuck_sweeps: 0}
  end

  defp update_stuck_sweeps(state, summary) do
    no_progress? =
      Map.get(summary, :selected_count, 0) > 0 and
        Map.get(summary, :charged_count, 0) + Map.get(summary, :expired_count, 0) == 0

    stuck_sweeps = if no_progress?, do: state.stuck_sweeps + 1, else: 0

    if stuck_sweeps >= state.stuck_sweep_threshold do
      Logger.warning(
        "billing pending charge backlog made no progress" <>
          " sweeps=#{stuck_sweeps}" <>
          " selected=#{Map.get(summary, :selected_count, 0)}" <>
          " pending=#{Map.get(summary, :pending_count, 0)}"
      )

      %{state | stuck_sweeps: 0}
    else
      %{state | stuck_sweeps: stuck_sweeps}
    end
  end

  defp config(key, default) do
    :billing_core
    |> Application.get_env(:pending_charge_worker, [])
    |> Keyword.get(key, default)
  end
end
