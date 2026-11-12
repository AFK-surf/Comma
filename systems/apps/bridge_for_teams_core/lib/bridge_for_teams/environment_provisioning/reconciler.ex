defmodule BridgeForTeams.EnvironmentProvisioning.Reconciler do
  @moduledoc """
  Periodically refreshes the project device projection from the Salix
  registry and records runner status changes.

  The deterministic `drain_once/1` entrypoint is shared by direct callers and
  the GenServer loop, which only schedules that same pass.
  """
  use SystemsRuntime.Server

  require Logger

  alias BridgeForTeams.Environments
  alias BridgeForTeams.Telemetry

  @default_interval_ms 10_000

  @doc "Start the device reconcile worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reconcile one page of project devices.

  Options:

    * `:now` — deterministic clock override for tests.
  """
  @spec drain_once(keyword()) ::
          {:ok, %{required(atom()) => non_neg_integer()}} | {:error, term()}
  def drain_once(opts \\ []) do
    started = SystemsClock.monotonic_time()

    try do
      result = Environments.reconcile_devices(opts)
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"

      Telemetry.emit_operation(
        :environment_provision,
        outcome,
        SystemsClock.monotonic_time() - started
      )

      result
    rescue
      e ->
        Telemetry.emit_operation(
          :environment_provision,
          "error",
          SystemsClock.monotonic_time() - started
        )

        Logger.error("bridge_for_teams.environment_provision_reconcile.failed",
          error_class: "internal"
        )

        {:error, {:exception, e}}
    end
  end

  @impl true
  def init(opts) do
    cfg = SystemsRuntime.get_env(:bridge_for_teams_core, __MODULE__, [])

    state = %{
      interval_ms: opts[:interval_ms] || cfg[:interval_ms] || @default_interval_ms,
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true))
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = drain_once()

    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :drain, interval_ms)
end
