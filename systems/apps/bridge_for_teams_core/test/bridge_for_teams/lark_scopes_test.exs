defmodule BridgeForTeams.LarkScopesTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.LarkScopes

  test "the import names every scope the Lark bot needs, for the app's own identity" do
    assert %{"scopes" => %{"tenant" => tenant, "user" => user}} =
             Jason.decode!(LarkScopes.import_json())

    # A signed-in person grants the meeting, notes, Minutes and document
    # reads, and offline_access for the refresh token.
    assert user == LarkScopes.user_scope_ids()

    for scope <- ~w(vc:meeting.search:read vc:note:read minutes:minutes:readonly
                    docx:document:readonly offline_access) do
      assert scope in user
    end

    assert tenant == Enum.uniq(tenant)
    assert tenant == LarkScopes.required_scope_ids()

    # Messages, files, chats and the directory.
    for scope <- ~w(
      im:message im:message:send_as_bot im:message.p2p_msg:readonly
      im:message.group_at_msg:readonly im:message.group_msg im:message.reactions:read
      im:resource im:chat:readonly
      contact:contact.base:readonly contact:user.base:readonly
      contact:department.base:readonly contact:user.email:readonly
      contact:user.department:readonly
    ) do
      assert scope in tenant
    end

    # Documents and Minutes as the bot. Lark lists wiki spaces and nodes with
    # the two retrieve scopes.
    documents = ~w(
      docx:document docx:document:readonly docx:document:create docx:document:write_only
      wiki:node:read wiki:space:read wiki:space:retrieve wiki:node:retrieve
      docs:document.comment:read docs:document.comment:create docs:document.comment:write_only
      docs:document.media:download docs:document.media:upload
      docs:permission.member:retrieve docs:permission.member:create
      docs:permission.member:delete docs:permission.setting:read drive:drive
      space:document:delete minutes:minutes.basic:read minutes:minutes.artifacts:read
      minutes:minutes.media:export minutes:minutes.search:read minutes:permission:apply
    )

    assert Enum.sort(LarkScopes.document_scope_ids()) == Enum.sort(documents)
    assert documents -- tenant == []
  end

  test "the one preset carries the same JSON" do
    assert [%{id: "bot", title: "Lark bot", json: json, required_scopes: scopes}] =
             LarkScopes.import_cards()

    assert json == LarkScopes.import_json()
    assert scopes == LarkScopes.required_scope_ids()
  end
end
