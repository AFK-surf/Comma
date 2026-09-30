defmodule BridgeForTeams.FeishuScopesTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.FeishuScopes

  @bot_scopes [
    "im:message:send_as_bot",
    "im:message.group_at_msg:readonly",
    "im:message.p2p_msg:readonly",
    "im:message:readonly",
    "im:message.group_msg",
    "im:chat:read",
    "im:chat.members:read",
    "im:message:update",
    "im:message:recall",
    "im:message.reactions:read",
    "im:message.reactions:write_only",
    "im:message.pins:read",
    "im:message.pins:write_only",
    "im:resource",
    "contact:contact.base:readonly",
    "contact:user.base:readonly",
    "contact:department.base:readonly"
  ]

  test "exports copyable batch-import JSON for SSO, bot, and combined flows" do
    assert Jason.decode!(FeishuScopes.import_json(:sso)) == %{
             "scopes" => %{
               "user" => ["contact:user.base:readonly"]
             }
           }

    assert Jason.decode!(FeishuScopes.import_json(:bot)) == %{
             "scopes" => %{"tenant" => @bot_scopes}
           }

    assert Jason.decode!(FeishuScopes.import_json(:combined)) == %{
             "scopes" => %{
               "tenant" => @bot_scopes,
               "user" => ["contact:user.base:readonly"]
             }
           }
  end

  test "includes message history, media, reaction, pin, and directory scopes" do
    bot_scopes = FeishuScopes.required_scope_ids(:bot)

    assert "im:message:readonly" in bot_scopes
    assert "im:message.group_msg" in bot_scopes
    assert "im:message:update" in bot_scopes
    assert "im:message:recall" in bot_scopes
    assert "im:message.reactions:read" in bot_scopes
    assert "im:message.reactions:write_only" in bot_scopes
    assert "im:message.pins:read" in bot_scopes
    assert "im:message.pins:write_only" in bot_scopes
    assert "im:resource" in bot_scopes
    assert "contact:contact.base:readonly" in bot_scopes
    assert "contact:user.base:readonly" in bot_scopes
    assert "contact:department.base:readonly" in bot_scopes
  end

  test "documents only additional optional bot capabilities" do
    optional_scope_ids = Enum.map(FeishuScopes.optional_bot_scopes(), & &1.scope)

    refute "im:message.group_msg:readonly" in optional_scope_ids
    assert "im:message.group_at_msg.include_bot:readonly" in optional_scope_ids
    refute "im:resource" in optional_scope_ids
  end

  test "keeps invalid or guessed scopes out of required and optional flows" do
    all_exported =
      Enum.flat_map([:sso, :bot, :combined], &FeishuScopes.required_scope_ids/1) ++
        Enum.map(FeishuScopes.optional_bot_scopes(), & &1.scope)

    refute "im:message.history:readonly" in all_exported
    refute "im:chat.member:readonly" in all_exported
    refute "im:resource:upload" in all_exported
    refute "im:chat:readonly" in all_exported

    assert FeishuScopes.known_invalid_scopes() == [
             "im:message.history:readonly",
             "im:chat.member:readonly",
             "im:resource:upload"
           ]
  end
end
