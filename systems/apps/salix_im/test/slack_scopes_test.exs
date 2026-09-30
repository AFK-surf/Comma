defmodule SalixIM.SlackScopesTest do
  use ExUnit.Case, async: true

  alias SalixIM.SlackScopes

  test "generated Slack bot scopes include expression catalog and reaction reads" do
    scopes = SlackScopes.bot()

    assert scopes == Enum.uniq(scopes)
    assert "emoji:read" in scopes
    assert "pins:read" in scopes
    assert "reactions:read" in scopes
    assert "reactions:write" in scopes
    assert SlackScopes.bot_scope() == Enum.join(scopes, ",")
  end

  test "generated Slack bot scopes cover public and private channel creation and invites" do
    scopes = SlackScopes.bot()

    # conversations.create / conversations.invite need channels:manage for
    # public channels and groups:write for private ones.
    assert "channels:manage" in scopes
    assert "groups:write" in scopes
  end
end
