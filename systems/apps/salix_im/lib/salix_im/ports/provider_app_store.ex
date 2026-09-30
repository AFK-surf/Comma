defmodule SalixIM.Ports.ProviderAppStore do
  @moduledoc """
  Outbound port for tenant/provider application secrets needed by IM providers.
  """

  @callback get_feishu_tenant_app(tenant_id :: String.t()) ::
              {:ok, map()} | :none | {:error, term()}

  # Store faults must surface as errors, not collapse into "not configured":
  # callers classify :none as a local configuration gap, while {:error, _}
  # is a dependency failure. Swallowing either hides real message loss.
  # `{:error, :not_configured}` is the established absence signal of the
  # Salix.Control.Tenants binding and normalizes to :none.
  @spec get_feishu_tenant_app(String.t()) :: {:ok, map()} | :none | {:error, term()}
  def get_feishu_tenant_app(tenant_id) do
    case impl().get_feishu_tenant_app(tenant_id) do
      {:ok, app} when is_map(app) -> {:ok, app}
      {:error, :not_configured} -> :none
      {:error, reason} -> {:error, reason}
      _ -> :none
    end
  rescue
    exception -> {:error, {:crashed, exception.__struct__}}
  end

  defp impl, do: Application.get_env(:salix_im, :provider_app_store_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.ProviderAppStore

    @impl true
    def get_feishu_tenant_app(_tenant_id), do: :none
  end
end
