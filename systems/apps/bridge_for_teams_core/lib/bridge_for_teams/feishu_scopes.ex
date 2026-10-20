defmodule BridgeForTeams.FeishuScopes do
  @moduledoc """
  Source of truth for Feishu app permission scopes shown during onboarding.

  Keep these strings aligned with Feishu Open Platform's current scope catalog.
  The dashboard renders them as copyable batch-import JSON so admins do not have
  to infer required permissions from scattered setup notes.

  The default bot import includes app-identity directory, meeting-bot, and
  approval permissions. The combined import also includes user-identity search,
  Minutes, calendar, documents, Base, whiteboard, tasks, mail, and OKR permissions.
  These presets include writes, mail sending, and approval processing.
  Existing apps must import the updated JSON and publish a new app version.

  App permission declarations do not grant user consent or record access.
  User-identity tools need a separate authorization flow and credential.
  BFT SSO still requests identity access and does not retain tokens for Agent tools.
  The hosted Feishu MCP has separate OAuth and tool scopes.
  A scope in this catalog does not install its corresponding tool.
  The SSO-only import keeps its identity-only permissions.

  The combined import also names the user scopes of a Feishu account sign-in
  (`SalixStore.OAuth.Adapters.Feishu`): with them the bot reads meetings,
  meeting notes, recordings and documents as the person who signed in.

  The bot import also includes the cloud-document and Minutes permissions that
  Routers and Workers use as the bot (`SalixIM.Provider.Feishu.Docs` and
  `SalixIM.Provider.Feishu.Minutes`). These are separate from the same reads
  under user identity in the combined import.

  The required `im:message.group_msg` scope enables app-identity group history
  and may deliver every subscribed group message. Salix filters group messages
  that do not mention the bot before routing them to an agent.
  """

  @sso_user_scopes ~w(
    contact:user.base:readonly
  )

  @default_user_scopes ~w(
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

  @bot_messaging_scopes ~w(
    im:message:send_as_bot
    im:message.group_at_msg:readonly
    im:message.p2p_msg:readonly
    im:message:readonly
    im:message.group_msg
    im:chat:read
    im:chat.members:read
    im:message:update
    im:message:recall
    im:message.reactions:read
    im:message.reactions:write_only
    im:message.pins:read
    im:message.pins:write_only
    im:resource
    contact:contact.base:readonly
    contact:user.base:readonly
    contact:department.base:readonly
    im:message.group_at_msg.include_bot:readonly
    contact:user.email:readonly
    contact:user.department:readonly
    vc:meeting.bot.join:write
    vc:meeting.bot.manage:write
    vc:meeting.interaction:write
    vc:meeting.message:write
    vc:meeting.meetingevent:read
    approval:approval.list:readonly
    approval:instance
    approval:task
  )

  # Cloud documents read and edited, and Minutes read, as the bot by Routers
  # and Workers. The names follow the official Lark CLI.
  @bot_document_scopes ~w(
    docx:document
    docx:document:readonly
    docx:document:create
    docx:document:write_only
    wiki:node:read
    wiki:space:read
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
    space:document:delete
    minutes:minutes.basic:read
    minutes:minutes.artifacts:read
    minutes:minutes.media:export
    minutes:minutes.search:read
    minutes:permission:apply
  )

  @bot_tenant_scopes @bot_messaging_scopes ++ @bot_document_scopes

  @known_invalid_scopes ~w(
    im:message.history:readonly
    im:chat.member:readonly
    im:resource:upload
  )

  @type flow :: :sso | :bot | :combined

  @spec import_cards() :: [map()]
  def import_cards do
    [
      %{
        id: "sso",
        title: "SSO login",
        description: "Use when the app only signs users into Bridge For Teams.",
        json: import_json(:sso),
        required_scopes: required_scope_ids(:sso)
      },
      %{
        id: "bot",
        title: "Group bot",
        description:
          "App-identity permissions for messaging, directory access, meetings, approval processing, documents, and Minutes.",
        json: import_json(:bot),
        required_scopes: required_scope_ids(:bot)
      },
      %{
        id: "combined",
        title: "SSO + group bot",
        description:
          "Default integration permissions, including editing, sending mail, and processing approvals.",
        json: import_json(:combined),
        required_scopes: required_scope_ids(:combined)
      }
    ]
  end

  @spec import_json(flow()) :: String.t()
  def import_json(flow) do
    flow
    |> import_payload()
    |> Jason.encode!(pretty: true)
  end

  @spec import_payload(flow()) :: map()
  def import_payload(:sso) do
    %{"scopes" => %{"user" => @sso_user_scopes}}
  end

  def import_payload(:bot) do
    %{"scopes" => %{"tenant" => @bot_tenant_scopes}}
  end

  def import_payload(:combined) do
    %{
      "scopes" => %{
        "tenant" => @bot_tenant_scopes,
        "user" => Enum.uniq(@sso_user_scopes ++ @default_user_scopes ++ sign_in_user_scopes())
      }
    }
  end

  @spec required_scope_ids(flow()) :: [String.t()]
  def required_scope_ids(flow) do
    flow
    |> import_payload()
    |> get_in(["scopes"])
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "The scopes a person grants when they sign in for the bot."
  @spec sign_in_user_scopes() :: [String.t()]
  def sign_in_user_scopes, do: SalixStore.OAuth.Adapters.Feishu.default_scopes()

  @spec document_scope_ids() :: [String.t()]
  def document_scope_ids, do: @bot_document_scopes

  @spec optional_bot_scopes() :: [map()]
  def optional_bot_scopes, do: []

  @spec known_invalid_scopes() :: [String.t()]
  def known_invalid_scopes, do: @known_invalid_scopes
end
