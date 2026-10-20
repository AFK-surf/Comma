defmodule SalixCalendar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {SystemsRuntime.Registry,
       keys: :unique, name: SalixCalendar.Registry, partitions: System.schedulers_online()},
      {SystemsRuntime.DynamicSupervisor, name: SalixCalendar.FleetSupervisor, strategy: :one_for_one}
    ]

    SystemsRuntime.Supervisor.start_link(children, strategy: :rest_for_one, name: SalixCalendar.Supervisor)
  end
end
