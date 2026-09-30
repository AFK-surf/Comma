defmodule SalixEnv.Ports.GroupDirectory do
  @moduledoc """
  Group lookup port used by env connector-token creation.
  """

  @callback get_group(String.t(), String.t()) :: {:ok, map()} | {:error, term()}

  def get_group(group_id, tenant_id), do: impl().get_group(group_id, tenant_id)

  defp impl do
    Application.get_env(:salix_env, :group_directory_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixEnv.Ports.GroupDirectory

    @impl true
    def get_group(_group_id, _tenant_id), do: {:error, :group_directory_not_configured}
  end
end
