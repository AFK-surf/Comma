defmodule SalixAgent.SessionHistory.Recent do
  @moduledoc "Four fixed recent-tail lanes, independent of archive maintenance."
  use SystemsRuntime.Server
  alias SalixAgent.SessionHistory.{Worker, Scheduler}

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  def init(_) do
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :tick)
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

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, delay)
    {:noreply, state}
  end
end
