defmodule BillingCommerce.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if SystemsRuntime.get_env(:billing_commerce, :cycle_scheduler_enabled, false) do
        opts = SystemsRuntime.get_env(:billing_commerce, :cycle_scheduler, [])
        [{BillingCommerce.CycleScheduler, opts}]
      else
        []
      end

    SystemsRuntime.Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BillingCommerce.Supervisor
    )
  end
end
