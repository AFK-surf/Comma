defmodule BridgeForTeams.DailyBrief.ActorRef do
  @moduledoc """
  A person or bot in daily brief rows, qualified by its source:
  `"slack:U123"`. Only a source adapter builds or reads the part after the
  source; the core compares refs as opaque strings.
  """

  @type t :: String.t()

  @doc "The ref of a Slack user or bot id, or `nil`."
  @spec slack(String.t() | nil) :: t() | nil
  def slack(id) when is_binary(id) and id != "", do: "slack:" <> id
  def slack(_id), do: nil

  @doc "The Slack id of a Slack ref, or `nil` for another source."
  @spec slack_id(t() | nil) :: String.t() | nil
  def slack_id("slack:" <> id) when id != "", do: id
  def slack_id(_ref), do: nil
end
