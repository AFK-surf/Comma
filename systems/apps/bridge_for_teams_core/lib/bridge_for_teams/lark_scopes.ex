defmodule BridgeForTeams.LarkScopes do
  @moduledoc """
  The permission scopes a Lark app needs for its bot.

  The Swarm Connections page and `bft lark scopes` show them as one JSON for
  the batch import of the Lark Developer Console (Permissions & Scopes). The
  bot's scopes are for the app's own identity (`tenant`). The `user` scopes
  are what a person grants when they sign in so the bot can read meetings,
  meeting notes, recordings and documents as them
  (`SalixStore.OAuth.Adapters.Lark`).

  Keep the names equal to the scope catalog of the Lark open platform
  (`open.larksuite.com`). A scope takes effect with the next published
  version of the app.

  `im:message.group_msg` lets Lark deliver every message of a group. Without
  it only a message that mentions the bot arrives, so a thread cannot go on
  without a mention and only mentions are recorded.
  """

  # Messages, files, chats, and the directory reads of `lark.get_user`,
  # `lark.list_contact_scopes` and the department operations.
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
  )

  # Cloud documents and Minutes, read and edited as the bot
  # (`SalixIM.Provider.Lark.Docs`, `SalixIM.Provider.Lark.Minutes`). Lark
  # lists wiki spaces and nodes with the two `retrieve` scopes.
  @document_scopes ~w(
    docx:document
    docx:document:readonly
    docx:document:create
    docx:document:write_only
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
    space:document:delete
    minutes:minutes.basic:read
    minutes:minutes.artifacts:read
    minutes:minutes.media:export
    minutes:minutes.search:read
    minutes:permission:apply
  )

  @doc "The presets to show. Lark has one."
  @spec import_cards() :: [map()]
  def import_cards do
    [
      %{
        id: "bot",
        title: "Lark bot",
        description:
          "App-identity permissions for messaging, directory access, documents, and Minutes, and the user permissions of a Lark account sign-in.",
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
    do: %{"scopes" => %{"tenant" => required_scope_ids(), "user" => user_scope_ids()}}

  @spec required_scope_ids() :: [String.t()]
  def required_scope_ids, do: @messaging_scopes ++ @document_scopes

  @doc "The scopes a person grants when they sign in for the bot."
  @spec user_scope_ids() :: [String.t()]
  def user_scope_ids, do: SalixStore.OAuth.Adapters.Lark.default_scopes()

  @spec document_scope_ids() :: [String.t()]
  def document_scope_ids, do: @document_scopes
end
