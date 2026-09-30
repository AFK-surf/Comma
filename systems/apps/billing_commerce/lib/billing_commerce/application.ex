defmodule BillingCommerce.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:billing_commerce, :cycle_scheduler_enabled, false) do
        opts = Application.get_env(:billing_commerce, :cycle_scheduler, [])
        [{BillingCommerce.CycleScheduler, opts}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: BillingCommerce.Supervisor)
  end
end
