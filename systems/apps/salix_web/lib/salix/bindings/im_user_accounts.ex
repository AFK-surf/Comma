defmodule Salix.Bindings.IMUserAccounts do
  @moduledoc """
  The Feishu or Lark people who signed in for a Group, for the reads a
  connect makes as one of them (`Salix.Bindings.IMFeishuUserAccounts`,
  `Salix.Bindings.IMLarkUserAccounts`): the Group's OAuth Bindings of the
  provider. A token is resolved, and refreshed when it expires, by the managed
  OAuth owner (`SalixAgent.OAuthCredentials`).

  A member's own sign-in with the bot app their scan made (alias
  `<provider>-member`, `CommaWeb.PluginConnections`) belongs to them. It is
  listed and resolved only for a read that acts for its owner
  (`acts_for_owner?/2`). For a read for anyone else, or for nobody, it does
  not exist.
  """

  alias Salix.Control.OAuthBindings
  alias SalixAgent.OAuthCredentials

  @doc "The signed-in people of `provider` that a read `acting` for someone may use."
  @spec list(String.t(), String.t(), map()) :: {:ok, [map()]}
  def list(provider, group_id, acting) do
    {
      :ok,
      for %{"provider" => ^provider} = binding <- OAuthBindings.list(group_id),
          binding["alias"] != member_alias(provider) or acts_for_owner?(binding, acting) do
        %{
          "alias" => binding["alias"],
          "open_id" => binding["provider_account_id"],
          "name" => binding["provider_account_name"],
          "status" => binding["status"]
        }
      end
    }
  end

  @doc """
  The user access token of the account `alias_name`, as the env var
  `env_var` of `provider` resolves it. A member's own sign-in resolves only
  when `list/3` gives it to the same read.
  """
  @spec access_token(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def access_token(provider, env_var, agent_id, alias_name, acting) do
    with :ok <- usable(provider, alias_name, acting) do
      entry = %{
        "env_var" => env_var,
        "provider" => provider,
        "alias" => alias_name,
        "value" => "access_token"
      }

      case OAuthCredentials.resolve(agent_id, [entry]) do
        {:ok, %{^env_var => token}} -> {:ok, token}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Whether a read `acting` for someone acts for the owner of `binding`: the
  person of its tool call is the binding's `"owner"`
  (`SalixAgent.OAuthCredentials.usable_by?/2`), or is the provider user who
  writes to the connect the read goes through and whose open_id is the
  binding's account. A member's own bot only takes messages from them, and an
  open_id names one person to one app. A read that acts for nobody (an Agent,
  a schedule no person made) never does.
  """
  @spec acts_for_owner?(map(), map()) :: boolean()
  def acts_for_owner?(binding, acting) do
    person = OAuthCredentials.acting_for(%{trusted_origin: field(acting, "trusted_origin")})

    present?(binding["owner"]) and is_binary(person) and
      (OAuthCredentials.usable_by?(binding, person) or own_bot_user?(person, binding, acting))
  end

  defp own_bot_user?(person, binding, acting) do
    case SalixIFC.Codec.decode_principal(person) do
      {:ok, {:provider_user, connect_id, open_id}} ->
        present?(open_id) and open_id == binding["provider_account_id"] and
          connect_id == field(acting, "connect_id")

      _other ->
        false
    end
  end

  defp usable(provider, alias_name, acting) do
    if alias_name == member_alias(provider) do
      with group_id when is_binary(group_id) and group_id != "" <- field(acting, "group_id"),
           {:ok, accounts} <- list(provider, group_id, acting),
           true <- Enum.any?(accounts, &(&1["alias"] == alias_name)) do
        :ok
      else
        _hidden -> {:error, :not_found}
      end
    else
      :ok
    end
  end

  defp member_alias(provider), do: provider <> "-member"

  defp field(acting, key) when is_map(acting), do: acting[key]
  defp field(_acting, _key), do: nil

  defp present?(value), do: is_binary(value) and value != ""
end
