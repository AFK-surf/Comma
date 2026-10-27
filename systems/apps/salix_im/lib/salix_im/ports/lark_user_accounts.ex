defmodule SalixIM.Ports.LarkUserAccounts do
  @moduledoc """
  Outbound port for the Lark people who signed in for a Group: the Group's
  OAuth Bindings of provider `lark` (`SalixStore.OAuth.Adapters.Lark`). A
  Lark connect's bot finds and reads as one of them what that person may see
  (`SalixIM.Provider.Lark.Meetings`).
  """

  @typedoc "One signed-in person: the binding alias, the Lark open_id, name and status."
  @type account :: %{required(String.t()) => String.t()}

  @callback list(group_id :: String.t()) :: {:ok, [account()]} | {:error, term()}
  @callback access_token(agent_id :: String.t(), alias :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @spec list(String.t()) :: {:ok, [account()]} | {:error, term()}
  def list(group_id), do: impl().list(group_id)

  @spec access_token(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def access_token(agent_id, alias_name), do: impl().access_token(agent_id, alias_name)

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :lark_user_accounts_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.LarkUserAccounts

    @impl true
    def list(_group_id), do: {:ok, []}

    @impl true
    def access_token(_agent_id, _alias), do: {:error, :not_found}
  end
end
