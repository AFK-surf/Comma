defmodule SalixAgent.GroupContext do
  @moduledoc """
  Group facts needed by agent control.

  `salix_agent` owns agent identity and runtime configuration. Group records
  are owned by the composition/control plane, so agent control reaches group
  facts through this port.
  """

  @callback list(tenant_id :: String.t()) :: [map()] | {:error, term()}
  @callback get(group_id :: String.t(), tenant_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  def list(tenant_id), do: impl().list(tenant_id)
  def get(group_id, tenant_id), do: impl().get(group_id, tenant_id)

  defp impl, do: Application.get_env(:salix_agent, :group_context_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixAgent.GroupContext

    @impl true
    def list(_tenant_id), do: []

    @impl true
    def get(_group_id, _tenant_id), do: {:error, :not_found}
  end
end
