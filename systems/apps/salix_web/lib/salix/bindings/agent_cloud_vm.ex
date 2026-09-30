defmodule Salix.Bindings.AgentCloudVM do
  @moduledoc false

  @behaviour SalixAgent.CloudVM

  @impl true
  def default_provider(tenant_id), do: SalixWeb.CloudVM.default_provider(tenant_id)

  @impl true
  def validate_enabled(tenant_id, provider),
    do: SalixWeb.CloudVM.validate_enabled(tenant_id, provider)

  @impl true
  def validate_group_provider(group_id, provider),
    do: SalixWeb.CloudVM.validate_group_provider(group_id, provider)

  @impl true
  def ensure_provisioning(agent),
    do: SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

  @impl true
  def ensure_runtime(agent, args), do: SalixWeb.CloudVM.Runtimes.request(agent, args)

  @impl true
  def switch_provider(agent, provider),
    do: SalixWeb.ComputeProviders.Cloudflare.switch_provider(agent, provider)

  @impl true
  def attach(%{"vm" => %{"enabled" => true}, "group_id" => group_id} = agent) do
    case SalixWeb.ComputeProviders.Cloudflare.vm_json(group_id) do
      nil -> agent
      vm -> Map.put(agent, "vm", Map.merge(agent["vm"], vm))
    end
  end

  def attach(agent), do: agent

  @impl true
  def mark_agent_settled(agent_id),
    do: SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(agent_id)
end
