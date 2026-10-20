defmodule SalixMCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {SystemsRuntime.Registry, keys: :unique, name: SalixMCP.ConnectionRegistry},
      {SystemsRuntime.TaskSupervisor, name: SalixMCP.TaskSupervisor},
      {SystemsRuntime.DynamicSupervisor, name: SalixMCP.ConnectionSupervisor, strategy: :one_for_one},
      SalixMCP.Builtins
    ]

    SystemsRuntime.Supervisor.start_link(children, strategy: :one_for_one, name: SalixMCP.Supervisor)
  end
end
