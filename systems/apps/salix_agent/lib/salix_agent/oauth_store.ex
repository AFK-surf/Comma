defmodule SalixAgent.OAuthStore do
  @moduledoc """
  Control-plane read seam for the agent-facing OAuth tools — the Salix port of
  the control-DB lookups willow's OAuth tools perform inline
  (`internal/tools/listoauth.go`: `ListOAuthBindingsForGroup`;
  `internal/tools/request_oauth_auth.go`: `GetAgent` + `tenantOAuthApp` +
  `tc.APIBaseURL`; `internal/oauth/resolver.go`: `GetTenant` →
  `GetTenantOAuthProviderApp`).

  The active implementation is configured with

      Application.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)

  (same seam pattern as `SalixAgent.LlmResolver` / `:env_dispatch`). With no
  implementation configured every lookup returns
  `{:error, :oauth_store_not_configured}` and `public_base_url/0` returns
  `nil`; the tools surface that as willow's "oauth authorization is not
  configured for this runtime" error (or an empty credential list for the
  read-only listing, matching willow's empty-group behavior).

  ## Intentional divergences from willow

    * Willow reads the agent row, tenant config, and bindings from the control
      DB directly inside each tool; Salix routes them through this behaviour so
      `salix_agent` stays decoupled from `salix_web`'s control-plane records.
    * `agent_oauth_context/1` collapses willow's `GetAgent` →
      `agent.TenantID` / `agent.GroupID` pair into one call; "agent not
      found" / "agent has no tenant" map to `{:error, term}` returns.
    * `public_base_url/0` replaces willow's `tc.APIBaseURL`
      (`server.api_base_url` config).
  """

  @doc """
  The `(tenant, group_id)` pair the agent's OAuth operations are scoped to —
  willow's `tc.ControlDB.GetAgent(tc.AgentID)` → `TenantID` / `GroupID`.
  """
  @callback agent_oauth_context(agent_id :: String.t()) ::
              {:ok, %{tenant: String.t(), group_id: String.t()}} | {:error, term()}

  @doc """
  The tenant's per-provider OAuth client app (willow's `tenantOAuthApp` /
  `GetTenantOAuthProviderApp`): `%{"client_id" => _, "client_secret" => _}`.
  """
  @callback provider_app(tenant :: String.t(), provider :: String.t()) ::
              {:ok, %{optional(String.t()) => term()}} | {:error, :not_configured | term()}

  @doc """
  The OAuth bindings attached to a group (willow's
  `ListOAuthBindingsForGroup`): string-keyed maps with at least
  `"binding_id"`, `"provider"`, `"alias"`, `"connection_id"`, `"status"`,
  `"enabled"`, `"provider_account_name"`, `"scopes"`.
  """
  @callback bindings_for_group(group_id :: String.t()) ::
              {:ok, [%{optional(String.t()) => term()}]} | {:error, term()}

  @doc """
  The public base URL OAuth redirect URIs are built from (willow's
  `tc.APIBaseURL` / `server.api_base_url`), or nil when not configured.
  """
  @callback public_base_url() :: String.t() | nil

  @doc """
  Delete (disconnect) a group's OAuth binding, best-effort revoking the
  provider token when it was the last reference. Mirrors the dashboard
  disconnect path. `{:error, :not_found}` when no such binding exists for the
  group/tenant.
  """
  @callback delete_binding(tenant :: String.t(), group_id :: String.t(), binding_id :: String.t()) ::
              :ok | {:error, term()}

  @doc "The configured implementation module, or nil."
  @spec impl() :: module() | nil
  def impl, do: Application.get_env(:salix_agent, :oauth_store_mod)

  @spec agent_oauth_context(String.t()) ::
          {:ok, %{tenant: String.t(), group_id: String.t()}} | {:error, term()}
  def agent_oauth_context(agent_id) do
    case impl() do
      nil -> {:error, :oauth_store_not_configured}
      mod -> mod.agent_oauth_context(agent_id)
    end
  end

  @spec provider_app(String.t(), String.t()) ::
          {:ok, %{optional(String.t()) => term()}} | {:error, term()}
  def provider_app(tenant, provider) do
    case impl() do
      nil -> {:error, :oauth_store_not_configured}
      mod -> mod.provider_app(tenant, provider)
    end
  end

  @spec bindings_for_group(String.t()) ::
          {:ok, [%{optional(String.t()) => term()}]} | {:error, term()}
  def bindings_for_group(group_id) do
    case impl() do
      nil -> {:error, :oauth_store_not_configured}
      mod -> mod.bindings_for_group(group_id)
    end
  end

  @spec public_base_url() :: String.t() | nil
  def public_base_url do
    case impl() do
      nil -> nil
      mod -> mod.public_base_url()
    end
  end

  @spec delete_binding(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_binding(tenant, group_id, binding_id) do
    case impl() do
      nil -> {:error, :oauth_store_not_configured}
      mod -> mod.delete_binding(tenant, group_id, binding_id)
    end
  end
end
