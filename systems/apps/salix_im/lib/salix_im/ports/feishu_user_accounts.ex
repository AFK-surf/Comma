defmodule SalixIM.Ports.FeishuUserAccounts do
  @moduledoc """
  Outbound port for the Feishu people who signed in for a Group: the Group's
  OAuth Bindings of provider `feishu` (`SalixStore.OAuth.Adapters.Feishu`). A
  Feishu connect's bot finds and reads as one of them what that person may see
  (`SalixIM.Provider.Feishu.Meetings`).

  `acting` says who the read is for: the tool call's `"trusted_origin"`
  and the `"connect_id"` and `"group_id"` of the connect it reads through.
  A sign-in that belongs to one person (a member's own, alias `feishu-member`)
  is listed and resolved only for a read that acts for them; an empty
  `acting` acts for nobody.
  """

  @typedoc "One signed-in person: the binding alias, the Feishu open_id, name and status."
  @type account :: %{required(String.t()) => String.t()}

  @typedoc "Who a read acts for, and the connect and Group it reads through."
  @type acting :: %{optional(String.t()) => term()}

  @callback list(group_id :: String.t(), acting()) :: {:ok, [account()]} | {:error, term()}
  @callback access_token(agent_id :: String.t(), alias :: String.t(), acting()) ::
              {:ok, String.t()} | {:error, term()}

  @spec list(String.t(), acting()) :: {:ok, [account()]} | {:error, term()}
  def list(group_id, acting \\ %{}), do: impl().list(group_id, acting)

  @spec access_token(String.t(), String.t(), acting()) :: {:ok, String.t()} | {:error, term()}
  def access_token(agent_id, alias_name, acting \\ %{}),
    do: impl().access_token(agent_id, alias_name, acting)

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :feishu_user_accounts_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuUserAccounts

    @impl true
    def list(_group_id, _acting), do: {:ok, []}

    @impl true
    def access_token(_agent_id, _alias, _acting), do: {:error, :not_found}
  end
end
