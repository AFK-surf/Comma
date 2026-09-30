defmodule BridgeForTeams.EnvironmentProvisioning.Reconciler do
  @moduledoc """
  Periodically reconciles runner-backed project device provision requests.

  The deterministic `drain_once/1` entrypoint is shared by direct callers and
  the GenServer loop, which only schedules that same pass.
  """
  use GenServer

  require Logger

  alias BridgeForTeams.Environments
  alias BridgeForTeams.Telemetry

  @default_interval_ms 10_000
  @default_limit 50
  @default_attach_timeout_ms 300_000

  @doc "Start the provision-request reconcile worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reconcile active runner-backed provision requests once.

  Options:

    * `:limit` — max active requests to scan.
    * `:attach_timeout_ms` — how long `waiting_for_attach` may wait after its
      last status update before being classified as `connector.attach_timeout`.
    * `:now` — deterministic clock override for tests.
  """
  @spec drain_once(keyword()) ::
          {:ok, %{required(atom()) => non_neg_integer()}} | {:error, term()}
  def drain_once(opts \\ []) do
    started = System.monotonic_time()

    try do
      result = Environments.reconcile_device_provision_requests(opts)
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"
      Telemetry.emit_operation(:environment_provision, outcome, System.monotonic_time() - started)
      result
    rescue
      e ->
        Telemetry.emit_operation(
          :environment_provision,
          "error",
          System.monotonic_time() - started
        )

        Logger.error("bridge_for_teams.environment_provision_reconcile.failed",
          error_class: "internal"
        )

        {:error, {:exception, e}}
    end
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:bridge_for_teams_core, __MODULE__, [])

    state = %{
      interval_ms: opts[:interval_ms] || cfg[:interval_ms] || @default_interval_ms,
      limit: opts[:limit] || cfg[:limit] || @default_limit,
      attach_timeout_ms:
        opts[:attach_timeout_ms] || cfg[:attach_timeout_ms] || @default_attach_timeout_ms,
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true))
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ =
      drain_once(
        limit: state.limit,
        attach_timeout_ms: state.attach_timeout_ms
      )

    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :drain, interval_ms)
end
