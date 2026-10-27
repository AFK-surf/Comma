defmodule Salix.Bindings.AgentCloudVM do
  @moduledoc false

  @behaviour SalixAgent.CloudVM

  # Existing Group VMs keep their provider. New Cloud VMs use Cloudflare. On
  # Cloudflare it needs the Tenant's Cloudflare configuration.
  @impl true
  def validate_group_enabled(tenant_id, group_id) do
    with :ok <- SalixWeb.CloudVM.validate_group_enabled(tenant_id, group_id, "cloudflare"),
         do: SalixWeb.CloudVM.validate_group_provider(group_id, "cloudflare")
  end

  @impl true
  def ensure_provisioning(agent),
    do: SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

  @impl true
  def mark_agent_settled(agent_id),
    do: SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(agent_id)

  @impl true
  def start(agent_id, worker_id, budget_ms),
    do: SalixWeb.CloudVM.Start.run(agent_id, budget_ms, worker_id)
end
