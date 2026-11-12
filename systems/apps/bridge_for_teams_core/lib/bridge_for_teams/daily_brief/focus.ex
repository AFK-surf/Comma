defmodule BridgeForTeams.DailyBrief.Focus do
  @moduledoc """
  A member's main channels: the channels whose human messages all reach their
  brief, not only the ones that name them.

  By default they are the public channels the member wrote most in over the
  last 14 days (at most 6, each with at least 5 of their messages), so nobody
  has to choose. A member changes them by asking the Swarm's bot
  (`ChatSettings`), kept as aliases: `channel` adds a channel, `channel_bots`
  adds one with its bot messages too (an alerts channel), and `channel_off`
  drops a default one. Terms are channel ids.
  """

  alias BridgeForTeams.Salix.Client, as: Salix

  @lookback_days 14
  @max_default 6
  @min_messages 5

  @kinds ~w(channel channel_bots channel_off)

  @type t :: %{humans: MapSet.t(String.t()), bots: MapSet.t(String.t())}

  @doc "The alias kinds that hold a member's channel choices."
  def kinds, do: @kinds

  @doc """
  Each member's main channels, by member id. `channel_ids` are the run's
  readable channels; a choice outside them is ignored. Best effort: when the
  activity read fails, members keep only the channels they chose.
  """
  @spec for_members(map(), [map()], [String.t()], DateTime.t()) :: %{term() => t()}
  def for_members(_source, [], _channel_ids, _now), do: %{}

  def for_members(source, members, channel_ids, now) do
    after_us = now |> DateTime.add(-@lookback_days * 86_400) |> DateTime.to_unix(:microsecond)

    active =
      case Salix.impl().daily_brief_active_channels(
             Map.merge(source, %{
               slack_user_ids: Enum.map(members, & &1.slack_user_id),
               channel_ids: channel_ids,
               after_us: after_us
             })
           ) do
        {:ok, active} when is_map(active) -> active
        _unavailable -> %{}
      end

    readable = MapSet.new(channel_ids)
    Map.new(members, &{&1.id, of(&1, Map.get(active, &1.slack_user_id, []), readable)})
  end

  @doc "One member's main channels from their channel activity and choices."
  @spec of(map(), [%{channel_id: String.t(), count: non_neg_integer()}], MapSet.t()) :: t()
  def of(member, activity, readable) do
    choices = for %{kind: kind, term: term} <- member.aliases, kind in @kinds, do: {kind, term}
    off = for {"channel_off", id} <- choices, into: MapSet.new(), do: id
    bots = for {"channel_bots", id} <- choices, into: MapSet.new(), do: id
    added = for {"channel", id} <- choices, into: MapSet.new(), do: id

    defaults =
      activity
      |> Enum.filter(&(&1.count >= @min_messages and MapSet.member?(readable, &1.channel_id)))
      |> Enum.sort_by(&(-&1.count))
      |> Enum.take(@max_default)
      |> MapSet.new(& &1.channel_id)

    humans =
      defaults
      |> MapSet.union(added)
      |> MapSet.union(bots)
      |> MapSet.difference(off)
      |> MapSet.intersection(readable)

    %{humans: humans, bots: MapSet.intersection(bots, readable)}
  end

  @doc "No main channels."
  def none, do: %{humans: MapSet.new(), bots: MapSet.new()}
end
