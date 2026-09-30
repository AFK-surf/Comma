defmodule SalixStore.AgentVMMSettlementSweeper do
  @moduledoc """
  Bounded backstop for Agent VMM commands left incomplete across connection loss.

  The command row is the durable settlement obligation. Expiry and
  `(status, next_attempt_at, id)` due indexes select fixed Command owner-row pages before any
  allocation validation; each pass therefore performs at most one point
  validation per selected release and never scans Workloads or allocations.
  """

  use GenServer

  alias SalixStore.AgentVMM

  @batch_size 32
  @default_interval_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    schedule(0)
    {:ok, Keyword.get(opts, :interval_ms, @default_interval_ms)}
  end

  @impl true
  def handle_info(:sweep, interval_ms) do
    delay =
      case AgentVMM.settle_expired_commands(@batch_size) do
        {:ok, %{more?: true}} -> 0
        _ -> interval_ms
      end

    schedule(delay)
    {:noreply, interval_ms}
  end

  defp schedule(delay), do: Process.send_after(self(), :sweep, delay)
end
