defmodule Salix.Bindings.AgentPluginStore do
  @moduledoc false

  @behaviour SalixAgent.PluginStore

  alias Salix.Control.Plugins

  @impl true
  def runtime_projection(attrs), do: Plugins.runtime_projection(attrs)

  @impl true
  def list_definitions(tenant_id, group_id), do: Plugins.list_definitions(tenant_id, group_id)

  @impl true
  def list_raw_definitions(tenant_id, group_id),
    do: Plugins.list_raw_definitions(tenant_id, group_id)

  @impl true
  def get_definition(tenant_id, group_id, plugin_id),
    do: Plugins.get_definition(tenant_id, group_id, plugin_id)

  @impl true
  def create_definition(tenant_id, group_id, attrs),
    do: Plugins.create_definition(tenant_id, group_id, attrs)

  @impl true
  def update_definition(tenant_id, group_id, plugin_id, attrs),
    do: Plugins.update_definition(tenant_id, group_id, plugin_id, attrs)

  @impl true
  def put_refs(tenant_id, group_id, plugin_id, attrs),
    do: Plugins.put_refs(tenant_id, group_id, plugin_id, attrs)

  @impl true
  def list_group_enablements(tenant_id, group_id),
    do: Plugins.list_group_enablements(tenant_id, group_id)

  @impl true
  def enable_group(tenant_id, group_id, plugin_id),
    do: Plugins.enable_group(tenant_id, group_id, plugin_id)

  @impl true
  def disable_group(tenant_id, group_id, plugin_id),
    do: Plugins.disable_group(tenant_id, group_id, plugin_id)
end
