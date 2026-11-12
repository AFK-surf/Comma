defmodule SalixStore.AgentVMMSettlementSweeper do
  @moduledoc """
  Bounded ticket cleanup, explicit revocation retirement, and command settlement.

  Each pass reads at most 32 expired pending tickets, due Commands, and
  in-flight Commands. The command cursor revisits healthy Commands after each
  complete pass. Retirement uses at most 32 indexed queries and 32 Workload
  transactions. It preserves busy owners for a later pass.

  A failed pass keeps its cursors and waits for the normal interval.
  Seven-day credential expiry rejects admission. It does not retire a
  Registration or its Workloads.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixStore.{AgentVMM, AgentVMMRegistrations}

  @batch_size 32
  @default_interval_ms 5_000

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    schedule(0)
    {:ok, {Keyword.get(opts, :interval_ms, @default_interval_ms), "", nil}}
  end

  @impl true
  def handle_info(:sweep, {interval_ms, cursor, command_cursor} = state) do
    {delay, state} =
      try do
        pass(interval_ms, cursor, command_cursor)
      rescue
        error ->
          failed(Exception.message(error), interval_ms, state)
      catch
        :exit, reason ->
          failed(inspect(reason), interval_ms, state)
      end

    schedule(delay)
    {:noreply, state}
  end

  defp pass(interval_ms, cursor, command_cursor) do
    tickets = AgentVMMRegistrations.expire_tickets(limit: @batch_size)

    {:ok, %{after_id: next_cursor}} =
      SalixStore.ComputeWorkloadDeletion.retire_revoked(@batch_size, cursor)

    settlement = AgentVMM.settle_expired_commands(@batch_size)
    disconnected = AgentVMM.settle_disconnected_commands(@batch_size, command_cursor)

    next_command_cursor =
      case disconnected do
        {:ok, %{cursor: next}} -> next
        _ -> command_cursor
      end

    delay =
      if Enum.any?(
           [tickets, settlement, disconnected],
           &match?({:ok, %{more?: true}}, &1)
         ),
         do: 0,
         else: interval_ms

    {delay, {interval_ms, next_cursor, next_command_cursor}}
  end

  defp failed(reason, interval_ms, state) do
    Logger.warning("Agent VMM settlement sweep failed; retrying in #{interval_ms} ms: #{reason}")
    {interval_ms, state}
  end

  defp schedule(delay), do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, delay)
end
