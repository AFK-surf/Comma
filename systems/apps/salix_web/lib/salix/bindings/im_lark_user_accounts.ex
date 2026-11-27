defmodule Salix.Bindings.IMLarkUserAccounts do
  @moduledoc """
  The Lark people who signed in for a Group, from its OAuth Bindings of
  provider `lark` (`Salix.Bindings.IMUserAccounts`). A member's own sign-in
  (alias `lark-member`) is there only for a read that acts for them.
  """

  @behaviour SalixIM.Ports.LarkUserAccounts

  alias Salix.Bindings.IMUserAccounts

  @impl true
  def list(group_id, acting), do: IMUserAccounts.list("lark", group_id, acting)

  @impl true
  def access_token(agent_id, alias_name, acting),
    do:
      IMUserAccounts.access_token("lark", "LARK_USER_ACCESS_TOKEN", agent_id, alias_name, acting)
end
