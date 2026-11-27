defmodule BridgeForTeams.DailyBrief.Focus do
  @moduledoc """
  A member's main channels (Slack channels, or Feishu and Lark groups): the
  channels whose human messages all reach their brief, not only the ones
  that name them.

  By default they are the public channels the member wrote most in over the
  last 14 days (at most 6, each with at least 5 of their messages), so nobody
  has to choose. A member changes them by asking the Swarm's bot
  (`ChatSettings`), kept as aliases: `channel` adds a channel, `channel_bots`
  adds one with its bot messages too (an alerts channel), and `channel_off`
  drops a default one. Terms are channel ids.
  """

  alias BridgeForTeams.DailyBrief.{ActorRef, Sources}
  alias BridgeForTeams.Salix.Client, as: Salix

  @lookback_days 14
  @max_default 6
  @min_messages 5
  @min_window_messages 3
  @max_window_default 3

  @kinds ~w(channel channel_bots channel_off)

  @type t :: %{humans: MapSet.t(String.t()), bots: MapSet.t(String.t())}

  @doc "The alias kinds that hold a member's channel choices."
  def kinds, do: @kinds

  @doc """
  Each member's main channels, by member id. `channel_ids` are the run's
  readable channels; a choice outside them is ignored. `window_messages`
  adds channels where the member wrote #{@min_window_messages} or more human
  messages in the current window, so a newly created channel enters focus on
  its first day. Best effort: when the activity read fails, members keep
  their choices and current-window channels.
  """
  @spec for_members(map(), [map()], [String.t()], DateTime.t(), [map()], String.t() | nil) ::
          %{term() => t()}
  def for_members(source, members, channel_ids, now, window_messages \\ [], app_id \\ nil)
  def for_members(_source, [], _channel_ids, _now, _window_messages, _app_id), do: %{}

  # `app_id` is the Feishu or Lark app the source reads through: members are
  # named by their open id there, and one it does not know has only choices.
  def for_members(source, members, channel_ids, now, window_messages, app_id) do
    after_us = now |> DateTime.add(-@lookback_days * 86_400) |> DateTime.to_unix(:microsecond)
    request = Sources.active_request(source, members, channel_ids, after_us, app_id)
    ids = request[:slack_user_ids] || request[:open_ids] || []

    active =
      with [_ | _] <- ids,
           {:ok, active} when is_map(active) <-
             Salix.impl().daily_brief_active_channels(request) do
        active
      else
        _unavailable -> %{}
      end

    window_by_user = window_channel_counts(window_messages)
    readable = MapSet.new(channel_ids)

    Map.new(members, fn member ->
      id = ActorRef.member_actor_id(member, app_id)

      {member.id,
       of(member, Map.get(active, id, []), readable, Map.get(window_by_user, id || "", %{}))}
    end)
  end

  @doc "One member's main channels from their channel activity and choices."
  @spec of(map(), [%{channel_id: String.t(), count: non_neg_integer()}], MapSet.t(), map()) :: t()
  def of(member, activity, readable, window_counts \\ %{}) do
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

    window_defaults =
      window_counts
      |> Enum.filter(fn {id, count} ->
        count >= @min_window_messages and MapSet.member?(readable, id)
      end)
      |> Enum.sort_by(fn {_id, count} -> -count end)
      |> Enum.take(@max_window_default)
      |> MapSet.new(&elem(&1, 0))

    humans =
      defaults
      |> MapSet.union(window_defaults)
      |> MapSet.union(added)
      |> MapSet.union(bots)
      |> MapSet.difference(off)
      |> MapSet.intersection(readable)

    %{humans: humans, bots: MapSet.intersection(bots, readable)}
  end

  defp window_channel_counts(messages) when is_list(messages) do
    Enum.reduce(messages, %{}, fn message, acc ->
      actor = message[:actor_id]
      channel = message[:channel_id]

      if message[:actor_kind] != "bot" and is_binary(actor) and is_binary(channel) do
        Map.update(acc, actor, %{channel => 1}, &Map.update(&1, channel, 1, fn n -> n + 1 end))
      else
        acc
      end
    end)
  end

  defp window_channel_counts(_messages), do: %{}

  @doc "No main channels."
  def none, do: %{humans: MapSet.new(), bots: MapSet.new()}
end
