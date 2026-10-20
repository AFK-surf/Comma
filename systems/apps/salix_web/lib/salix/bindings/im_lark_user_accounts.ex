defmodule Salix.Bindings.IMLarkUserAccounts do
  @moduledoc """
  The Lark people who signed in for a Group, from its OAuth Bindings of
  provider `lark`. A token is resolved, and refreshed when it expires, by the
  managed OAuth owner (`SalixAgent.OAuthCredentials`).
  """

  @behaviour SalixIM.Ports.LarkUserAccounts

  alias Salix.Control.OAuthBindings

  @impl true
  def list(group_id) do
    {:ok,
     for %{"provider" => "lark"} = binding <- OAuthBindings.list(group_id) do
       %{
         "alias" => binding["alias"],
         "open_id" => binding["provider_account_id"],
         "name" => binding["provider_account_name"],
         "status" => binding["status"]
       }
     end}
  end

  @impl true
  def access_token(agent_id, alias_name) do
    entry = %{
      "env_var" => "LARK_USER_ACCESS_TOKEN",
      "provider" => "lark",
      "alias" => alias_name,
      "value" => "access_token"
    }

    case SalixAgent.OAuthCredentials.resolve(agent_id, [entry]) do
      {:ok, %{"LARK_USER_ACCESS_TOKEN" => token}} -> {:ok, token}
      {:error, _reason} = error -> error
    end
  end
end
