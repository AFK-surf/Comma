defmodule SalixIM.SlackScopes do
  @moduledoc """
  Shared Slack bot OAuth scopes for generated app manifests and install URLs.
  """

  @bot ~w(
    app_mentions:read
    canvases:read
    canvases:write
    channels:history
    channels:join
    channels:manage
    channels:read
    chat:write
    emoji:read
    files:read
    files:write
    groups:history
    groups:read
    groups:write
    im:history
    im:read
    im:write
    mpim:history
    mpim:read
    metadata.message:read
    pins:read
    pins:write
    reactions:read
    reactions:write
    users:read
    users:read.email
    users.profile:read
  )

  @spec bot() :: [String.t()]
  def bot, do: @bot

  @spec bot_scope() :: String.t()
  def bot_scope, do: Enum.join(@bot, ",")
end
