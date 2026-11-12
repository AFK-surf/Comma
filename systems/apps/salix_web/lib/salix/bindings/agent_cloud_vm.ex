defmodule Salix.Bindings.AgentCloudVM do
  @moduledoc false

  @behaviour SalixAgent.CloudVM

  # A Group can have a Cloud VM on its Agent VMM Host, or a Cloudflare one
  # that the Tenant's Cloudflare configuration makes; a router-only (guest)
  # Tenant has none.
  @impl true
  def available?(tenant_id, group_id) do
    not SalixStore.TenantProfiles.router_only?(tenant_id) and
      SalixWeb.CloudVM.available?(tenant_id, group_id, "cloudflare")
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
