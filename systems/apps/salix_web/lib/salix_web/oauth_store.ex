defmodule SalixWeb.OAuthStore do
  @moduledoc """
  OAuth data access backed by Salix control-plane records. The agent port
  implementation is `Salix.Bindings.AgentOAuthStore`; this module contains the
  concrete control-plane reads used by that adapter.

  Ports the lookups willow's tool layer does against `internal/control`
  (`internal/tools/oauth.go` RequestOAuthAuthorization /
  CompleteOAuthAuthorization / credential resolution):

    * agent → (tenant, group) scoping
    * GetTenantOAuthProviderApp
    * ListOAuthBindingsForGroup
    * public API origin used to build authorization callback URLs

  Intentional divergences from willow:

    * `public_base_url/0` falls back to the local HTTP listener when
      config.json `web.api_base_url` (`:salix_web, :public_base_url`) is unset
      (willow errors when `server.api_base_url` is unset).
    * `bindings_for_group/1` returns the joined binding detail maps (a
      superset of the contract keys: also group_id, provider_account_id,
      expires_at, metadata, created_at).
  """

  alias Salix.Control.{OAuthApps, OAuthBindings}
  alias SalixAgent.Control

  def agent_oauth_context(agent_id) do
    case Control.get(agent_id) do
      {:ok, agent} ->
        {:ok,
         %{
           tenant: agent["tenant_id"],
           group_id: agent["group_id"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def provider_app(tenant, provider),
    do: OAuthApps.get(tenant, provider)

  def bindings_for_group(group_id),
    do: {:ok, OAuthBindings.list(group_id)}

  def public_base_url, do: SalixWeb.Application.public_base_url()

  def delete_binding(tenant, group_id, binding_id),
    do: SalixWeb.OAuthFlow.delete_binding(tenant, group_id, binding_id)
end
