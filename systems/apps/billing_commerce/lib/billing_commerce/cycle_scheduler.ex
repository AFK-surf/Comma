defmodule BillingCommerce.CycleScheduler do
  @moduledoc false

  use GenServer

  alias BillingCommerce.Subscriptions

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      limit: Keyword.get(opts, :limit, 50)
    }

    schedule(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:run, state) do
    _ = Subscriptions.run_due_cycles(%{limit: state.limit})
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :run, interval_ms)
end
