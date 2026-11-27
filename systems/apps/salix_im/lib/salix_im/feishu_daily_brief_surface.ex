defmodule SalixIM.FeishuDailyBriefSurface do
  @moduledoc """
  The BFT daily brief in Feishu: one card per member from the Swarm's bot
  (`open_id`), and the team brief card in one internal public group
  (`channel_id`) that the bot is in. BFT renders the card.
  """

  alias SalixIM.LarkSuiteDailyBrief, as: Brief

  @spec post(map()) :: {:ok, map()} | {:error, term()}
  def post(request), do: Brief.post(SalixIM.FeishuDailyBriefSource.provider(), request)
end
