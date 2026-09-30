defmodule Salix.Control do
  @moduledoc """
  Tenant/group control-plane public API.
  """

  alias Salix.Control.{
    GroupMembers,
    Groups,
    InitialAgentSeeds,
    OAuthApps,
    OAuthBindings,
    Plugins,
    Tenants
  }

  defdelegate list_tenants, to: Tenants, as: :list
  defdelegate get_tenant(id), to: Tenants, as: :get
  defdelegate create_tenant(attrs), to: Tenants, as: :create
  defdelegate create_preallocated_tenant(attrs, tenant_id), to: Tenants, as: :create_preallocated
  defdelegate update_tenant(id, attrs), to: Tenants, as: :update

  defdelegate list_groups(tenant_id), to: Groups, as: :list
  defdelegate get_group(id, tenant_id), to: Groups, as: :get
  defdelegate create_group(attrs, tenant_id), to: Groups, as: :create

  defdelegate create_preallocated_group(attrs, tenant_id, group_id),
    to: Groups,
    as: :create_preallocated

  defdelegate update_group(id, attrs, tenant_id), to: Groups, as: :update
  defdelegate delete_group(id, tenant_id), to: Groups, as: :delete

  defdelegate list_group_members(group_id), to: GroupMembers, as: :list

  defdelegate list_initial_agent_seeds(tenant_id), to: InitialAgentSeeds, as: :list
  defdelegate get_initial_agent_seed(slot, tenant_id), to: InitialAgentSeeds, as: :get
  defdelegate put_initial_agent_seed(slot, attrs, tenant_id), to: InitialAgentSeeds, as: :put
  defdelegate delete_initial_agent_seed(slot, tenant_id), to: InitialAgentSeeds, as: :delete

  defdelegate list_oauth_apps(tenant_id), to: OAuthApps, as: :list
  defdelegate get_oauth_app(tenant_id, provider), to: OAuthApps, as: :get
  defdelegate put_oauth_app(tenant_id, provider, attrs), to: OAuthApps, as: :put
  defdelegate delete_oauth_app(tenant_id, provider), to: OAuthApps, as: :delete

  defdelegate list_oauth_bindings(group_id), to: OAuthBindings, as: :list
  defdelegate get_oauth_binding(group_id, binding_id), to: OAuthBindings, as: :get

  defdelegate put_oauth_binding(tenant_id, group_id, provider, alias_name, connection_id),
    to: OAuthBindings,
    as: :put

  defdelegate update_oauth_binding(group_id, binding_id, attrs), to: OAuthBindings, as: :update
  defdelegate delete_oauth_binding(group_id, binding_id), to: OAuthBindings, as: :delete

  defdelegate list_plugins(tenant_id, group_id), to: Plugins, as: :list_definitions
  defdelegate get_plugin(tenant_id, group_id, plugin_id), to: Plugins, as: :get_definition
  defdelegate create_plugin(tenant_id, group_id, attrs), to: Plugins, as: :create_definition

  defdelegate update_plugin(tenant_id, group_id, plugin_id, attrs),
    to: Plugins,
    as: :update_definition

  defdelegate put_plugin_refs(tenant_id, group_id, plugin_id, attrs), to: Plugins, as: :put_refs

  defdelegate list_plugin_enablements(tenant_id, group_id),
    to: Plugins,
    as: :list_group_enablements

  defdelegate enable_plugin(tenant_id, group_id, plugin_id), to: Plugins, as: :enable_group
  defdelegate disable_plugin(tenant_id, group_id, plugin_id), to: Plugins, as: :disable_group
  defdelegate runtime_plugin_projection(attrs), to: Plugins, as: :runtime_projection
end
