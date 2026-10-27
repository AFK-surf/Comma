defmodule SalixIM.DailyBriefSurface do
  @moduledoc """
  The BFT daily brief in Slack: one direct message per member from the
  Swarm's bot, and the team brief in one public channel. The brief is
  rendered by BFT as trusted product blocks.
  """

  alias SalixIM.Provider.Slack, as: SlackProvider
  alias SalixIM.ProviderConnects

  @doc "Posts one brief into the member's direct conversation with the Swarm's bot."
  @spec post(map()) :: {:ok, map()} | {:error, term()}
  def post(%{
        tenant_id: tenant_id,
        group_id: group_id,
        connect_id: connect_id,
        slack_user_id: user_id,
        text: text,
        blocks: blocks
      })
      when is_binary(user_id) and is_binary(text) and is_list(blocks) do
    with {:ok, connect} <- connect(tenant_id, group_id, connect_id),
         {:ok, response} <-
           SlackProvider.post_direct_surface(tenant_id, connect, user_id, text, blocks) do
      {:ok, %{channel_id: response["channel"], ts: response["ts"]}}
    end
  end

  # The team brief goes to one public channel the bot is in.
  def post(%{
        tenant_id: tenant_id,
        group_id: group_id,
        connect_id: connect_id,
        channel_id: channel_id,
        text: text,
        blocks: blocks
      })
      when is_binary(channel_id) and is_binary(text) and is_list(blocks) do
    with {:ok, connect} <- connect(tenant_id, group_id, connect_id),
         :ok <- SalixIM.DailyBriefSource.channel_readable(connect, channel_id),
         {:ok, response} <-
           SlackProvider.post_channel_surface(tenant_id, connect, channel_id, text, blocks) do
      {:ok, %{channel_id: response["channel"], ts: response["ts"]}}
    end
  rescue
    error in SalixIM.Provider.Slack.API.Error -> {:error, Exception.message(error)}
  end

  def post(_request), do: {:error, :invalid_request}

  defp connect(tenant_id, group_id, connect_id) do
    case ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack") do
      {:ok, %{"tenant_id" => ^tenant_id} = connect} -> {:ok, connect}
      {:ok, _other} -> {:error, :source_unavailable}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end
end
