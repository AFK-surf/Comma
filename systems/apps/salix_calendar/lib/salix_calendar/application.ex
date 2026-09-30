defmodule SalixCalendar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry,
       keys: :unique, name: SalixCalendar.Registry, partitions: System.schedulers_online()},
      {DynamicSupervisor, name: SalixCalendar.FleetSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: SalixCalendar.Supervisor)
  end
end
