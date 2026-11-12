defmodule Salix.Bindings.IMProviderAppStore do
  @moduledoc false

  @behaviour SalixIM.Ports.ProviderAppStore

  @impl true
  def get_feishu_tenant_app(tenant_id), do: Salix.Control.Tenants.get_feishu_tenant_app(tenant_id)

  @impl true
  def put_feishu_tenant_app(tenant_id, attrs),
    do: Salix.Control.Tenants.put_feishu_tenant_app(tenant_id, attrs)

  @impl true
  def delete_feishu_tenant_app(tenant_id),
    do: Salix.Control.Tenants.delete_feishu_tenant_app(tenant_id)
end
