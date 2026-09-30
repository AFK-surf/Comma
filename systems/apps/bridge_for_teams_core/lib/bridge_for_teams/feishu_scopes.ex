defmodule BridgeForTeams.FeishuScopes do
  @moduledoc """
  Source of truth for Feishu app permission scopes shown during onboarding.

  Keep these strings aligned with Feishu Open Platform's current scope catalog.
  The dashboard renders them as copyable batch-import JSON so admins do not have
  to infer required permissions from scattered setup notes.

  The required `im:message.group_msg` scope enables app-identity group history
  and may deliver every subscribed group message. Salix filters group messages
  that do not mention the bot before routing them to an agent.
  """

  @sso_user_scopes ~w(
    contact:user.base:readonly
  )

  @bot_tenant_scopes ~w(
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
  )

  @optional_bot_scopes [
    %{
      scope: "im:message.group_at_msg.include_bot:readonly",
      label: "Receive @mentions sent by other bots",
      note: "Only needed for bot-to-bot workflows; human @Bridge messages do not require it."
    }
  ]

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
        description: "Use when the app only powers the Feishu group bot.",
        json: import_json(:bot),
        required_scopes: required_scope_ids(:bot)
      },
      %{
        id: "combined",
        title: "SSO + group bot",
        description: "Recommended for the normal Bridge For Teams onboarding flow.",
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
    %{"scopes" => %{"tenant" => @bot_tenant_scopes, "user" => @sso_user_scopes}}
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

  @spec optional_bot_scopes() :: [map()]
  def optional_bot_scopes, do: @optional_bot_scopes

  @spec known_invalid_scopes() :: [String.t()]
  def known_invalid_scopes, do: @known_invalid_scopes
end
