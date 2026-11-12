defmodule BridgeForTeams.LarkScopes do
  @moduledoc """
  The permission scopes a Lark app needs for its bot.

  The Swarm Connections page and `bft lark scopes` show them as one JSON for
  the batch import of the Lark Developer Console (Permissions & Scopes). The
  bot's scopes are for the app's own identity (`tenant`). The `user` scopes
  are what a person grants when they sign in so the bot can work as them:
  meetings, notes, recordings, documents, group chats, the directory and
  calendars
  (`SalixStore.OAuth.Adapters.Lark`).

  Keep the names equal to the scope catalog of the Lark open platform
  (`open.larksuite.com`). A scope takes effect with the next published
  version of the app.

  The import names the same scopes as the Feishu one
  (`BridgeForTeams.FeishuScopes`): approval processing as the bot, and the
  user-identity search, Minutes, calendar, documents, Base, whiteboard, tasks,
  mail and OKR permissions a person may grant. A scope here does not install
  its tool.

  `im:message.group_msg` lets Lark deliver every message of a group. Without
  it only a message that mentions the bot arrives, so a thread cannot go on
  without a mention and only mentions are recorded.
  """

  # Messages, files, chats, and the directory reads of `lark.get_user`,
  # `lark.list_contact_scopes` and the department operations. The bot joins a
  # Lark video meeting it is invited to and reads what is said there
  # (`SalixIM.Provider.Lark.MeetingBot`).
  @messaging_scopes ~w(
    im:message
    im:message:send_as_bot
    im:message.p2p_msg:readonly
    im:message.group_at_msg:readonly
    im:message.group_msg
    im:message.reactions:read
    im:resource
    im:chat:readonly
    contact:contact.base:readonly
    contact:user.base:readonly
    contact:department.base:readonly
    contact:user.email:readonly
    contact:user.department:readonly
    vc:meeting.bot.join:write
  )

  # Cloud documents and Minutes, read and edited as the bot
  # (`SalixIM.Provider.Lark.Docs`, `SalixIM.Provider.Lark.Minutes`). Lark
  # lists wiki spaces and nodes with the two `retrieve` scopes.
  @document_scopes ~w(
    docx:document
    docx:document:readonly
    docx:document:create
    docx:document:write_only
    wiki:wiki
    wiki:wiki:readonly
    wiki:node:read
    wiki:space:read
    wiki:space:retrieve
    wiki:node:retrieve
    docs:document.comment:read
    docs:document.comment:create
    docs:document.comment:write_only
    docs:document.media:download
    docs:document.media:upload
    docs:permission.member:retrieve
    docs:permission.member:create
    docs:permission.member:delete
    docs:permission.setting:read
    drive:drive
    drive:drive:readonly
    drive:drive:version
    drive:drive:version:readonly
    drive:drive.metadata:readonly
    drive:drive.search:readonly
    space:document:delete
    space:document:retrieve
    bitable:app:readonly
    sheets:spreadsheet:readonly
    minutes:minutes.basic:read
    minutes:minutes.artifacts:read
    minutes:minutes.media:export
    minutes:minutes.search:read
    minutes:minutes:readonly
    minutes:permission:apply
    search:docs:read
    vc:meeting.search:read
    vc:meeting.meetingevent:read
    vc:note:read
    vc:record:readonly
  )

  # Approval processing as the bot, as on Feishu.
  @approval_scopes ~w(
    approval:approval.list:readonly
    approval:instance
    approval:task
  )

  # User-identity permissions the import declares besides those of a sign-in,
  # as on Feishu: search, Minutes, calendars, documents, Base, whiteboards,
  # tasks, mail and OKR.
  @declared_user_scopes ~w(
    contact:user:search
    minutes:minutes.basic:read
    minutes:minutes.search:read
    minutes:minutes.transcript:export
    minutes:minutes.artifacts:read
    calendar:calendar:readonly
    calendar:calendar
    vc:meeting.meetingid:read
    vc:meeting.meetingevent:read
    minutes:minutes.media:export
    minutes:minutes.statistics:read
    docx:document:readonly
    docs:document:export
    docx:document
    bitable:app:readonly
    board:whiteboard:node:read
    task:task:read
    task:tasklist:read
    task:comment:read
    task:task:write
    task:tasklist:write
    task:comment:write
    mail:user_mailbox:readonly
    mail:user_mailbox.message:readonly
    mail:user_mailbox.message.address:read
    mail:user_mailbox.message.subject:read
    mail:user_mailbox.message.body:read
    mail:user_mailbox.message:modify
    mail:user_mailbox.message:send
    okr:okr:readonly
    okr:okr
  )

  # The rest of the daily work as the bot: group messages and chats,
  # the directory and organization, search, Minutes, calendars and meeting
  # rooms, and video meetings. Taken from the official larksuite/cli and
  # checked against the platform's scope catalog for the app identity; no
  # administration (roles, resignations, group moderation).
  @work_scopes ~w(
    calendar:calendar
    calendar:calendar.event:create
    calendar:calendar.event:delete
    calendar:calendar.event:join
    calendar:calendar.event:read
    calendar:calendar.event:reply
    calendar:calendar.event:transfer
    calendar:calendar.event:update
    calendar:calendar.free_busy:read
    calendar:calendar:create
    calendar:calendar:delete
    calendar:calendar:read
    calendar:calendar:readonly
    calendar:calendar:update
    calendar:room:readonly
    contact:department.organize:readonly
    contact:job_title:readonly
    contact:user.basic_profile:readonly
    contact:user.dotted_line_leader_info.read
    contact:user.employee:readonly
    contact:user.employee_id:readonly
    contact:user.id:readonly
    contact:user.phone:readonly
    contact:work_city:readonly
    directory:department.base:read
    directory:department.count:read
    directory:department.department_path:read
    directory:department.has_child:read
    directory:department.leader:read
    directory:department.name:read
    directory:department.organization:read
    directory:department.parent_id:read
    directory:department:list
    directory:department:read
    directory:department:search
    directory:employee.base.avatar:read
    directory:employee.base.base:read
    directory:employee.base.department:read
    directory:employee.base.department_path:read
    directory:employee.base.description:read
    directory:employee.base.dotted_line_leaders:read
    directory:employee.base.email:read
    directory:employee.base.enterprise_email:read
    directory:employee.base.leader:read
    directory:employee.base.leader_id:read
    directory:employee.base.mobile:read
    directory:employee.base.name.another_name:read
    directory:employee.base.name.first_name:read
    directory:employee.base.name.last_name:read
    directory:employee.base.name.name:read
    directory:employee.work.base_work:read
    directory:employee.work.extension_number:read
    directory:employee.work.job_number:read
    directory:employee.work.job_title:read
    directory:employee.work.join_date:read
    directory:employee.work.positions:read
    directory:employee.work.work_country_or_region:read
    directory:employee.work.work_place:read
    directory:employee.work.work_station:read
    directory:employee:list
    directory:employee:read
    directory:employee:search
    directory:job_title.base:read
    directory:place.base:read
    im:chat.announcement:read
    im:chat.chat_pins:read
    im:chat.members:bot_access
    im:chat.members:read
    im:chat.members:write_only
    im:chat:create
    im:chat:read
    im:message.group_at_msg.include_bot:readonly
    im:message.group_msg.include_bot:read
    im:message.pins:read
    im:message.pins:write_only
    im:message.reactions:write_only
    im:message.urgent
    im:message:readonly
    im:message:recall
    im:message:update
    minutes:minutes
    search:message
    vc:meeting.bot.manage:write
    vc:meeting.interaction:write
    vc:meeting.message:write
    vc:room:readonly
  )

  # Whether the app is available to a person who asks for a station tool
  # (`SalixIM.Provider.Lark.AppAvailability`), as on Feishu.
  @station_scopes ~w(
    application:application:self_manage
  )

  @doc "The presets to show. Lark has one."
  @spec import_cards() :: [map()]
  def import_cards do
    [
      %{
        id: "bot",
        title: "Lark bot",
        description:
          "App-identity permissions for messaging, directory access, meetings, approval processing, documents, and Minutes, and the user permissions of a Lark account sign-in.",
        json: import_json(),
        required_scopes: required_scope_ids()
      }
    ]
  end

  @doc "The batch-import JSON of the Lark Developer Console."
  @spec import_json() :: String.t()
  def import_json, do: Jason.encode!(import_payload(), pretty: true)

  @spec import_payload() :: map()
  def import_payload,
    do: %{
      "scopes" => %{
        "tenant" => required_scope_ids(),
        "user" => Enum.uniq(@declared_user_scopes ++ user_scope_ids() ++ on_demand_user_scopes())
      }
    }

  @spec required_scope_ids() :: [String.t()]
  def required_scope_ids,
    do:
      @messaging_scopes ++ @approval_scopes ++ @document_scopes ++ @work_scopes ++ @station_scopes

  @doc "The scopes a person grants when they sign in for the bot."
  @spec user_scope_ids() :: [String.t()]
  def user_scope_ids, do: SalixStore.OAuth.Adapters.Lark.default_scopes()

  @doc """
  The user scopes a person grants only when a need asks for them (table
  reads, document edits). The import offers them, so a sign-in that asks for
  them is not refused.
  """
  @spec on_demand_user_scopes() :: [String.t()]
  def on_demand_user_scopes,
    do:
      SalixStore.OAuth.Adapters.Lark.on_demand_scopes()
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

  @spec document_scope_ids() :: [String.t()]
  def document_scope_ids, do: @document_scopes
end
