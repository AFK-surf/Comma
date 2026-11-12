defmodule BridgeForTeams.LarkScopesTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.LarkScopes

  test "the import names every scope the Lark bot needs, for the app's own identity" do
    assert %{"scopes" => %{"tenant" => tenant, "user" => user}} =
             Jason.decode!(LarkScopes.import_json())

    # A signed-in person grants the meeting, notes, Minutes and document
    # reads, and offline_access for the refresh token. The import declares
    # the user scopes of the Feishu import besides.
    assert LarkScopes.user_scope_ids() -- user == []
    assert user == Enum.uniq(user)

    feishu_user =
      BridgeForTeams.FeishuScopes.import_payload(:combined)["scopes"]["user"] --
        BridgeForTeams.FeishuScopes.import_payload(:sso)["scopes"]["user"]

    assert feishu_user -- user == []

    for scope <- ~w(vc:meeting.search:read vc:note:read minutes:minutes:readonly
                    docx:document:readonly offline_access) do
      assert scope in user
    end

    assert tenant == Enum.uniq(tenant)
    assert tenant == LarkScopes.required_scope_ids()

    # The bot joins the Lark video meetings it is invited to.
    assert "vc:meeting.bot.join:write" in tenant

    # The bot asks whether the app is available to a person who asks for a
    # station tool; a sign-in does not.
    assert "application:application:self_manage" in tenant
    refute "application:application:self_manage" in user

    # The bot has the scopes of a Feishu bot.
    assert BridgeForTeams.FeishuScopes.import_payload(:bot)["scopes"]["tenant"] -- tenant == []

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
      wiki:wiki wiki:wiki:readonly
      wiki:node:read wiki:space:read wiki:space:retrieve wiki:node:retrieve
      docs:document.comment:read docs:document.comment:create docs:document.comment:write_only
      docs:document.media:download docs:document.media:upload
      docs:permission.member:retrieve docs:permission.member:create
      docs:permission.member:delete docs:permission.setting:read
      drive:drive drive:drive:readonly drive:drive:version drive:drive:version:readonly
      drive:drive.metadata:readonly drive:drive.search:readonly
      space:document:delete space:document:retrieve bitable:app:readonly sheets:spreadsheet:readonly
      minutes:minutes.basic:read minutes:minutes.artifacts:read
      minutes:minutes.media:export minutes:minutes.search:read minutes:minutes:readonly
      minutes:permission:apply search:docs:read
      vc:meeting.search:read vc:meeting.meetingevent:read vc:note:read vc:record:readonly
    )

    assert Enum.sort(LarkScopes.document_scope_ids()) == Enum.sort(documents)
    assert documents -- tenant == []

    # Cloud space and wiki access is granted to both identities.
    drive_and_wiki = ~w(
      drive:drive drive:drive:readonly drive:drive:version drive:drive:version:readonly
      drive:drive.metadata:readonly drive:drive.search:readonly
      wiki:wiki wiki:wiki:readonly wiki:node:read wiki:node:retrieve
      wiki:space:read wiki:space:retrieve search:docs:read space:document:retrieve
    )

    assert drive_and_wiki -- tenant == []
    assert drive_and_wiki -- user == []
  end

  test "the one preset carries the same JSON" do
    assert [%{id: "bot", title: "Lark bot", json: json, required_scopes: scopes}] =
             LarkScopes.import_cards()

    assert json == LarkScopes.import_json()
    assert scopes == LarkScopes.required_scope_ids()
  end

  test "the bot and a signed-in person get the daily work, without private chats or administration" do
    tenant = LarkScopes.required_scope_ids()
    user = LarkScopes.user_scope_ids()

    # Group messages, the directory, calendars and rooms, search, Minutes and
    # video meetings, for both identities.
    for scope <- ~w(im:chat.members:read directory:employee:search calendar:calendar.event:create
                    calendar:room:readonly search:message minutes:minutes vc:room:readonly) do
      assert scope in tenant
      assert scope in user
    end

    assert "im:message.group_msg:get_as_user" in user
    assert "im:message.send_as_user" in user
    assert "docs:permission.member:apply" in user

    # Table reads and document edits as a person ask for their scopes only
    # when needed: the import offers them, a default sign-in does not ask.
    imported = Jason.decode!(LarkScopes.import_json())["scopes"]["user"]
    on_demand = LarkScopes.on_demand_user_scopes()

    for scope <- ~w(sheets:spreadsheet:readonly bitable:app:readonly docx:document
                    docs:document.comment:create docs:document.media:upload) do
      assert scope in on_demand
      refute scope in user
    end

    assert (user ++ on_demand) -- imported == []

    assert user == Enum.uniq(user)

    # A sign-in reads no private chat; neither identity administers.
    refute Enum.any?(user, &String.contains?(&1, "p2p"))

    for scope <- ~w(directory:employee.base.is_admin:read contact:role:readonly
                    im:chat.managers:write_only im:chat:moderation:write_only) do
      refute scope in tenant
      refute scope in user
    end
  end
end
