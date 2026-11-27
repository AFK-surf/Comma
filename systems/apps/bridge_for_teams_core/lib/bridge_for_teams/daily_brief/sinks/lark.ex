defmodule BridgeForTeams.DailyBrief.Sinks.Lark do
  @moduledoc """
  Draws a brief as a Lark interactive card. The implementation is
  `Sinks.LarkSuite`; see it for the card's layout.
  """

  alias BridgeForTeams.DailyBrief.Sinks.LarkSuite

  def render_personal(title, text, footer \\ nil),
    do: LarkSuite.render_personal(title, text, footer)

  def render_team(title, text, read \\ nil), do: LarkSuite.render_team(title, text, read)
end
