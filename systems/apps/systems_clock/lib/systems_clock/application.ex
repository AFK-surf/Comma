defmodule SystemsClock.Application do
  @moduledoc false
  use Application

  @node_timers Application.compile_env(:systems_clock, :node_timers, false)

  @impl true
  def start(_type, _args) do
    children = if @node_timers, do: [SystemsClock.NodeTimers], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
