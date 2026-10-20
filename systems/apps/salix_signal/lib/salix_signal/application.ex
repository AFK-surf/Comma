defmodule SalixSignal.Application do
  @moduledoc """
  Signal runtime supervision.

  `SalixSignal.CallMedia.Supervisor` runs one
  `SalixSignal.CallMedia.Connection` per 1:1 call media connection on the
  node that holds the call. `SalixSignal.CallSignaling.Supervisor` runs one
  `SalixSignal.CallSignaling.Call` per 1:1 call attempt on this node.
  `SalixSignal.GroupCall.Supervisor` runs one `SalixSignal.GroupCall.Session`
  per joined group call, registered in `SalixSignal.GroupCall.Registry` by
  account and group; its short tasks (peeks, signaling sends) run under
  `SalixSignal.GroupCall.TaskSupervisor`.

  `SalixSignal.Account.Supervisor` runs one `SalixSignal.Account.Server`
  per Signal account whose ring owner is this node, registered in
  `SalixSignal.Account.Registry` by account ID. `SalixSignal.Account.Keeper`
  starts and stops them as the ring changes (`config :salix_signal,
  :account_keeper`, default true).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {SystemsRuntime.DynamicSupervisor,
       name: SalixSignal.CallMedia.Supervisor, strategy: :one_for_one},
      {SystemsRuntime.DynamicSupervisor,
       name: SalixSignal.CallSignaling.Supervisor, strategy: :one_for_one},
      {SystemsRuntime.Registry, keys: :unique, name: SalixSignal.GroupCall.Registry},
      {SystemsRuntime.TaskSupervisor, name: SalixSignal.GroupCall.TaskSupervisor},
      {SystemsRuntime.DynamicSupervisor,
       name: SalixSignal.GroupCall.Supervisor, strategy: :one_for_one},
      {SystemsRuntime.Registry, keys: :unique, name: SalixSignal.Account.Registry},
      {SystemsRuntime.DynamicSupervisor,
       name: SalixSignal.Account.Supervisor, strategy: :one_for_one}
    ]

    children =
      if SystemsRuntime.get_env(:salix_signal, :account_keeper, true),
        do: children ++ [SalixSignal.Account.Keeper],
        else: children

    SystemsRuntime.Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SalixSignal.Supervisor
    )
  end
end
