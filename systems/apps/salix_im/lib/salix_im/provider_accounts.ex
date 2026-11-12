defmodule SalixIM.ProviderAccounts do
  @moduledoc """
  Which account a person is on one connect, for a person to recognise it:
  `"name"`, `"email"`, `"workspace"` (their Slack workspace or Lark or Feishu
  tenant, else the Comma for Teams organization of the connect) and `"bot"`
  (the connect's bot). The same person on two connects reads differently by
  the last two. What a provider cannot say stays out, and a connect that
  cannot be read gives `%{}`: a lookup never stops what it serves.

  `app_member/2` is not such a lookup: it answers whether a chat app is
  available to a person, and its caller refuses on any failure.
  """

  alias SalixIM.Ports.Organizations
  alias SalixIM.Provider
  alias SalixIM.ProviderConnects

  @spec who(String.t(), String.t(), String.t(), String.t()) :: map()
  def who(group_id, connect_id, provider, subject) when provider in ~w(slack lark feishu) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, provider) do
      account = account(provider, connect, subject)

      Map.merge(account, %{
        "bot" => first([connect["bot_username"], connect["app_name"]]),
        "workspace" => first([account["workspace"], Organizations.name(connect["tenant_id"])])
      })
    else
      _other -> %{}
    end
  rescue
    _error -> %{}
  end

  def who(_group_id, _connect_id, _provider, _subject), do: %{}

  @doc """
  Whether the connect's chat app is available to the person `subject` (the
  app's availability range), and who they are (`"name"`, `"email"`):
  `SalixIM.Provider.Feishu.AppAvailability` and its Lark twin. Other providers
  answer `{:error, :unsupported}`.
  """
  @spec app_member(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def app_member(%{"provider" => "feishu"} = connect, subject),
    do: Provider.Feishu.AppAvailability.member(connect, subject)

  def app_member(%{"provider" => "lark"} = connect, subject),
    do: Provider.Lark.AppAvailability.member(connect, subject)

  def app_member(_connect, _subject), do: {:error, :unsupported}

  defp account("slack", connect, subject) do
    user =
      case Provider.Slack.call(nil, connect, "slack.get_user_info", %{"user_id" => subject}) do
        {:ok, user} -> user
        _other -> %{}
      end

    %{
      "name" => first([user["real_name"], user["display_name"], user["name"]]),
      "email" => user["email"],
      "workspace" => connect["workspace_name"]
    }
  end

  defp account("lark", connect, subject), do: Provider.Lark.account(connect, subject)
  defp account("feishu", connect, subject), do: Provider.Feishu.account(connect, subject)

  defp first(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))
end
