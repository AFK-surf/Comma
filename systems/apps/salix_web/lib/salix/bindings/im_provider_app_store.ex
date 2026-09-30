defmodule Salix.Bindings.IMProviderAppStore do
  @moduledoc false

  @behaviour SalixIM.Ports.ProviderAppStore

  @impl true
  def get_feishu_tenant_app(tenant_id), do: Salix.Control.Tenants.get_feishu_tenant_app(tenant_id)
end
