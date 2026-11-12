defmodule Salix.Bindings.DailyBriefMemberAuth do
  @moduledoc """
  A BFT member's own read-only Slack authorization for the daily brief.

  The grant uses the Swarm's own Slack bot app, the one that sends the brief.
  Slack keeps one user token per person and app, so this app must differ from
  the tenant's Slack OAuth app that Group bindings use; otherwise the grant's
  read scopes would join a token that Agents can resolve. The grant belongs to
  one member and has no Group binding. BFT starts the flow,
  reads its result, and deletes the grant through this module. The token
  itself never leaves Salix.
  """

  alias SalixStore.OAuth, as: Connections
  alias SalixStore.OAuth.AuthState
  alias SalixWeb.OAuthFlow

  @alias_name "daily-brief-direct-messages"

  @scopes SalixIM.SlackScopes.daily_brief_user()

  def scopes, do: @scopes

  @spec start(map()) :: {:ok, map()} | {:error, term()}
  def start(%{
        tenant_id: tenant_id,
        group_id: group_id,
        connect_id: connect_id,
        bft_member: member,
        redirect_after: after_url
      })
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(connect_id) and
             is_binary(after_url) do
    with {:ok, member} <- member_ref(member),
         :ok <- separate_from_group_app(tenant_id, group_id, connect_id) do
      OAuthFlow.start_authorization(
        tenant_id,
        group_id,
        "slack",
        %{"alias" => @alias_name, "scopes" => @scopes, "redirect_after" => after_url},
        bft_member: member,
        app_source: %{
          "kind" => "slack_im_connect",
          "group_id" => group_id,
          "connect_id" => connect_id
        }
      )
    end
  end

  def start(_request), do: {:error, :invalid_request}

  @doc """
  The outcome of one authorization, for its own member only. A completed grant
  reports the Slack user and workspace that authorized it.
  """
  @spec result(map()) :: {:ok, map()} | {:error, term()}
  def result(%{tenant_id: tenant_id, state: state, bft_member: member})
      when is_binary(tenant_id) and is_binary(state) do
    with {:ok, member} <- member_ref(member),
         {:ok, auth} <- AuthState.get(state),
         true <- auth["tenant"] == tenant_id and auth["bft_member"] == member do
      case auth["status"] do
        "completed" -> completed(tenant_id, auth["connection_id"], member)
        status -> {:ok, %{status: status, error: auth["error"]}}
      end
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def result(_request), do: {:error, :invalid_request}

  @spec delete(map()) :: :ok | {:error, term()}
  def delete(%{tenant_id: tenant_id, connection_id: connection_id, bft_member: member})
      when is_binary(tenant_id) and is_binary(connection_id) do
    with {:ok, member} <- member_ref(member) do
      OAuthFlow.delete_member_connection(tenant_id, connection_id, member)
    end
  end

  def delete(_request), do: {:error, :invalid_request}

  defp separate_from_group_app(tenant_id, group_id, connect_id) do
    with {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack"),
         true <- connect["tenant_id"] == tenant_id do
      bot_client_id = connect["client_id"]

      case Salix.Control.OAuthApps.get(tenant_id, "slack") do
        {:ok, %{"client_id" => ^bot_client_id}} -> {:error, :shared_slack_app}
        _separate -> :ok
      end
    else
      _unavailable -> {:error, :source_unavailable}
    end
  end

  defp completed(tenant_id, connection_id, member) do
    case Connections.get(connection_id) do
      {:ok, %{"tenant" => ^tenant_id, "bft_member" => ^member} = conn} ->
        # The Slack adapter's account fields sit under the connection's metadata.
        metadata = get_in(conn, ["metadata", "metadata"]) || conn["metadata"] || %{}

        {:ok,
         %{
           status: "completed",
           connection_id: connection_id,
           slack_user_id: metadata["authed_user_id"] || conn["provider_account_id"],
           slack_workspace_id: metadata["team_id"],
           scopes: conn["scopes"] || []
         }}

      _missing ->
        {:error, :not_found}
    end
  end

  defp member_ref(%{org_id: org_id, member_id: member_id, user_id: user_id})
       when is_binary(org_id) and is_binary(member_id) and is_binary(user_id),
       do: {:ok, %{"org_id" => org_id, "member_id" => member_id, "user_id" => user_id}}

  defp member_ref(_member), do: {:error, :invalid_request}
end
