defmodule SalixAgent.RuntimeEnvironment do
  @moduledoc """
  Compatibility-free port from External Session ownership to the tagged
  `RuntimeBindingResolver`.

  The configured environment module remains the Connected Runtime transport
  implementation. It is never asked to resolve Compute Workloads.
  """

  @callback resolve_external_runtime_binding(map(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback external_runtime_binding_status(map(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}

  def resolve_external_runtime_binding(config, tenant_id, group_id),
    do: SalixAgent.RuntimeBindingResolver.resolve(config, tenant_id, group_id)

  def external_runtime_binding_status(config, tenant_id, group_id),
    do: SalixAgent.RuntimeBindingResolver.status(config, tenant_id, group_id)

  def connected_resolve(config, tenant_id, group_id),
    do: connected_impl().resolve_external_runtime_binding(config, tenant_id, group_id)

  def connected_status(config, tenant_id, group_id),
    do: connected_impl().external_runtime_binding_status(config, tenant_id, group_id)

  defp connected_impl,
    do: Application.get_env(:salix_agent, :runtime_environment_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(_config, _tenant_id, _group_id),
      do: {:error, :not_configured}

    @impl true
    def external_runtime_binding_status(_config, _tenant_id, _group_id),
      do: {:ok, %{"status" => "unknown"}}
  end
end
