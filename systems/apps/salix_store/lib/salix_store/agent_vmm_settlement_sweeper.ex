defmodule SalixStore.AgentVMMSettlementSweeper do
  @moduledoc """
  Bounded registration expiry, install handoff expiry, cloud retirement and
  command settlement backstop.
  Each pass handles at most 32 registrations, expired material handoffs and due Commands.
  Retirement uses at most 32 indexed navigation queries and 32 Workload transactions.
  The Workload cursor skips busy owners and revisits them after a full cursor tour.
  """

  use SystemsRuntime.Server

  alias SalixStore.{AgentVMM, AgentVMMInstallations}

  @batch_size 32
  @default_interval_ms 5_000

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    schedule(0)
    {:ok, {Keyword.get(opts, :interval_ms, @default_interval_ms), ""}}
  end

  @impl true
  def handle_info(:sweep, {interval_ms, cursor}) do
    expiry = AgentVMM.expire_authorizations(@batch_size)
    handoffs = AgentVMMInstallations.expire_handoffs(limit: @batch_size)

    {:ok, %{after_id: next_cursor}} =
      SalixStore.ComputeWorkloadDeletion.retire_revoked(@batch_size, cursor)

    settlement = AgentVMM.settle_expired_commands(@batch_size)

    delay =
      if Enum.any?([expiry, handoffs, settlement], &match?({:ok, %{more?: true}}, &1)),
        do: 0,
        else: interval_ms

    schedule(delay)

    {:noreply, {interval_ms, next_cursor}}
  end

  defp schedule(delay), do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, delay)
end
