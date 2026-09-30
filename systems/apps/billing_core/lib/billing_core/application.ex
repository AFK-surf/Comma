defmodule BillingCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    repo_children =
      if Application.get_env(:billing_core, :start_repo, false) do
        [BillingCore.Repo]
      else
        []
      end

    children =
      repo_children
      |> maybe_add(
        Application.get_env(:billing_core, :fee_control_server, true),
        BillingCore.FeeControl.Server
      )
      |> maybe_add(
        Application.get_env(:billing_core, :pending_charge_worker_enabled, repo_children != []),
        BillingCore.Metering.PendingChargeWorker
      )

    children =
      maybe_add(
        children,
        Application.get_env(:billing_core, :llm_usage_worker_enabled, true),
        {SalixAnalytics.TypedSinkWorker,
         name: BillingCore.Metering.LLMUsageWorker,
         sink: BillingCore.Metering.LLMUsageSink,
         sink_name: "llm_usage",
         retry_on_error: true}
      )

    Supervisor.start_link(children, strategy: :one_for_one, name: BillingCore.Supervisor)
  end

  defp maybe_add(children, true, child), do: children ++ [child]
  defp maybe_add(children, _enabled, _child), do: children
end
