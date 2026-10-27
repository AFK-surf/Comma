defmodule BridgeForTeams.FeishuScopesTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.FeishuScopes

  test "default imports include integration reads and writes under the correct identity" do
    assert %{"scopes" => %{"tenant" => tenant, "user" => user}} =
             Jason.decode!(FeishuScopes.import_json(:combined))

    for scope <- ~w(
      im:message:send_as_bot im:message.group_msg im:chat.members:read
      im:message.group_at_msg.include_bot:readonly
      contact:user.email:readonly contact:user.department:readonly
      vc:meeting.bot.join:write vc:meeting.bot.manage:write
      vc:meeting.interaction:write vc:meeting.message:write
      approval:approval.list:readonly approval:instance approval:task
    ) do
      assert scope in tenant
    end

    for scope <- ~w(
      contact:user:search
      minutes:minutes.basic:read minutes:minutes.search:read
      minutes:minutes.transcript:export minutes:minutes.artifacts:read
      minutes:minutes.media:export minutes:minutes.statistics:read
      calendar:calendar:readonly calendar:calendar
      vc:meeting.meetingid:read vc:meeting.meetingevent:read
      docx:document:readonly docs:document:export docx:document
      bitable:app:readonly board:whiteboard:node:read
      task:task:read task:tasklist:read task:comment:read
      task:task:write task:tasklist:write task:comment:write
      mail:user_mailbox:readonly mail:user_mailbox.message:readonly
      mail:user_mailbox.message.address:read mail:user_mailbox.message.subject:read
      mail:user_mailbox.message.body:read mail:user_mailbox.message:modify
      mail:user_mailbox.message:send okr:okr:readonly okr:okr
    ) do
      assert scope in user

      refute scope in (tenant --
                         ["vc:meeting.meetingevent:read" | FeishuScopes.document_scope_ids()])
    end

    # A signed-in person grants the meeting, notes, Minutes and document
    # reads, and offline_access for the refresh token.
    for scope <- FeishuScopes.sign_in_user_scopes(), do: assert(scope in user)

    for scope <- ~w(vc:meeting.search:read vc:note:read minutes:minutes:readonly
                    docx:document:readonly offline_access) do
      assert scope in FeishuScopes.sign_in_user_scopes()
    end

    assert user == Enum.uniq(user)

    # Cloud space and wiki access is granted to both identities.
    drive_and_wiki = ~w(
      drive:drive drive:drive:readonly drive:drive:version drive:drive:version:readonly
      drive:drive.metadata:readonly drive:drive.search:readonly
      wiki:wiki wiki:wiki:readonly wiki:node:read wiki:node:retrieve
      wiki:space:read wiki:space:retrieve search:docs:read space:document:retrieve
    )

    assert drive_and_wiki -- tenant == []
    assert drive_and_wiki -- user == []

    # Routers and Workers read and edit documents and read Minutes as the bot.
    for scope <- ~w(
      docx:document docx:document:readonly docx:document:create docx:document:write_only
      wiki:node:read wiki:space:read docs:document.comment:read docs:document.comment:create
      docs:document.comment:write_only docs:document.media:download docs:document.media:upload
      docs:permission.member:retrieve docs:permission.member:create docs:permission.member:delete
      docs:permission.setting:read drive:drive space:document:delete
      minutes:minutes.basic:read minutes:minutes.artifacts:read minutes:minutes.media:export
      minutes:minutes.search:read minutes:permission:apply
    ) do
      assert scope in tenant
    end

    assert Jason.decode!(FeishuScopes.import_json(:bot)) == %{
             "scopes" => %{"tenant" => tenant}
           }
  end

  test "the SSO-only import requests identity access" do
    assert Jason.decode!(FeishuScopes.import_json(:sso)) == %{
             "scopes" => %{"user" => ["contact:user.base:readonly"]}
           }
  end
end
