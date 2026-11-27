defmodule SalixIM.Ports.ProviderAppStore do
  @moduledoc """
  Outbound port for tenant/provider application secrets needed by IM providers.

  A tenant may hold several Feishu custom apps, one per department bot. A
  Feishu connect names its app, so readers fetch the secrets by
  `(tenant_id, app_id)`.
  """

  @callback get_feishu_tenant_app(tenant_id :: String.t()) ::
              {:ok, map()} | :none | {:error, term()}

  @callback get_feishu_tenant_app(tenant_id :: String.t(), app_id :: String.t()) ::
              {:ok, map()} | :none | {:error, term()}

  @callback put_feishu_tenant_app(tenant_id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback delete_feishu_tenant_app(tenant_id :: String.t()) :: :ok | {:error, term()}

  @callback delete_feishu_tenant_app(tenant_id :: String.t(), app_id :: String.t()) ::
              :ok | {:error, term()}

  @optional_callbacks get_feishu_tenant_app: 2,
                      put_feishu_tenant_app: 2,
                      delete_feishu_tenant_app: 1,
                      delete_feishu_tenant_app: 2

  # Store faults must surface as errors, not collapse into "not configured":
  # callers classify :none as a local configuration gap, while {:error, _}
  # is a dependency failure. Swallowing either hides real message loss.
  # `{:error, :not_configured}` is the established absence signal of the
  # Salix.Control.Tenants binding and normalizes to :none.
  @spec get_feishu_tenant_app(String.t()) :: {:ok, map()} | :none | {:error, term()}
  def get_feishu_tenant_app(tenant_id) do
    tenant_id |> impl().get_feishu_tenant_app() |> normalize_app()
  rescue
    exception -> {:error, {:crashed, exception.__struct__}}
  end

  @doc """
  The tenant's Feishu app `app_id`. A store that keeps one app per tenant
  (`get_feishu_tenant_app/1` only) answers with that app when its app id is
  blank or matches.
  """
  @spec get_feishu_tenant_app(String.t(), String.t()) :: {:ok, map()} | :none | {:error, term()}
  def get_feishu_tenant_app(tenant_id, app_id) do
    impl = impl()

    if exports?(impl, :get_feishu_tenant_app, 2) do
      tenant_id |> impl.get_feishu_tenant_app(app_id) |> normalize_app()
    else
      case tenant_id |> impl.get_feishu_tenant_app() |> normalize_app() do
        {:ok, app} ->
          if trim(app["app_id"]) in ["", trim(app_id)], do: {:ok, app}, else: :none

        other ->
          other
      end
    end
  rescue
    exception -> {:error, {:crashed, exception.__struct__}}
  end

  @doc "Saves the tenant's Feishu app (an app made by a scan, `SalixIM.Provider.Lark.Registration`)."
  @spec put_feishu_tenant_app(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_feishu_tenant_app(tenant_id, attrs), do: impl().put_feishu_tenant_app(tenant_id, attrs)

  @doc "Removes every Feishu app of the tenant."
  @spec delete_feishu_tenant_app(String.t()) :: :ok | {:error, term()}
  def delete_feishu_tenant_app(tenant_id) do
    tenant_id |> impl().delete_feishu_tenant_app() |> normalize_delete()
  end

  @doc "Removes the tenant's Feishu app `app_id` only."
  @spec delete_feishu_tenant_app(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_feishu_tenant_app(tenant_id, app_id) do
    impl().delete_feishu_tenant_app(tenant_id, app_id) |> normalize_delete()
  end

  defp normalize_app({:ok, app}) when is_map(app), do: {:ok, app}
  defp normalize_app({:error, :not_configured}), do: :none
  defp normalize_app({:error, reason}), do: {:error, reason}
  defp normalize_app(_other), do: :none

  defp normalize_delete(:ok), do: :ok
  defp normalize_delete({:ok, _}), do: :ok
  defp normalize_delete({:error, :not_found}), do: :ok
  defp normalize_delete({:error, reason}), do: {:error, reason}

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :provider_app_store_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.ProviderAppStore

    @impl true
    def get_feishu_tenant_app(_tenant_id), do: :none

    @impl true
    def get_feishu_tenant_app(_tenant_id, _app_id), do: :none

    @impl true
    def put_feishu_tenant_app(_tenant_id, _attrs), do: {:error, :not_configured}

    @impl true
    def delete_feishu_tenant_app(_tenant_id), do: :ok

    @impl true
    def delete_feishu_tenant_app(_tenant_id, _app_id), do: :ok
  end
end
