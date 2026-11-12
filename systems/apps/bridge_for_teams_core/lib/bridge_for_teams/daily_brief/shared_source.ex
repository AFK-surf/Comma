defmodule BridgeForTeams.DailyBrief.SharedSource do
  @moduledoc """
  Reads one time window of the shared Slack stream for a daily brief run.

  The stream is every public, non-shared channel that the Swarm's Slack bot
  belongs to, read from the Salix Slack mirror. Nothing here is stored: the
  result is the input of a brief, with per-member relevance and an honest
  coverage report. A channel that fails or runs out of page budget is named in
  the coverage, never silently dropped. `members:` are the members whose
  messages are picked out (`relevant`); the team brief reads with none.
  """

  alias BridgeForTeams.DailyBrief.{Classifier, Focus, Members}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting}

  @page_limit 200
  # Main-channel talk a member was not part of, newest kept: the messages
  # that concern them always go in, and the model stays within its time.
  @max_channel_only 250
  @default_page_budget 500
  # The most threads one member lookup takes.
  @thread_batch 500

  @type window :: %{after: DateTime.t(), before: DateTime.t()}

  @spec read(DailyBriefSetting.t(), window(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(%DailyBriefSetting{} = settings, %{after: after_at, before: before_at}, opts \\ []) do
    members = Keyword.get_lazy(opts, :members, fn -> Members.enabled(settings.org_id) end)
    budget = Keyword.get(opts, :page_budget, @default_page_budget)
    after_us = DateTime.to_unix(after_at, :microsecond)
    before_us = DateTime.to_unix(before_at, :microsecond)

    with {:ok, source} <- Members.source(settings),
         {:ok, channels} <-
           Salix.impl().daily_brief_channels(Map.put(source, :member_slack_ids, [])) do
      {messages, read_report} =
        read_channels(source, channels.channels, after_us, before_us, budget)

      focus =
        Focus.for_members(source, members, Enum.map(channels.channels, & &1.id), before_at)

      {matchers, thread_report} = matchers(source, members, messages, focus)

      {:ok,
       %{
         window: %{after: after_at, before: before_at},
         messages: messages,
         relevant: relevant(messages, members, matchers),
         coverage:
           Map.merge(read_report, %{
             channels_total: length(channels.channels),
             channel_list_complete?: channels.complete?,
             threads_complete: thread_report
           })
       }}
    end
  end

  @doc """
  Whether every channel was read in full and every member's thread list was
  complete.
  """
  @spec complete?(map()) :: boolean()
  def complete?(%{complete?: complete?}), do: complete?

  def complete?(coverage) do
    coverage.channel_list_complete? and coverage.failed == [] and coverage.truncated == [] and
      coverage.channels_read == coverage.channels_total and
      Enum.all?(Map.values(coverage.threads_complete))
  end

  defp read_channels(source, channels, after_us, before_us, budget) do
    {messages, report, _budget} =
      Enum.reduce(channels, {[], %{channels_read: 0, failed: [], truncated: []}, budget}, fn
        channel, {messages, report, 0} ->
          {messages, %{report | truncated: report.truncated ++ [channel]}, 0}

        channel, {messages, report, budget} ->
          case read_channel(source, channel.id, after_us, before_us, nil, budget, []) do
            {:ok, rows, left} ->
              {messages ++ rows, %{report | channels_read: report.channels_read + 1}, left}

            {:truncated, rows, left} ->
              {messages ++ rows, %{report | truncated: report.truncated ++ [channel]}, left}

            {:error, reason, left} ->
              {messages, %{report | failed: report.failed ++ [Map.put(channel, :reason, reason)]},
               left}
          end
      end)

    {messages, report}
  end

  defp read_channel(_source, _channel_id, _after_us, _before_us, _cursor, 0, rows),
    do: {:truncated, rows, 0}

  defp read_channel(source, channel_id, after_us, before_us, cursor, budget, rows) do
    request =
      Map.merge(source, %{
        channel_id: channel_id,
        after_us: after_us,
        before_us: before_us,
        limit: @page_limit,
        cursor: cursor
      })

    case Salix.impl().daily_brief_read_window(request) do
      {:ok, %{messages: page, has_more?: true, next_cursor: next}} when not is_nil(next) ->
        read_channel(source, channel_id, after_us, before_us, next, budget - 1, rows ++ page)

      {:ok, %{messages: page}} ->
        {:ok, rows ++ page, budget - 1}

      {:error, reason} ->
        {:error, reason, budget - 1}
    end
  end

  # A member's threads are the window's threads they wrote in, at any time:
  # one lookup per batch of the window's thread roots.
  defp matchers(source, members, messages, focus) do
    threads =
      for %{thread_ts: ts} = message <- messages,
          is_binary(ts),
          uniq: true,
          do: %{channel_id: message.channel_id, thread_ts: ts}

    Enum.reduce(members, {%{}, %{}}, fn %DailyBriefMember{} = member, {matchers, report} ->
      {wrote, complete?} = member_threads(source, member, threads)
      aliases = Enum.map(member.aliases, &%{term: &1.term, kind: &1.kind})

      channels = Map.get(focus, member.id, Focus.none())

      {Map.put(
         matchers,
         member.id,
         Classifier.member(member.slack_user_id, aliases, wrote, channels)
       ), Map.put(report, member.id, complete?)}
    end)
  end

  defp member_threads(source, member, threads) do
    threads
    |> Enum.chunk_every(@thread_batch)
    |> Enum.reduce({[], true}, fn batch, {wrote, complete?} ->
      case Salix.impl().daily_brief_member_threads(
             Map.merge(source, %{slack_user_id: member.slack_user_id, threads: batch})
           ) do
        {:ok, %{threads: found}} -> {wrote ++ found, complete?}
        {:error, _reason} -> {wrote, false}
      end
    end)
  end

  defp cap_channel_only(picked) do
    {channel_only, rest} = Enum.split_with(picked, &(&1.reasons == [:channel]))

    if length(channel_only) <= @max_channel_only do
      picked
    else
      kept =
        channel_only
        |> Enum.sort_by(&ts_value(&1.message.ts), :desc)
        |> Enum.take(@max_channel_only)
        |> MapSet.new(&{&1.message.channel_id, &1.message.ts})

      Enum.filter(picked, fn entry ->
        entry in rest or MapSet.member?(kept, {entry.message.channel_id, entry.message.ts})
      end)
    end
  end

  defp ts_value(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp ts_value(_ts), do: 0.0

  defp relevant(messages, members, matchers) do
    Map.new(members, fn member ->
      matcher = Map.fetch!(matchers, member.id)

      picked =
        for message <- messages,
            reasons = Classifier.reasons(message, matcher),
            tier = Classifier.tier(reasons),
            not is_nil(tier),
            do: %{message: message, reasons: reasons, tier: tier}

      {member.id, cap_channel_only(picked)}
    end)
  end
end
