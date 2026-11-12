defmodule SalixWeb.CodingSandboxes.FleetMetrics do
  @moduledoc """
  The sandbox fleet gauges: `salix.sandbox.records{state}` and
  `salix.sandbox.starting.oldest.timestamp.seconds` (`Salix.Telemetry`).

  One aggregate read (`SalixStore.CodingSandboxes.fleet/0`), published by
  `SalixWeb.CodingSandboxes` once a minute per node on its check pass. Every
  state gets a value, 0 when no Workload stands there, so a gauge that stood
  at 1 falls back. The oldest `starting` record is published as the time it
  started, or the time of publishing with none: its age is taken at query
  time (`time() - ...`), so it also grows when the check pass stops
  publishing.
  """

  require Logger

  alias SalixStore.CodingSandboxes, as: Store

  @doc "Publish the fleet gauges. `:ok`, or the read's error (the gauges keep their last values)."
  @spec emit(keyword()) :: :ok | {:error, term()}
  def emit(opts \\ []) do
    case Store.fleet() do
      {:ok, rows} ->
        now = Keyword.get(opts, :now, SystemsClock.system_time(:millisecond))
        by_state = Map.new(rows, &{&1.state, &1})

        for state <- Store.states() do
          count =
            case by_state do
              %{^state => %{count: count}} -> count
              _ -> 0
            end

          SystemsRuntime.Telemetry.execute(
            [:salix_web, :sandbox, :fleet, :records],
            %{count: count},
            %{state: state}
          )
        end

        since_ms =
          case by_state do
            %{"starting" => %{oldest_ms: oldest}} when is_integer(oldest) -> min(oldest, now)
            _ -> now
          end

        SystemsRuntime.Telemetry.execute(
          [:salix_web, :sandbox, :fleet, :oldest_starting],
          %{timestamp_seconds: since_ms / 1_000},
          %{}
        )

        :ok

      {:error, reason} ->
        Logger.warning("sandbox fleet metrics skipped: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end
end
