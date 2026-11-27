defmodule BridgeForTeams.DailyBrief.Sources.Lark do
  @moduledoc """
  The Lark adapter of the daily brief, with the functions of
  `Sources.Slack`. The implementation is `Sources.LarkSuite`.
  """

  alias BridgeForTeams.DailyBrief.Sources.LarkSuite

  @provider "lark"

  def permalinks(items, settings), do: LarkSuite.permalinks(@provider, items, settings)
  def shared_item(message), do: LarkSuite.shared_item(@provider, message)
  def mentions(text), do: LarkSuite.mentions(@provider, text)
  def label_text(text, people), do: LarkSuite.label_text(@provider, text, people)
  def mention_people(text, people), do: LarkSuite.mention_people(@provider, text, people)
  def conversation(item, names), do: LarkSuite.conversation(item, names)

  def thread_roots(settings, items, after_at),
    do: LarkSuite.thread_roots(settings, items, after_at)

  def channel_names(settings, shared), do: LarkSuite.channel_names(settings, shared)
  def channel_names(settings), do: LarkSuite.channel_names(settings)
  def user_names(refs, settings), do: LarkSuite.user_names(@provider, refs, settings)

  @doc "Lark gives the bot no link that opens one message; the preview link opens its chat."
  def deep_link(_item, _team), do: nil
end
