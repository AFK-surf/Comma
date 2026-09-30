defmodule Salix.Bindings.EnvGroupDirectory do
  @moduledoc false

  @behaviour SalixEnv.Ports.GroupDirectory

  @impl true
  def get_group(group_id, tenant_id), do: Salix.Control.Groups.get(group_id, tenant_id)
end
