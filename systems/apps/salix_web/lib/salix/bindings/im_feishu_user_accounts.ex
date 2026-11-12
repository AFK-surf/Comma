defmodule Salix.Bindings.IMFeishuUserAccounts do
  @moduledoc """
  The Feishu people who signed in for a Group, from its OAuth Bindings of
  provider `feishu`. A token is resolved, and refreshed when it expires, by the
  managed OAuth owner (`SalixAgent.OAuthCredentials`).
  """

  @behaviour SalixIM.Ports.FeishuUserAccounts

  alias Salix.Control.OAuthBindings

  @impl true
  def list(group_id) do
    {
      :ok,
      # A member's sign-in for their Routine (alias `feishu-member`) belongs to
      # them alone: no read of the connect's own uses it.
      for %{"provider" => "feishu"} = binding <- OAuthBindings.list(group_id),
          binding["alias"] != "feishu-member" do
        %{
          "alias" => binding["alias"],
          "open_id" => binding["provider_account_id"],
          "name" => binding["provider_account_name"],
          "status" => binding["status"]
        }
      end
    }
  end

  @impl true
  def access_token(_agent_id, "feishu-member"), do: {:error, :not_found}

  def access_token(agent_id, alias_name) do
    entry = %{
      "env_var" => "FEISHU_USER_ACCESS_TOKEN",
      "provider" => "feishu",
      "alias" => alias_name,
      "value" => "access_token"
    }

    case SalixAgent.OAuthCredentials.resolve(agent_id, [entry]) do
      {:ok, %{"FEISHU_USER_ACCESS_TOKEN" => token}} -> {:ok, token}
      {:error, _reason} = error -> error
    end
  end
end
