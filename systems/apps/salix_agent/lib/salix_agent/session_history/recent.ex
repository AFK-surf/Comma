defmodule SalixAgent.SessionHistory.Recent do
  @moduledoc "Four fixed recent-tail lanes, independent of archive maintenance."
  use GenServer
  alias SalixAgent.SessionHistory.{Worker, Scheduler}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(_) do
    send(self(), :tick)
    {:ok, nil}
  end

  def handle_info(:tick, state) do
    delay =
      case Scheduler.claim() do
        {agent, session} ->
          try do
            Worker.safely("session_history_recent", fn -> Worker.recent(agent, session) end)
          after
            Scheduler.complete()
          end

          0

        nil ->
          25
      end

    Process.send_after(self(), :tick, delay)
    {:noreply, state}
  end
end
