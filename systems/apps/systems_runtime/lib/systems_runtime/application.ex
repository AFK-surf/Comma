defmodule SystemsRuntime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if(Application.get_env(:systems_runtime, :network_guard, false),
        do: [SystemsRuntime.NetworkGuard],
        else: []
      ) ++
        if Application.get_env(:systems_runtime, :scoped_env, false),
          do: [SystemsRuntime.Bindings],
          else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
