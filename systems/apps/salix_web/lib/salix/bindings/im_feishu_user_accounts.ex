defmodule Salix.Bindings.IMFeishuUserAccounts do
  @moduledoc """
  The Feishu people who signed in for a Group, from its OAuth Bindings of
  provider `feishu` (`Salix.Bindings.IMUserAccounts`). A member's own sign-in
  (alias `feishu-member`) is there only for a read that acts for them.
  """

  @behaviour SalixIM.Ports.FeishuUserAccounts

  alias Salix.Bindings.IMUserAccounts

  @impl true
  def list(group_id, acting), do: IMUserAccounts.list("feishu", group_id, acting)

  @impl true
  def access_token(agent_id, alias_name, acting),
    do:
      IMUserAccounts.access_token(
        "feishu",
        "FEISHU_USER_ACCESS_TOKEN",
        agent_id,
        alias_name,
        acting
      )
end
