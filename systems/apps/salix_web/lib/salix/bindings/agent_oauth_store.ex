defmodule Salix.Bindings.AgentOAuthStore do
  @moduledoc false

  @behaviour SalixAgent.OAuthStore

  @impl true
  def agent_oauth_context(agent_id), do: SalixWeb.OAuthStore.agent_oauth_context(agent_id)

  @impl true
  def provider_app(tenant, provider), do: SalixWeb.OAuthStore.provider_app(tenant, provider)

  @impl true
  def bindings_for_group(group_id), do: SalixWeb.OAuthStore.bindings_for_group(group_id)

  @impl true
  def public_base_url, do: SalixWeb.OAuthStore.public_base_url()

  @impl true
  def delete_binding(tenant, group_id, binding_id),
    do: SalixWeb.OAuthStore.delete_binding(tenant, group_id, binding_id)
end
