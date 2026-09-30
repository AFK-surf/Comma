defmodule SalixAgent.ComposioStore do
  @moduledoc """
  Control-plane read seam for the agent-facing Composio tools — the sibling of
  `SalixAgent.OAuthStore` for the Composio integrations path. The only lookup
  the tools need beyond the shared agent context (tenant/group, which comes
  from `SalixAgent.OAuthStore.agent_oauth_context/1`) is the tenant's
  effective Composio settings.

  The active implementation is configured with

      Application.put_env(:salix_agent, :composio_store_mod, Salix.Bindings.AgentComposioStore)

  (same seam pattern as `:oauth_store_mod`). With no implementation configured
  every lookup returns `{:error, :composio_not_configured}`, which the tools
  surface as a "Composio is not configured" error.
  """

  @doc """
  The tenant's effective Composio settings
  (`%{"api_key" => _, "base_url" => _}`), or `{:error, :not_configured}`
  when the tenant has not opted in.
  """
  @callback settings(tenant :: String.t()) ::
              {:ok, %{optional(String.t()) => term()}} | {:error, :not_configured | term()}

  @doc "The configured implementation module, or nil."
  @spec impl() :: module() | nil
  def impl, do: Application.get_env(:salix_agent, :composio_store_mod)

  @spec settings(String.t()) ::
          {:ok, %{optional(String.t()) => term()}} | {:error, term()}
  def settings(tenant) do
    case impl() do
      nil -> {:error, :composio_not_configured}
      mod -> mod.settings(tenant)
    end
  end
end
