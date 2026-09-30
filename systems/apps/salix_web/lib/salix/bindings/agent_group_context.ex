defmodule Salix.Bindings.AgentGroupContext do
  @moduledoc false

  @behaviour SalixAgent.GroupContext

  alias Salix.Control.Groups

  @impl true
  def list(tenant_id), do: Groups.list(tenant_id)

  @impl true
  def get(group_id, tenant_id), do: Groups.get(group_id, tenant_id)
end
