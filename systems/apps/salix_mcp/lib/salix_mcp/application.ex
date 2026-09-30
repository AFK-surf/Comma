defmodule SalixMCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SalixMCP.ConnectionRegistry},
      {Task.Supervisor, name: SalixMCP.TaskSupervisor},
      {DynamicSupervisor, name: SalixMCP.ConnectionSupervisor, strategy: :one_for_one},
      SalixMCP.Builtins
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SalixMCP.Supervisor)
  end
end
