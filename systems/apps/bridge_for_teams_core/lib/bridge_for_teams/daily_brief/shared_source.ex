defmodule BridgeForTeams.DailyBrief.SharedSource do
  @moduledoc """
  Reads one time window of the shared stream for a daily brief run.

  The stream is every public, non-shared Slack channel that the Swarm's
  Slack bot belongs to, or every internal public Feishu or Lark group its
  bot belongs to, read from the provider's Salix message mirror. A brief
  that reads several Swarms (`Scope`) reads each Swarm's stream through its
  own bot, each group or channel once. Nothing here is stored: the
  result is the input of a brief, with per-member relevance and an honest
  coverage report. A channel that fails or runs out of page budget is named in
  the coverage, never silently dropped. `members:` are the members whose
  messages are picked out (`relevant`); the team brief reads with none.
  """

  alias BridgeForTeams.DailyBrief.{ActorRef, Classifier, Focus, Members, SourceItem, Sources}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting}

  @page_limit 200
  # Main-channel talk a member was not part of, newest kept: the messages
  # that concern them always go in, and the model stays within its time.
  @max_channel_only 250
  @default_page_budget 500
  @rate_limit_retries 3
  @max_rate_limit_wait 30
  # The most threads one member lookup takes.
  @thread_batch 500

  @type window :: %{after: DateTime.t(), before: DateTime.t()}

  @doc """
  Reads the window of one Swarm (`settings`), or of a scope: a list of
  settings, the sending Swarm first (`Scope`). A group or channel that two
  Swarms' bots both read is read once, through the first. Each source's
  messages are matched to the members by the id its app knows them by;
  then a member's Feishu or Lark open id in another app is written as their
  open id in the first Swarm's app (`app_id`), so the brief names them as
  the bot that sends it knows them.
  """
  @spec read(DailyBriefSetting.t() | [DailyBriefSetting.t()], window(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def read(settings_or_scope, window, opts \\ [])

  def read(%DailyBriefSetting{} = settings, window, opts), do: read([settings], window, opts)

  def read([%DailyBriefSetting{} = settings | _] = scope, window, opts) do
    members = Keyword.get_lazy(opts, :members, fn -> Members.enabled(settings) end)
    budget = Keyword.get(opts, :page_budget, @default_page_budget)

    with {:ok, [head | rest]} <- list_sources(scope) do
      {parts, _seen, _budget} =
        Enum.reduce([head | rest], {[], MapSet.new(), budget}, fn
          %{unreadable: failed}, {parts, seen, budget} ->
            {parts ++ [unreadable_part(failed)], seen, budget}

          source, {parts, seen, budget} ->
            channels = Enum.reject(source.channels, &MapSet.member?(seen, &1.id))
            seen = Enum.reduce(channels, seen, &MapSet.put(&2, &1.id))

            {part, budget} =
              read_source(%{source | channels: channels}, members, window, budget, head.app_id)

            {parts ++ [part], seen, budget}
        end)

      {:ok, merge(parts, members, window, head)}
    end
  end

  # Each settings' Salix source and channel list. The sending Swarm's must
  # answer; another Swarm whose bot cannot be read is named in the
  # coverage's `failed`, by its Swarm id.
  defp list_sources([settings | rest]) do
    with {:ok, head} <- list_source(settings) do
      others =
        Enum.map(rest, fn other ->
          case list_source(other) do
            {:ok, source} ->
              source

            {:error, reason} ->
              %{source: nil, unreadable: %{id: other.project_id, name: "", reason: reason}}
          end
        end)

      {:ok, [head | others]}
    end
  end

  defp list_source(settings) do
    with {:ok, source} <- Members.source(settings),
         {:ok, channels} <-
           Salix.impl().daily_brief_channels(Sources.channels_request(source)) do
      {:ok,
       %{
         settings: settings,
         source: source,
         app_id: if(is_binary(channels[:app_id]), do: channels[:app_id]),
         channels: channels.channels,
         complete?: channels.complete?
       }}
    end
  end

  defp read_source(source, members, %{after: after_at, before: before_at}, budget, head_app) do
    after_us = DateTime.to_unix(after_at, :microsecond)
    before_us = DateTime.to_unix(before_at, :microsecond)

    {messages, read_report, budget} =
      read_channels(source.source, source.channels, after_us, before_us, budget)

    focus =
      Focus.for_members(
        source.source,
        members,
        Enum.map(source.channels, & &1.id),
        before_at,
        messages,
        source.app_id
      )

    {matchers, thread_report} = matchers(source, members, messages, focus)
    messages = maybe_attach_jev_recall(source, messages, members, matchers)
    relevant = relevant(messages, members, matchers)
    rename = renames(source, members, head_app)

    channel_source = %{
      settings: source.settings,
      source: source.source,
      app_id: source.app_id
    }

    {%{
       messages: Enum.map(messages, &rename_message(&1, rename)),
       relevant:
         Map.new(relevant, fn {id, picked} ->
           {id, Enum.map(picked, &%{&1 | message: rename_message(&1.message, rename)})}
         end),
       channel_names: Map.new(source.channels, &{&1.id, &1.name}),
       channel_sources: Map.new(source.channels, &{&1.id, channel_source}),
       report: read_report,
       channels_total: length(source.channels),
       complete?: source.complete?,
       threads: thread_report
     }, budget}
  end

  defp unreadable_part(failed) do
    %{
      messages: [],
      relevant: %{},
      channel_names: %{},
      channel_sources: %{},
      report: %{channels_read: 0, failed: [failed], truncated: []},
      channels_total: 0,
      complete?: true,
      threads: %{}
    }
  end

  @doc """
  Renames a Feishu or Lark `SourceItem` read through `source_app` so that
  known members use their open id in `head_app`. No-op for Slack or when
  both apps match.
  """
  @spec rename_item(SourceItem.t(), String.t() | nil, String.t() | nil, [DailyBriefMember.t()]) ::
          SourceItem.t()
  def rename_item(%SourceItem{source: provider} = item, source_app, head_app, members)
      when provider in ["feishu", "lark"] and is_binary(source_app) and is_binary(head_app) and
             source_app != head_app do
    rename = member_renames(source_app, head_app, members)

    if map_size(rename) == 0 do
      item
    else
      %SourceItem{
        item
        | author: rename_ref(item.author, provider, rename),
          mentions: Enum.map(item.mentions, &rename_ref(&1, provider, rename)),
          text: rename_text(item.text, rename),
          origin:
            if(is_map(item.origin), do: rename_message(item.origin, rename), else: item.origin)
      }
    end
  end

  def rename_item(item, _source_app, _head_app, _members), do: item

  # The open ids of members in the source's app, by their open id in the
  # sending Swarm's app. Slack ids are the workspace's: nothing to rename.
  defp renames(%{source: source, app_id: app_id}, members, head_app)
       when is_binary(app_id) and is_binary(head_app) and app_id != head_app do
    if Sources.slack?(source), do: %{}, else: member_renames(app_id, head_app, members)
  end

  defp renames(_source, _members, _head_app), do: %{}

  defp member_renames(app_id, head_app, members) do
    for member <- members,
        from = ActorRef.member_actor_id(member, app_id),
        to = ActorRef.member_actor_id(member, head_app),
        is_binary(from) and is_binary(to) and from != to,
        into: %{},
        do: {from, to}
  end

  defp rename_ref(ref, provider, rename) do
    case ActorRef.id_of(provider, ref) do
      nil -> ref
      id -> ActorRef.of(provider, Map.get(rename, id, id))
    end
  end

  defp rename_message(message, rename) when map_size(rename) == 0, do: message

  defp rename_message(message, rename) do
    message
    |> Map.update(:actor_id, nil, &Map.get(rename, &1, &1))
    |> then(fn message ->
      if is_list(message[:mentions]),
        do:
          Map.update!(message, :mentions, fn ids -> Enum.map(ids, &Map.get(rename, &1, &1)) end),
        else: message
    end)
    |> then(fn message ->
      if is_binary(message[:text]),
        do: Map.update!(message, :text, &rename_text(&1, rename)),
        else: message
    end)
  end

  defp rename_text(text, rename) when is_binary(text) do
    Regex.replace(~r/<@(ou_[A-Za-z0-9_-]{2,64})>/, text, fn whole, id ->
      case rename do
        %{^id => to} -> "<@#{to}>"
        _other -> whole
      end
    end)
  end

  defp rename_text(text, _rename), do: text

  defp merge(parts, members, window, head) do
    report = %{
      channels_read: Enum.sum(Enum.map(parts, & &1.report.channels_read)),
      failed: Enum.flat_map(parts, & &1.report.failed),
      truncated: Enum.flat_map(parts, & &1.report.truncated)
    }

    %{
      window: window,
      app_id: head.app_id,
      messages: Enum.flat_map(parts, & &1.messages),
      relevant:
        Map.new(members, fn member ->
          {member.id,
           parts
           |> Enum.flat_map(&Map.get(&1.relevant, member.id, []))
           |> cap_channel_only()}
        end),
      channel_names: Enum.reduce(parts, %{}, &Map.merge(&1.channel_names, &2)),
      channel_sources: Enum.reduce(parts, %{}, &Map.merge(&1.channel_sources, &2)),
      coverage:
        Map.merge(report, %{
          channels_total: Enum.sum(Enum.map(parts, & &1.channels_total)),
          channel_list_complete?: Enum.all?(parts, & &1.complete?),
          threads_complete:
            Map.new(members, fn member ->
              {member.id, Enum.all?(parts, &Map.get(&1.threads, member.id, true))}
            end)
        })
    }
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

    case read_page(request, @rate_limit_retries) do
      {:ok, %{messages: page, has_more?: true, next_cursor: next}} when not is_nil(next) ->
        read_channel(source, channel_id, after_us, before_us, next, budget - 1, rows ++ page)

      {:ok, %{messages: page}} ->
        {:ok, rows ++ page, budget - 1}

      {:error, reason} ->
        {:error, reason, budget - 1}
    end
  end

  # The members' briefs of a Swarm are written around the same hour, each
  # reading every channel: Slack then asks some reads to wait. A read waits
  # as asked, a few times, and is not lost to the brief.
  defp read_page(request, tries) do
    case Salix.impl().daily_brief_read_window(request) do
      {:error, {:rate_limited, seconds}} when tries > 0 and is_integer(seconds) ->
        SystemsClock.sleep(min(seconds, @max_rate_limit_wait) * 1000)
        read_page(request, tries - 1)

      result ->
        result
    end
  end

  # A member's threads are the window's threads they wrote in, at any time:
  # one lookup per batch of the window's thread roots.
  defp matchers(%{source: source, app_id: app_id}, members, messages, focus) do
    threads =
      for %{thread_ts: ts} = message <- messages,
          is_binary(ts),
          uniq: true,
          do: %{channel_id: message.channel_id, thread_ts: ts}

    Enum.reduce(members, {%{}, %{}}, fn %DailyBriefMember{} = member, {matchers, report} ->
      {wrote, complete?} = member_threads(source, member, threads, app_id)
      aliases = Enum.map(member.aliases, &%{term: &1.term, kind: &1.kind})

      channels = Map.get(focus, member.id, Focus.none())

      {Map.put(
         matchers,
         member.id,
         Classifier.member(ActorRef.member_actor_id(member, app_id), aliases, wrote, channels)
       ), Map.put(report, member.id, complete?)}
    end)
  end

  # A member the source's app does not know wrote in none of its threads.
  defp member_threads(source, member, threads, app_id) do
    if is_nil(ActorRef.member_actor_id(member, app_id)),
      do: {[], true},
      else: member_threads_known(source, member, threads, app_id)
  end

  defp member_threads_known(source, member, threads, app_id) do
    threads
    |> Enum.chunk_every(@thread_batch)
    |> Enum.reduce({[], true}, fn batch, {wrote, complete?} ->
      case Salix.impl().daily_brief_member_threads(
             Sources.threads_request(source, member, batch, app_id)
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
        |> Enum.sort_by(&ts_value(&1.message), :desc)
        |> Enum.take(@max_channel_only)
        |> MapSet.new(&{&1.message.channel_id, &1.message.ts})

      Enum.filter(picked, fn entry ->
        entry in rest or MapSet.member?(kept, {entry.message.channel_id, entry.message.ts})
      end)
    end
  end

  # A Feishu or Lark message names its time; a Slack ts is its time.
  defp ts_value(%{at_us: us}) when is_integer(us), do: us / 1_000_000

  defp ts_value(%{ts: ts}) when is_binary(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp ts_value(_message), do: 0.0

  defp relevant(messages, members, matchers) do
    Map.new(members, fn member ->
      matcher = Map.fetch!(matchers, member.id)

      picked =
        for message <- messages,
            reasons = Classifier.reasons(message, matcher),
            tier = Classifier.tier(reasons),
            not is_nil(tier),
            do: %{message: message, reasons: reasons, tier: tier}

      {member.id, picked}
    end)
  end

  defp maybe_attach_jev_recall(%{source: source}, messages, members, matchers) do
    salix = Salix.impl()

    if Code.ensure_loaded?(salix) and function_exported?(salix, :daily_brief_jev_recall, 1) do
      p2_candidates =
        Enum.filter(messages, fn m ->
          m.actor_kind not in ["bot", "app"] and
            is_nil(m[:jev_recall_bp] || m["jev_recall_bp"]) and
            Enum.all?(members, fn member ->
              Classifier.reasons(m, Map.fetch!(matchers, member.id)) == []
            end)
        end)

      if p2_candidates == [] do
        messages
      else
        payload_messages =
          p2_candidates
          |> Enum.take(24)
          |> Enum.map(fn m ->
            %{
              channel_id: m.channel_id,
              ts: m.ts,
              text: String.slice(m.text || "", 0, 300),
              actor_label: m[:actor_label]
            }
          end)

        case salix.daily_brief_jev_recall(%{
               group_id: source[:group_id],
               messages: payload_messages
             }) do
          {:ok, scores} when is_map(scores) ->
            Enum.map(messages, fn m ->
              case Map.get(scores, {m.channel_id, m.ts}) || Map.get(scores, m.ts) do
                bp when is_integer(bp) -> Map.put(m, :jev_recall_bp, bp)
                _ -> m
              end
            end)

          _ ->
            messages
        end
      end
    else
      messages
    end
  rescue
    _ -> messages
  end
end
