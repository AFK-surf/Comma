defmodule SalixStore.SlackRouterThreadParticipationSweeper do
  @moduledoc """
  Hourly bounded cleanup for expired Slack Router participation-status rows.

  Every Pod may run a pass. `FOR UPDATE SKIP LOCKED` partitions concurrent
  work, while each pass is capped at a fixed row count. Expiry is enforced on
  the read path, so cleanup delay or failure cannot grant admission.
  """

  use GenServer

  require Logger

  alias SalixStore.SlackRouterThreadParticipations

  @interval_ms :timer.hours(1)
  @batch_size 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cleanup(&SlackRouterThreadParticipations.cleanup_expired/1, "canonical")
    cleanup(&SlackRouterThreadParticipations.cleanup_legacy_expired/1, "legacy")

    schedule()
    {:noreply, state}
  end

  defp cleanup(fun, table_role) do
    case fun.(@batch_size) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Slack Router #{table_role} participation-status cleanup failed: #{inspect(reason)}"
        )
    end
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval_ms)
end
