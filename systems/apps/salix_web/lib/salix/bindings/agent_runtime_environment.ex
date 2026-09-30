defmodule Salix.Bindings.AgentRuntimeEnvironment do
  @moduledoc false

  @behaviour SalixAgent.RuntimeEnvironment

  @impl true
  def resolve_external_runtime_binding(config, tenant_id, group_id) do
    with :ok <- SalixWeb.CloudVM.RuntimeLifecycle.wake_binding(config, tenant_id, group_id),
         do: SalixEnv.Control.resolve_external_runtime_binding(config, tenant_id, group_id)
  end

  @impl true
  def external_runtime_binding_status(config, tenant_id, group_id) do
    SalixEnv.Control.external_runtime_binding_status(config, tenant_id, group_id)
  end
end
