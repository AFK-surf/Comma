defmodule SystemsObservability.Runtime do
  @moduledoc false
  use SystemsRuntime.Server

  require Logger

  @retry_ms 5_000

  def start_link(_opts), do: SystemsRuntime.Server.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, start_runtime()}
  end

  @impl true
  def handle_info(:retry, nil), do: {:noreply, start_runtime()}

  def handle_info({:EXIT, pid, _reason}, pid) do
    unavailable()
    {:noreply, nil}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, pid) when is_pid(pid) do
    if Process.alive?(pid), do: SystemsRuntime.Supervisor.stop(pid, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_runtime do
    metrics = SystemsObservability.Metrics.enabled_metrics(enabled_subsystems())

    {histograms, core_metrics} =
      Enum.split_with(metrics, &match?(%Telemetry.Metrics.Distribution{}, &1))

    children = [
      {Bandit,
       plug: SystemsObservability.Router,
       scheme: :http,
       port: Application.get_env(:systems_observability, :port, 9568),
       http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false],
       thousand_island_options: [num_acceptors: 2]},
      %{
        id: SystemsObservability.Prometheus,
        start:
          {__MODULE__, :start_prometheus,
           [[name: SystemsObservability.Prometheus, metrics: core_metrics, start_async: false]]}
      },
      {SystemsObservability.HistogramReporter,
       name: SystemsObservability.Histograms, metrics: histograms},
      SystemsObservability.EctoHandler
    ]

    case SystemsRuntime.Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} ->
        pid

      {:error, _reason} ->
        unavailable()
        nil
    end
  rescue
    _exception ->
      unavailable()
      nil
  catch
    _kind, _reason ->
      unavailable()
      nil
  end

  @doc false
  # The Prometheus reporter makes a counter's series at its first event. A
  # series the metric declares in `zero_series` is written at 0 into the
  # reporter's table when it starts, keyed as its counter handler keys it.
  def start_prometheus(opts) do
    with {:ok, pid} <- TelemetryMetricsPrometheus.Core.start_link(opts) do
      %{aggregates_table_id: table} =
        TelemetryMetricsPrometheus.Core.Registry.config(Keyword.fetch!(opts, :name))

      for metric <- Keyword.fetch!(opts, :metrics),
          labels <- Keyword.get(metric.reporter_options, :zero_series, []) do
        SystemsRuntime.ETS.insert_new(table, {{metric.name, labels}, 0})
      end

      {:ok, pid}
    end
  end

  defp unavailable do
    Logger.warning("systems_observability.runtime.unavailable", error_class: "internal")
    SystemsClock.send_after(self(), :retry, @retry_ms)
    :ok
  end

  defp enabled_subsystems do
    Application.get_env(:comma, :enabled_subsystems, [
      :alert_router,
      :salix,
      :comma_product,
      :bridge_for_teams
    ])
  end
end
