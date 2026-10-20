defmodule SalixIM.Ports.FeishuUserAccounts do
  @moduledoc """
  Outbound port for the Feishu people who signed in for a Group: the Group's
  OAuth Bindings of provider `feishu` (`SalixStore.OAuth.Adapters.Feishu`). A
  Feishu connect's bot reads as one of them what Feishu shows only to people
  (`SalixIM.Provider.Feishu.Meetings`).
  """

  @typedoc "One signed-in person: the binding alias, the Feishu open_id, name and status."
  @type account :: %{required(String.t()) => String.t()}

  @callback list(group_id :: String.t()) :: {:ok, [account()]} | {:error, term()}
  @callback access_token(agent_id :: String.t(), alias :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @spec list(String.t()) :: {:ok, [account()]} | {:error, term()}
  def list(group_id), do: impl().list(group_id)

  @spec access_token(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def access_token(agent_id, alias_name), do: impl().access_token(agent_id, alias_name)

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :feishu_user_accounts_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuUserAccounts

    @impl true
    def list(_group_id), do: {:ok, []}

    @impl true
    def access_token(_agent_id, _alias), do: {:error, :not_found}
  end
end
