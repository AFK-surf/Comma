defmodule BridgeForTeams.DailyBrief.Compose do
  @moduledoc """
  Writes the daily briefs. Once a day the model writes the team's brief from
  the shared stream (`write_team/2`); each member's brief is then written from
  the member's messages and the team brief, so the two agree and the member's
  brief does not retell the team's (`write/2`). Each brief also gets the one
  it follows, so it can tell what changed since. A thread that continued in
  the window comes with its first message, marked as earlier context.

  The model sees short references and people labels. What it writes is
  checked here before anyone sees it:

    * a link is an item reference, replaced by a message preview link and a
      native-open link, or a URL that appears in the input; any other link is
      removed; a "#123" becomes the pull request or issue link the window's
      messages carry;
    * a credential (an API key, a token) is cut to its prefix;
    * a people label becomes a mention (in the team brief, for at most
      three people).

  The text is Slack mrkdwn. For Feishu and Lark the source adapter is
  `Sources.Feishu` or `Sources.Lark` (by the settings' provider): a person is
  written `<@ou_…>` and the sink turns the text into card Markdown.
  """

  alias BridgeForTeams.{Agents, Repo}
  alias BridgeForTeams.DailyBrief.{ActorRef, Members, People, SharedSource, SourceItem, Sources}
  alias BridgeForTeams.DailyBrief.Sources.Slack
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Project}

  # The binding refuses input above 450 KB: the items take what the rest of
  # the request leaves, and a request still over it after the estimate loses
  # items until it fits.
  @request_bytes 420_000
  @max_request_bytes 440_000
  @min_items_bytes 20_000
  @brief_bytes 8_000
  @text_cap 600
  # A bot's write-up (meeting notes, a summary) keeps its decisions and
  # action items, which come after the attendees and the agenda.
  @write_up_cap 3_000
  @write_up_length 800
  # What an item's keys, ref, channel, label, time, and thread add to its
  # text in the request, with room for labels longer than the mentions they
  # replace.
  @item_overhead 110
  @max_team_mentions 3
  # The last replies of a told thread, and of all of them in one brief.
  @ending_replies 3
  @max_endings 100
  @max_team_endings 300

  @type result :: %{text: String.t(), usage: map()}

  @doc """
  The team brief of a window: its human messages of the shared stream and
  the brief before it. Both texts name people as Slack mentions: `posted`
  links the messages it cites, for the team's channel; `text` has no links and
  is kept for the members' briefs.
  """
  @spec write_team(map(), keyword()) ::
          {:ok, %{text: String.t(), posted: String.t(), usage: map()}}
          | {:error, term(), map() | nil}
  def write_team(%{settings: settings, shared: shared, now: now} = input, opts) do
    members = Keyword.get_lazy(opts, :members, fn -> Members.enabled(settings) end)
    zone = team_zone(members)
    src = Sources.adapter(settings)

    with {:ok, model} <- compose_model(opts),
         {:ok, agent_id} <- agent_id(settings, opts),
         candidates =
           for(
             message <- shared.messages,
             item = src.shared_item(message),
             not item.bot?,
             do: {1, item}
           ),
         previous = brief_text(input[:previous]),
         people =
           people(
             members,
             sourced_refs(src, candidates, previous, [], settings, shared),
             settings,
             shared
           ),
         rest = %{
           "now" => local_iso(now, zone),
           # The organization chose whether the team brief names people.
           "names" => if(settings.team_names == "shown", do: "important", else: "none"),
           "previous_brief" => previous && src.label_text(previous, people)
         },
         # The latest messages are the ones a team brief cannot do without.
         {picked, earlier} =
           select(candidates, budget(rest), :newest, settings, shared, members),
         endings = thread_endings(src, picked, shared.messages, @max_team_endings),
         picked = picked ++ endings,
         people =
           people(
             members,
             sourced_refs(src, candidates, previous, earlier ++ endings, settings, shared),
             settings,
             shared
           ),
         {items, item_refs} =
           views(src, picked, earlier, people, src.channel_names(settings, shared), zone),
         known = Map.merge(input[:issues] || %{}, issue_links(shared.messages)),
         {issues, known} =
           issue_states_and_links(
             agent_id,
             known,
             [],
             items,
             item_refs,
             channel_repos(shared.messages)
           ),
         request =
           rest
           |> Map.put("items", items)
           |> Map.put("issues", issues)
           |> fit(:newest),
         {:ok, %{text: text, usage: usage}} <-
           model_call(model, %{agent_id: agent_id, input: request, view: :team}) do
      links = links(text, item_refs, members, settings, shared)
      names? = settings.team_names == "shown"
      text = if names?, do: few_mentions(text, people), else: text

      {:ok,
       %{
         text: text |> finish(request, %{}, people, src) |> unnamed(names?),
         posted:
           text
           |> finish(request, links, people, src)
           |> link_issues(known)
           |> unnamed(names?),
         usage: usage,
         issues: keep_issues(known)
       }}
    else
      {:error, {reason, %{input_tokens: _, output_tokens: _} = usage}} -> {:error, reason, usage}
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc """
  The brief text for `member`: `shared` is the member's read of the shared
  stream, `team_brief` the team's latest, `previous` the member's last brief.
  Fails with the tokens a failed call cost.
  """
  @spec write(map(), keyword()) :: {:ok, result()} | {:error, term(), map() | nil}
  def write(%{settings: settings, member: member, shared: shared, now: now} = input, opts) do
    members = Keyword.get_lazy(opts, :members, fn -> Members.enabled(settings) end)
    src = Sources.adapter(settings)

    with {:ok, model} <- compose_model(opts),
         {:ok, agent_id} <- agent_id(settings, opts),
         candidates = candidates(src, member, shared),
         team_brief = brief_text(input[:team_brief]),
         previous = brief_text(input[:previous]),
         context = Enum.join(Enum.reject([team_brief, previous], &is_nil/1), "\n"),
         people =
           people(
             members,
             sourced_refs(src, candidates, context, [], settings, shared),
             settings,
             shared
           ),
         rest = %{
           "me" => me(member, people, Map.get(shared, :app_id)),
           "now" => local_iso(now, member.timezone),
           "team_brief" => team_brief && src.label_text(team_brief, people),
           "previous_brief" => previous && src.label_text(previous, people)
         },
         {picked, earlier} =
           select(candidates, budget(rest), :oldest, settings, shared, members),
         endings = thread_endings(src, picked, shared.messages, @max_endings),
         picked = picked ++ endings,
         people =
           people(
             members,
             sourced_refs(src, candidates, context, earlier ++ endings, settings, shared),
             settings,
             shared
           ),
         {items, item_refs} =
           views(
             src,
             picked,
             earlier,
             people,
             src.channel_names(settings, shared),
             member.timezone,
             mine_marks(src, member, picked, earlier, shared.messages, Map.get(shared, :app_id))
           ),
         known = Map.merge(input[:issues] || %{}, issue_links(shared.messages)),
         login = github_login(agent_id, member, input[:github], known),
         {my_prs, pull_links} = my_pulls_and_links(agent_id, login, shared.window),
         known = Map.merge(pull_links, known),
         {issues, known} =
           issue_states_and_links(
             agent_id,
             known,
             input[:followups],
             items,
             item_refs,
             channel_repos(shared.messages)
           ),
         request =
           rest
           |> Map.put("items", items)
           |> Map.put("my_talk", my_talk(items))
           |> Map.put("closed", closed_view(input[:closed]))
           |> Map.put("issues", issues)
           |> Map.put("my_prs", my_prs)
           |> put_station_tasks(station_task_views(input[:station_tasks], member.timezone))
           |> fit(:oldest),
         {mine, listed} = mine(model, agent_id, request, input[:followups]),
         {:ok, %{text: text, usage: usage}} <-
           model_call(model, %{agent_id: agent_id, input: Map.put(request, "mine", mine)}),
         {text, usage} = cover(model, agent_id, Map.put(request, "mine", mine), text, usage) do
      written =
        text
        |> finish(request, links(text, item_refs, members, settings, shared), people, src)
        |> link_issues(known)

      {:ok,
       %{
         text: written,
         usage: add_usage(usage, listed),
         mine: mine,
         issues: keep_issues(known),
         github: login
       }}
    else
      {:error, {reason, %{input_tokens: _, output_tokens: _} = usage}} -> {:error, reason, usage}
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc "The model agent of a brief: `opts[:agent_id]` or the Swarm Router."
  @spec agent_id(DailyBriefSetting.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def agent_id(settings, opts) do
    case Keyword.fetch(opts, :agent_id) do
      {:ok, agent_id} -> {:ok, agent_id}
      :error -> router(settings)
    end
  end

  defp router(settings) do
    with %Project{} = project <- Repo.get(Project, settings.project_id),
         {:ok, %{salix_agent_id: agent_id}} when is_binary(agent_id) and agent_id != "" <-
           Agents.current_router(project) do
      {:ok, agent_id}
    else
      _ -> {:error, :project_agent_unavailable}
    end
  end

  defp compose_model(opts) do
    model = Keyword.get_lazy(opts, :model, &BridgeForTeams.DailyBrief.Model.impl/0)

    if model && Code.ensure_loaded?(model) && function_exported?(model, :compose, 1),
      do: {:ok, model},
      else: {:error, :model_unavailable}
  end

  @mine_keys ~w(kind what owner waiting due status evidence)
  @mine_kinds ~w(promise assigned asked decide mine_moved watch)
  @max_mine 40

  # First the model lists what is the member's (promises, assignments,
  # questions waiting on them, decisions, the follow-ups carried from the
  # last brief with their new status); the note is then written from that
  # list. Best effort: a list that cannot be read leaves the note to the
  # messages alone.
  defp mine(model, agent_id, request, followups) do
    input = Map.put(request, "followups", followups(followups))

    {listed, usage} =
      case model.compose(%{agent_id: agent_id, input: input, view: :mine}) do
        {:ok, %{text: text, usage: usage}} when is_binary(text) -> {parse_mine(text), usage}
        {:ok, %{usage: usage}} -> {[], usage}
        {:error, {_reason, %{input_tokens: _, output_tokens: _} = usage}} -> {[], usage}
        {:error, _reason} -> {[], nil}
      end

    reconciled =
      SalixStore.ProactiveKernel.reconcile_brief_mine(listed, %{
        "followups" => input["followups"],
        "closed" => request["closed"],
        "issues" => request["issues"],
        "my_prs" => request["my_prs"],
        "items" => request["items"],
        "max" => @max_mine
      })

    {reconciled, usage}
  end

  @doc false
  # A follow-up the model did not give again stays as it was: a list it left
  # out, or a failed call, never drops open work. One it gave again under
  # other words is matched by the pull request or issue it names.
  def keep_followups(listed, followups) do
    SalixStore.ProactiveKernel.reconcile_brief_mine(listed, %{
      "followups" => followups,
      "max" => @max_mine
    })
  end

  @doc false
  def same_thing?(a, b), do: SalixStore.ProactiveKernel.same_matter?(a, b)

  @doc false
  # The model's list as validated entries: known keys and kinds, text only.
  def parse_mine(text) do
    json = text |> String.trim() |> String.replace(~r/\A```(?:json)?\s*|\s*```\z/, "")

    case Jason.decode(json) do
      {:ok, %{"items" => items}} when is_list(items) ->
        for %{"kind" => kind, "what" => what} = item <- items,
            kind in @mine_kinds and is_binary(what) and what != "",
            do: Map.new(@mine_keys, &{&1, text_field(item[&1])})

      _invalid ->
        []
    end
    |> Enum.take(@max_mine)
  end

  defp text_field(value) when is_binary(value), do: String.slice(value, 0, 300)
  defp text_field(_value), do: ""

  # Follow-ups carried over are the last brief's open entries.
  defp followups(entries) when is_list(entries) do
    entries
    |> Enum.filter(&(is_map(&1) and not String.starts_with?(&1["status"] || "", "done")))
    |> Enum.take(@max_mine)
  end

  defp followups(_none), do: []

  defp closed_view(entries) when is_list(entries),
    do:
      for(
        %{"what" => what} = e <- entries,
        do: %{"what" => what, "status" => e["status"] || "done", "on" => e["on"] || ""}
      )

  defp closed_view(_none), do: []

  defp add_usage(usage, nil), do: usage

  defp add_usage(usage, listed),
    do: %{
      input_tokens: usage.input_tokens + listed.input_tokens,
      output_tokens: usage.output_tokens + listed.output_tokens
    }

  defp model_call(model, request) do
    case model.compose(request) do
      {:ok, %{text: text}} = ok when is_binary(text) and text != "" -> ok
      {:ok, %{usage: usage}} -> {:error, {:empty_brief, usage}}
      {:error, _} = error -> error
    end
  end

  # The member's messages, ranked: 0 names or answers them, 1 is near them.
  defp candidates(src, member, shared) do
    for %{message: message, tier: tier} <- Map.get(shared.relevant, member.id, []) do
      {if(tier == :p0, do: 0, else: 1), src.shared_item(message)}
    end
  end

  defp me(member, people, app_id),
    do: %{
      "label" => People.label(people, ActorRef.member_ref(member, app_id)),
      "names" => for(a <- member.aliases, a.kind in ["name", "handle"], do: a.term)
    }

  # People who are not members are labelled by the name their IM shows, read
  # through the Swarm whose group each ref came from. A member is named as the
  # app of the bot that sends the brief knows them (`shared.app_id`), whichever
  # Swarm's group they wrote in. Non-member open ids from another Feishu or Lark
  # app are marked unmentionable so the sending app never emits a cross-app
  # `<at id=…>` tag.
  defp people(members, sourced_refs, settings, shared) do
    refs = Enum.map(sourced_refs, &elem(&1, 0))
    member_refs = MapSet.new(Enum.flat_map(members, &ActorRef.member_all_refs/1))
    head_app = Map.get(shared, :app_id)

    others =
      Enum.reject(sourced_refs, fn {ref, _src_settings, _src_app} ->
        is_nil(ref) or MapSet.member?(member_refs, ref)
      end)

    names =
      others
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.reduce(%{}, fn {source_settings, group_refs}, acc ->
        Map.merge(acc, Sources.adapter(source_settings).user_names(group_refs, source_settings))
      end)

    unmentionable =
      if Sources.slack?(settings) or not is_binary(head_app) do
        MapSet.new()
      else
        {mentionable_refs, foreign_refs} =
          Enum.reduce(others, {MapSet.new(), MapSet.new()}, fn {ref, _s, src_app}, {ok, bad} ->
            if is_binary(src_app) and src_app != head_app do
              {ok, MapSet.put(bad, ref)}
            else
              {MapSet.put(ok, ref), bad}
            end
          end)

        MapSet.difference(foreign_refs, mentionable_refs)
      end

    People.build(members, refs, names, head_app, unmentionable)
  end

  # Labels are given in order, so adding the earlier context's people last
  # keeps everyone else's label. Each ref carries the Swarm settings and app id
  # of the channel it came from.
  defp sourced_refs(src, candidates, context, earlier, settings, shared) do
    channel_sources = Map.get(shared, :channel_sources) || %{}
    head_app = Map.get(shared, :app_id)

    item_refs = fn item ->
      {source_settings, source_app} =
        channel_source(channel_sources, item.container_id, settings, head_app)

      for ref <- [item.author | item.mentions] ++ reactors(item),
          do: {ref, source_settings, source_app}
    end

    Enum.flat_map(candidates, fn {_t, item} -> item_refs.(item) end) ++
      Enum.map(src.mentions(context), &{&1, settings, head_app}) ++
      Enum.flat_map(earlier, item_refs)
  end

  defp channel_source(channel_sources, container_id, fallback_settings, fallback_app) do
    case Map.get(channel_sources, container_id) do
      %{settings: %DailyBriefSetting{} = source_settings} = info ->
        {source_settings, Map.get(info, :app_id)}

      %DailyBriefSetting{} = source_settings ->
        {source_settings, nil}

      _missing ->
        {fallback_settings, fallback_app}
    end
  end

  defp reactors(%SourceItem{origin: %{reactions: reactions}}) when is_list(reactions),
    do: for(%{users: users} <- reactions, id <- users, do: ActorRef.slack(id))

  defp reactors(_item), do: []

  # "+1 @Bob @Carol; eyes @Dan": a reaction often is the answer.
  defp reacted(%SourceItem{origin: %{reactions: [_ | _] = reactions}}, people) do
    Enum.map_join(reactions, "; ", fn %{name: name, users: users} ->
      name <>
        " " <> Enum.map_join(users, " ", &(People.label(people, ActorRef.slack(&1)) || "@" <> &1))
    end)
  end

  defp reacted(_item, _people), do: nil

  defp brief_text(text) when is_binary(text) and text != "", do: cap_bytes(text, @brief_bytes)
  defp brief_text(_none), do: nil

  defp budget(rest) do
    left = @request_bytes - byte_size(Jason.encode!(rest))
    max(left, @min_items_bytes)
  end

  @doc false
  # A team brief mentions at most a few people (Slack pings each once per
  # message); anyone after them is written without the `@`, and a bare Slack
  # id as 某人.
  def few_mentions(text, %People{by_label: by_label}) do
    case Map.keys(by_label) do
      [] ->
        text

      labels ->
        pattern =
          labels
          |> Enum.sort_by(&String.length/1, :desc)
          |> Enum.map_join("|", &Regex.escape/1)

        {parts, _seen} =
          ~r/(#{pattern})(?![A-Za-z0-9_-])/u
          |> Regex.split(text, include_captures: true)
          |> Enum.map_reduce(MapSet.new(), fn part, seen ->
            cond do
              not Map.has_key?(by_label, part) or MapSet.member?(seen, part) ->
                {part, seen}

              # A Slack bot_id cannot be @-mentioned and takes none of the ping budget.
              Regex.match?(~r/^@B[A-Z0-9]{2,32}(-\d+)?$/, part) ->
                {"机器人", seen}

              MapSet.size(seen) < @max_team_mentions ->
                {part, MapSet.put(seen, part)}

              # A label that is only a Slack or open id is no name to read.
              Regex.match?(~r/^@(?:[UW][A-Z0-9]{2,32}|ou_[A-Za-z0-9_-]{2,64})(-\d+)?$/, part) ->
                {"某人", seen}

              true ->
                {part |> String.trim_leading("@") |> String.replace("_", " "), seen}
            end
          end)

        Enum.join(parts)
    end
  end

  # An organization that hides names gets none, whatever the model wrote.
  defp unnamed(text, true), do: text

  defp unnamed(text, false),
    do: Regex.replace(~r/<@(?:[UW][A-Z0-9]{2,32}|ou_[A-Za-z0-9_-]{2,64})>/, text, "某人")

  @doc "The zone most members are in, for the team brief's times and date."
  @spec team_zone([DailyBriefMember.t()]) :: String.t()
  def team_zone([]), do: "Etc/UTC"

  def team_zone(members),
    do:
      members
      |> Enum.frequencies_by(& &1.timezone)
      |> Enum.max_by(&elem(&1, 1))
      |> elem(0)

  # Highest tier first, then oldest (a member's brief) or newest (the team's)
  # first, within `budget` bytes; then the first messages of the picked
  # items' threads that started before the window, in what is left.
  defp select(candidates, budget, order, settings, shared, members) do
    sorted =
      Enum.sort_by(candidates, fn {tier, item} ->
        {tier, if(order == :newest, do: -unix(item.at), else: unix(item.at))}
      end)

    {picked, used} = take_within(Enum.map(sorted, &elem(&1, 1)), budget, 0)

    roots = fetch_thread_roots(Sources.adapter(settings), settings, shared, members, picked)
    picked_keys = MapSet.new(picked, &SourceItem.key/1)
    roots = Enum.reject(roots, &MapSet.member?(picked_keys, SourceItem.key(&1)))
    {earlier, _used} = take_within(roots, budget, used)
    {picked, earlier}
  end

  defp fetch_thread_roots(src, settings, shared, members, picked) do
    channel_sources = Map.get(shared, :channel_sources) || %{}
    head_app = Map.get(shared, :app_id)
    after_at = shared.window.after

    picked
    |> Enum.group_by(&channel_source(channel_sources, &1.container_id, settings, head_app))
    |> Enum.flat_map(fn {{source_settings, source_app}, group_items} ->
      src.thread_roots(source_settings, group_items, after_at)
      |> Enum.map(&SharedSource.rename_item(&1, source_app, head_app, members))
    end)
  end

  # A thread the brief tells may have ended after the part it picked, often
  # in a reply nobody named anyone in (a bot saying it is fixed or giving the
  # plan asked for): its last replies in the window come along, so the brief
  # tells how it ended.
  defp thread_endings(src, picked, messages, max) do
    # A thread's first message may carry no thread: its replies name it.
    first_seen =
      picked
      |> Enum.group_by(&{&1.container_id, &1.thread_id || &1.id}, &unix(&1.at))
      |> Map.new(fn {thread, times} -> {thread, Enum.min(times)} end)

    picked_keys = MapSet.new(picked, &SourceItem.key/1)

    # The replies the brief does not carry, from where it starts telling the
    # thread: a bot's answer stays even when someone replied to it after.
    messages
    |> Enum.filter(&(&1[:thread_ts] && &1[:thread_ts] != &1[:ts]))
    |> Enum.map(&src.shared_item/1)
    |> Enum.filter(fn item ->
      seen = first_seen[{item.container_id, item.thread_id}]

      is_integer(seen) and unix(item.at) > seen and
        not MapSet.member?(picked_keys, SourceItem.key(item))
    end)
    |> Enum.group_by(&{&1.container_id, &1.thread_id})
    # Each thread's last reply first, then the one before it: a long window
    # with many threads still tells how each ended.
    |> Enum.flat_map(fn {_thread, replies} ->
      replies
      |> Enum.sort_by(&unix(&1.at), :desc)
      |> Enum.take(@ending_replies)
      |> Enum.with_index()
    end)
    |> Enum.sort_by(fn {item, rank} -> {rank, -unix(item.at)} end)
    |> Enum.take(max)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&unix(&1.at))
  end

  # Earlier context goes first, then the messages the brief can best do
  # without: the oldest for the team, the latest for a member.
  defp fit(request, order) do
    if byte_size(Jason.encode!(request)) <= @max_request_bytes do
      request
    else
      items = request["items"]
      {earlier, current} = Enum.split_with(items, & &1["earlier"])

      items =
        cond do
          earlier != [] -> Enum.drop(earlier, 1) ++ current
          order == :newest -> Enum.drop(current, max(div(length(current), 20), 1))
          true -> Enum.drop(current, -max(div(length(current), 20), 1))
        end

      fit(Map.put(request, "items", Enum.sort_by(items, &ref_index/1)), order)
    end
  end

  defp ref_index(%{"ref" => "m" <> n}), do: String.to_integer(n)

  defp text_cap(%SourceItem{bot?: true, text: text}) when is_binary(text) do
    if String.length(text) >= @write_up_length, do: @write_up_cap, else: @text_cap
  end

  defp text_cap(_item), do: @text_cap

  defp take_within(items, budget, used) do
    {taken, used} =
      Enum.reduce(items, {[], used}, fn item, {taken, used} ->
        size = byte_size(String.slice(item.text, 0, text_cap(item))) + @item_overhead

        if used + size <= budget,
          do: {[item | taken], used + size},
          else: {taken, used}
      end)

    {Enum.reverse(taken), used}
  end

  # In time order, the earlier context marked. Keys are short so more
  # messages fit: `in` the channel, `by` the author, `at` the local time,
  # `t` the thread (a short name shared by its messages).
  defp views(src, picked, context, people, names, zone, marks \\ %{me: nil, open: MapSet.new()}) do
    earlier_keys = MapSet.new(context, &SourceItem.key/1)

    refs =
      (picked ++ context)
      |> Enum.sort_by(&unix(&1.at))
      |> Enum.with_index(1)
      |> Enum.map(fn {item, i} -> {"m#{i}", item} end)

    threads =
      refs
      |> Enum.map(fn {_ref, item} -> {item.container_id, item.thread_id} end)
      |> Enum.filter(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.with_index(1)
      |> Map.new(fn {key, i} -> {key, "t#{i}"} end)

    thread = fn item ->
      threads[{item.container_id, item.thread_id}] || threads[{item.container_id, item.id}]
    end

    views =
      for {ref, item} <- refs do
        view =
          %{
            "ref" => ref,
            "in" => src.conversation(item, names),
            "by" => by(item, people, marks.me),
            "at" => local_time(item.at, zone),
            "text" => item.text |> src.label_text(people) |> String.slice(0, text_cap(item))
          }
          |> put_if("t", thread.(item))
          |> put_if("re", reacted(item, people))
          |> put_if("to_me", if(MapSet.member?(marks.open, SourceItem.key(item)), do: true))
          # A channel shared with another company: only the member's own words are read.
          |> put_if("only_mine", if(match?(%{kind: "shared"}, item.origin), do: true))

        if MapSet.member?(earlier_keys, SourceItem.key(item)),
          do: Map.put(view, "earlier", true),
          else: view
      end

    {views, Map.new(refs)}
  end

  @must_cover 3

  # Before the brief goes out: every place the member said @must_cover or
  # more things must be cited. A draft that leaves one out is written once
  # more with the missing places named; that second draft is sent either way.
  defp cover(model, agent_id, request, text, usage) do
    cited = ~r/\]\((m\d+)\)/ |> Regex.scan(text, capture: :all_but_first) |> List.flatten()

    missing =
      for %{"refs" => refs} = talk <- request["my_talk"] || [],
          refs = String.split(refs),
          length(refs) >= @must_cover,
          Enum.all?(refs, &(&1 not in cited)),
          do: Map.take(talk, ["where", "in", "refs"])

    with [_ | _] <- missing,
         {:ok, %{text: revised, usage: more}} when is_binary(revised) and revised != "" <-
           model.compose(%{
             agent_id: agent_id,
             input: request |> Map.put("draft", text) |> Map.put("missing", missing)
           }) do
      {revised, add_usage(more, usage)}
    else
      _kept -> {text, usage}
    end
  end

  # Where the member spoke, most first: each thread (or conversation outside
  # threads) with the refs of their messages there. The model must account
  # for each, so a line of the member's own day is not dropped.
  defp my_talk(items) do
    items
    |> Enum.filter(&(&1["by"] == "你" and not Map.has_key?(&1, "earlier")))
    |> Enum.group_by(&(&1["t"] || &1["in"]))
    |> Enum.map(fn {where, said} ->
      %{"where" => where, "in" => hd(said)["in"], "refs" => Enum.map_join(said, " ", & &1["ref"])}
    end)
    |> Enum.sort_by(&(-length(String.split(&1["refs"]))))
  end

  # The member's own words are marked "你" before the model reads them, so it
  # never tells them back as someone else's, nor as its own.
  defp by(%SourceItem{author: author}, _people, me) when author == me and not is_nil(me), do: "你"
  defp by(item, people, _me), do: People.label(people, item.author)

  # Which of the picked messages wait on the member's answer: a person's
  # one-to-one message, a message that mentions them, or a direct question to
  # them in a thread they already spoke in, with no later word or confirming
  # reaction from them there.
  # The rule picks these, not the model, so the brief does not invent asks.
  defp mine_marks(src, %DailyBriefMember{} = member, picked, earlier, messages, app_id) do
    user = ActorRef.member_actor_id(member, app_id) || ActorRef.member_actor_id(member)
    me = ActorRef.member_ref(member, app_id)

    own =
      (for(
         m <- messages,
         m.actor_id == user,
         item = src.shared_item(m),
         do: {item.container_id, item.thread_id || item.id, unix(item.at)}
       ) ++
         for(
           %SourceItem{author: ^me} = item <- earlier,
           do: {item.container_id, item.thread_id || item.id, unix(item.at)}
         ))
      |> Enum.uniq()

    last =
      messages
      |> Enum.filter(&is_binary(&1.thread_ts))
      |> Enum.group_by(&{&1.channel_id, &1.thread_ts})
      |> MapSet.new(fn {_thread, ms} ->
        {hd(ms).channel_id, Enum.max_by(ms, &unix_ts/1).ts}
      end)

    open =
      for item <- picked,
          item.author != me,
          directed?(item, me, own) or
            left_to_me?(item, MapSet.member?(last, {item.container_id, item.id}), own),
          not answered?(item, user, own),
          into: MapSet.new(),
          do: SourceItem.key(item)

    %{me: me, open: open}
  end

  @pending_reactions ~w(eyes eye thinking_face hourglass hourglass_flowing_sand)

  # Asked directly: a person's one-to-one message, any message that mentions
  # the member, or a human's unaddressed question in a thread the member
  # already spoke in.
  defp directed?(%SourceItem{} = item, me, own) do
    me in item.mentions or
      (not item.bot? and match?(%{kind: "im"}, item.origin)) or
      (not item.bot? and is_binary(item.thread_id) and item.mentions == [] and
         question?(item.text) and spoke_before?(item, own))
  end

  defp question?(text) when is_binary(text), do: String.contains?(text, ["?", "？"])
  defp question?(_text), do: false

  # The last word of a thread the member spoke in, a person's or a bot's,
  # that turns to them ("你…", a question, a choice to make) waits on them.
  defp left_to_me?(%SourceItem{} = item, last?, own) do
    last? and is_binary(item.thread_id) and item.mentions == [] and turns_to_me?(item.text) and
      spoke_before?(item, own)
  end

  defp turns_to_me?(text) when is_binary(text),
    do: question?(text) or String.contains?(text, ["你", "任选", "二选一", "要不要"])

  defp turns_to_me?(_text), do: false

  # A Feishu or Lark message names its time; a Slack ts is its time.
  defp unix_ts(%{at_us: us}) when is_integer(us), do: us / 1_000_000

  defp unix_ts(%{ts: ts}) do
    case Float.parse(ts || "") do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp spoke_before?(%SourceItem{container_id: container, thread_id: thread, at: at}, own) do
    item_at = unix(at)
    Enum.any?(own, fn {c, t, own_at} -> c == container and t == thread and own_at < item_at end)
  end

  defp answered?(%SourceItem{} = item, user, own) do
    dm? = match?(%{kind: kind} when kind in ["im", "mpim"], item.origin)
    thread = item.thread_id || item.id

    reacted_by_me? =
      Enum.any?(List.wrap(item.origin[:reactions]), fn r ->
        r[:name] not in @pending_reactions and user in List.wrap(r[:users])
      end)

    reacted_by_me? or
      Enum.any?(own, fn {c, t, at} ->
        c == item.container_id and at > unix(item.at) and (t == thread or dm?)
      end)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  ## Output

  @link ~r/\[([^\]\n]+)\]\(([^)\s]+)\)/u
  @url ~r/(?:https?:\/\/|www\.)[^\s<>()\[\]|"'`（）【】，。、；！？]+/iu
  @ref ~r/^m\d+$/

  # Fetch only cited messages, once each, through the Swarm whose bot reads
  # each message's channel. Keep native opening separate from the HTTPS
  # message link Slack uses for hover previews.
  defp links(text, item_refs, members, settings, shared) do
    src = Sources.adapter(settings)
    team = Enum.find_value(members, & &1.slack_workspace_id)
    cited = for [_, _label, ref] <- Regex.scan(@link, text), do: ref
    items = for ref <- cited, item = item_refs[ref], item, uniq: true, do: {ref, item}
    channel_sources = Map.get(shared, :channel_sources) || %{}
    head_app = Map.get(shared, :app_id)

    fetched =
      items
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq_by(&SourceItem.key/1)
      |> Enum.group_by(fn item ->
        item.container_id
        |> then(&channel_source(channel_sources, &1, settings, head_app))
        |> elem(0)
      end)
      |> Enum.reduce(%{}, fn {source_settings, group_items}, acc ->
        Map.merge(acc, src.permalinks(group_items, source_settings))
      end)

    for {ref, item} <- items,
        {preview, open} =
          {item.permalink || fetched[SourceItem.key(item)], src.deep_link(item, team)},
        is_binary(preview) or is_binary(open),
        into: %{},
        do:
          {ref,
           if(is_binary(preview) and is_binary(open), do: {preview, open}, else: preview || open)}
  end

  @issue_url ~r{https://github\.com/([\w.-]+/[\w.-]+)/(?:pull|issues)/(\d+)}
  @issue_ref ~r/(?<![\w\/&#-])#(\d{2,7})\b/u

  @doc false
  # The GitHub pull request and issue links the window's messages carry, any
  # author's, by number: a number two repositories share links to neither.
  def issue_links(messages) do
    messages
    |> Enum.flat_map(&Regex.scan(@issue_url, &1[:text] || ""))
    |> Enum.uniq_by(fn [_url, repo, number] -> {repo, number} end)
    |> Enum.group_by(fn [_url, _repo, number] -> number end, fn [url | _] -> url end)
    |> Enum.flat_map(fn
      {number, [url]} -> [{number, url}]
      {_number, _shared} -> []
    end)
    |> Map.new()
  end

  @max_issue_lookups 15
  @max_known_issues 200

  # The state, read now, of the pull requests and issues the follow-ups and
  # the items name, so a merged, closed, or draft one is not written as
  # waiting to be merged. A bare `#number` without a link resolves to the
  # single repository of its channel or of `known` when unambiguous, and joins
  # `known` once GitHub confirms it exists.
  defp issue_states_and_links(agent_id, known, followups, items, item_refs, channel_repos) do
    fallback_repo = sole_repo(known)

    followup_candidates =
      for entry <- followups(followups),
          number <- mentioned_numbers(entry["what"]) ++ mentioned_numbers(entry["status"]),
          repo = known_repo(known, number) || fallback_repo,
          is_binary(repo),
          do: {number, repo}

    item_candidates =
      for item <- items,
          number <- mentioned_numbers(item["text"]),
          container = item_refs[item["ref"]] && item_refs[item["ref"]].container_id,
          repo = known_repo(known, number) || channel_repos[container] || fallback_repo,
          is_binary(repo),
          do: {number, repo}

    issues =
      (followup_candidates ++ item_candidates)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn
        {number, [repo]} -> [%{repo: repo, number: number}]
        {_number, _ambiguous} -> []
      end)
      |> Enum.take(@max_issue_lookups)

    salix = BridgeForTeams.Salix.Client.impl()

    with [_ | _] <- issues,
         true <- Code.ensure_loaded?(salix),
         true <- function_exported?(salix, :daily_brief_issue_states, 1),
         {:ok, states} when is_map(states) <-
           salix.daily_brief_issue_states(%{agent_id: agent_id, issues: issues}) do
      resolved =
        for %{repo: repo, number: number} <- issues,
            state = states["#{repo}##{number}"],
            is_binary(state),
            do: {number, repo, state}

      updated_known =
        Enum.reduce(resolved, known, fn {number, repo, _state}, acc ->
          Map.put_new(acc, number, "https://github.com/#{repo}/issues/#{number}")
        end)

      {Enum.map(resolved, fn {number, _repo, state} ->
         %{"ref" => "#" <> number, "state" => state}
       end), updated_known}
    else
      _none -> {[], known}
    end
  end

  defp known_repo(known, number) do
    case Regex.run(@issue_url, known[number] || "") do
      [_url, repo, ^number] -> repo
      _ -> nil
    end
  end

  # Each channel's unambiguous GitHub repository when all links in that channel
  # name the same `owner/repo`.
  defp channel_repos(messages) do
    messages
    |> Enum.flat_map(fn message ->
      channel = message[:channel_id]

      if is_binary(channel) do
        for [_url, repo, _number] <- Regex.scan(@issue_url, message[:text] || ""),
            do: {channel, repo}
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {channel, [repo]} -> [{channel, repo}]
      {_channel, _shared} -> []
    end)
    |> Map.new()
  end

  defp sole_repo(known) do
    repos =
      known
      |> Map.values()
      |> Enum.flat_map(fn url ->
        case Regex.run(@issue_url, url) do
          [_url, repo, _number] -> [repo]
          _ -> []
        end
      end)
      |> Enum.uniq()

    case repos do
      [repo] -> repo
      _ -> nil
    end
  end

  defp mentioned_numbers(text) when is_binary(text) do
    refs = Regex.scan(@issue_ref, text, capture: :all_but_first)
    urls = for [_url, _repo, number] <- Regex.scan(@issue_url, text), do: [number]
    List.flatten(refs ++ urls)
  end

  defp mentioned_numbers(_text), do: []

  @doc false
  # The pull requests the member's GitHub login merged or closed in the
  # window. Their commits may be someone else's: an agent can open a pull
  # request with the member's account, so `others` names those authors.
  def my_pulls(agent_id, login, window) do
    elem(my_pulls_and_links(agent_id, login, window), 0)
  end

  defp my_pulls_and_links(agent_id, login, %{after: after_at, before: before})
       when is_binary(login) do
    salix = BridgeForTeams.Salix.Client.impl()

    with true <- Code.ensure_loaded?(salix),
         true <- function_exported?(salix, :daily_brief_member_pulls, 1),
         {:ok, pulls} when is_list(pulls) <-
           salix.daily_brief_member_pulls(%{
             agent_id: agent_id,
             login: login,
             since: after_at |> DateTime.to_date() |> Date.to_iso8601(),
             until: before |> DateTime.to_date() |> Date.to_iso8601()
           }) do
      recent = Enum.filter(pulls, &in_window?(&1[:closed_at], after_at, before))

      views =
        for %{number: number, state: state} = pull <- recent do
          %{"ref" => "#" <> number, "title" => pull[:title] || "", "state" => state}
          |> put_if("others", others(pull[:others]))
        end

      links =
        recent
        |> Enum.filter(&(is_binary(&1[:repo]) and is_binary(&1[:number])))
        |> Enum.uniq_by(&{&1.repo, &1.number})
        |> Enum.group_by(& &1.number, &"https://github.com/#{&1.repo}/pull/#{&1.number}")
        |> Enum.flat_map(fn
          {number, [url]} -> [{number, url}]
          {_number, _shared} -> []
        end)
        |> Map.new()

      {views, links}
    else
      _none -> {[], %{}}
    end
  end

  defp my_pulls_and_links(_agent_id, _login, _window), do: {[], %{}}

  # The member's GitHub login: the one they told the bot, else the one a
  # brief already found, else the member of the GitHub organizations the
  # brief has seen links to whose login or profile name is the member's name.
  defp github_login(agent_id, %DailyBriefMember{aliases: aliases}, found, known) do
    told = Enum.find_value(List.wrap(aliases), &(&1.kind == "github" && &1.term))
    salix = BridgeForTeams.Salix.Client.impl()

    orgs =
      for(
        url <- Map.values(known),
        [_url, repo, _number] <- [Regex.run(@issue_url, url)],
        do: repo |> String.split("/") |> hd()
      )
      |> Enum.uniq()

    names = for a <- List.wrap(aliases), a.kind in ["name", "handle"], do: a.term

    cond do
      is_binary(told) ->
        told

      is_binary(found) and found != "" ->
        found

      orgs != [] and names != [] and Code.ensure_loaded?(salix) and
          function_exported?(salix, :daily_brief_member_login, 1) ->
        case salix.daily_brief_member_login(%{agent_id: agent_id, orgs: orgs, names: names}) do
          {:ok, login} when is_binary(login) -> login
          _none -> nil
        end

      true ->
        nil
    end
  end

  defp in_window?(at, after_at, before) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} ->
        DateTime.compare(at, after_at) != :lt and DateTime.compare(at, before) == :lt

      _invalid ->
        false
    end
  end

  defp in_window?(_at, _after_at, _before), do: false

  defp others([_ | _] = logins), do: Enum.join(logins, " ")
  defp others(_none), do: nil

  # The links known so far travel with the brief, so a later one can still
  # look up a number the window no longer links.
  defp keep_issues(known) do
    known
    |> Enum.sort_by(fn {number, _url} -> -String.to_integer(number) end)
    |> Enum.take(@max_known_issues)
    |> Map.new()
  end

  @doc false
  # A "#123" the text names becomes its link when the window's messages carry
  # one; text already inside a link, a mention, or code is left alone.
  def link_issues(text, issues) when map_size(issues) == 0, do: text

  def link_issues(text, issues) do
    ~r/<[^>]*>|`[^`]*`/u
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn
      "<" <> _ = part ->
        part

      "`" <> _ = part ->
        part

      part ->
        Regex.replace(@issue_ref, part, fn whole, number ->
          case issues[number] do
            nil -> whole
            url -> "<#{url}|##{number}>"
          end
        end)
    end)
  end

  @doc false
  # The model's Markdown as checked Slack mrkdwn; people as `src` mentions them.
  def finish(text, request, links, people, src \\ Slack) do
    known = known_urls(request)

    {text, placeholders} =
      take_links(loose_refs(redact(text)), links, known, source_labels(request))

    text
    |> strip_unknown_urls(known)
    |> escape()
    |> mrkdwn()
    |> src.mention_people(people)
    |> put_links(placeholders, known)
    |> String.trim()
  end

  # A ref the model wrote outside a link ("[原消息](m1)(m2)", "（m3）") is a
  # link to that message too.
  defp loose_refs(text),
    do: Regex.replace(~r/(?<!\])[(（](m\d+)[)）]/u, text, " [原消息](\\1)")

  defp known_urls(request) do
    item_urls =
      request["items"]
      |> List.wrap()
      |> Enum.flat_map(&Regex.scan(@url, &1["text"] || ""))
      |> Enum.map(fn [url] -> url |> split_trailing() |> elem(0) end)

    station_urls =
      request["station_tasks"]
      |> List.wrap()
      |> Enum.flat_map(fn task ->
        case task["url"] do
          url when is_binary(url) and url != "" ->
            Regex.scan(@url, url) |> Enum.map(fn [u] -> u |> split_trailing() |> elem(0) end)

          _ ->
            []
        end
      end)

    MapSet.new(item_urls ++ station_urls)
  end

  defp put_station_tasks(request, []), do: request
  defp put_station_tasks(request, tasks), do: Map.put(request, "station_tasks", tasks)

  defp station_task_views(tasks, zone) when is_list(tasks) do
    tasks
    |> Enum.take(20)
    |> Enum.flat_map(fn
      %{} = task ->
        title = task["title"] || task[:title] || ""
        state = task["state"] || task[:state] || task["attention"] || task[:attention] || ""
        note = task["note"] || task[:note]
        url = task["url"] || task[:url]
        at_ms = task["last_activity_at"] || task[:last_activity_at]

        if title != "" and state in ~w(need failed done) do
          at =
            if is_integer(at_ms) and at_ms > 0 do
              at_ms |> DateTime.from_unix!(:millisecond) |> local_iso(zone)
            end

          [
            %{"title" => String.slice(title, 0, 120), "state" => state}
            |> put_if("note", if(is_binary(note) and note != "", do: String.slice(note, 0, 300)))
            |> put_if("url", if(is_binary(url) and url != "", do: String.slice(url, 0, 500)))
            |> put_if("at", at)
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp station_task_views(_tasks, _zone), do: []

  # A sentence's closing punctuation is not part of its URL.
  defp split_trailing(url) do
    case Regex.run(~r/^(.*?)([.,;:!?]*)$/su, url, capture: :all_but_first) do
      [bare, trailing] -> {bare, trailing}
      nil -> {url, ""}
    end
  end

  # Where and when each item was said, as a source link's words:
  # "#channel · 10/27 22:14".
  defp source_labels(request) do
    for %{"ref" => ref, "in" => where, "at" => at} <- request["items"] || [],
        is_binary(where) and is_binary(at),
        into: %{},
        do: {ref, where <> " · " <> String.replace(at, "-", "/")}
  end

  defp take_links(text, links, known, sources) do
    Regex.scan(@link, text, return: :index)
    |> Enum.reverse()
    |> Enum.reduce({text, []}, fn [{start, len}, label_at, target_at], {text, acc} ->
      label = binary_part(text, elem(label_at, 0), elem(label_at, 1))
      target = binary_part(text, elem(target_at, 0), elem(target_at, 1))

      url =
        cond do
          Regex.match?(@ref, target) -> links[target]
          MapSet.member?(known, target) -> target
          true -> nil
        end

      # A link to a message says where and when it was said.
      label =
        if not is_nil(url) and Regex.match?(@ref, target) and
             (Regex.match?(@ref, label) or source_label?(label)),
           do: Map.get(sources, target, label),
           else: label

      placeholder = "\u0001#{length(acc)}\u0001"
      {splice(text, start, len, placeholder), [{placeholder, label, url} | acc]}
    end)
  end

  defp splice(text, start, len, with) do
    binary_part(text, 0, start) <>
      with <> binary_part(text, start + len, byte_size(text) - start - len)
  end

  defp strip_unknown_urls(text, known) do
    text =
      Regex.replace(@url, text, fn url ->
        {bare, trailing} = split_trailing(url)
        if MapSet.member?(known, bare), do: url, else: trailing
      end)

    # What a removed `<url>` leaves behind.
    String.replace(text, "<>", "")
  end

  # A link to nothing keeps its words, except the bare "original message" kind.
  # A label's own URLs are checked like any other text.
  defp put_links(text, placeholders, known) do
    Enum.reduce(placeholders, text, fn {placeholder, label, url}, text ->
      # A model that names the link by its ref means the message.
      label = if Regex.match?(@ref, label), do: "原消息", else: label

      label =
        label |> strip_unknown_urls(known) |> String.trim() |> escape() |> String.replace("*", "")

      replacement =
        case url do
          nil ->
            if source_label?(label) or label == "", do: "", else: label

          {preview, open} ->
            "<#{preview}|#{if label == "", do: "原消息", else: label}> · <#{open}|打开>"

          url ->
            "<#{url}|#{if label == "", do: "原消息", else: label}>"
        end

      String.replace(text, placeholder, replacement)
    end)
  end

  defp source_label?(label), do: label in ["原消息", "原帖", "链接", "source", "link", "message"]

  # Keys and tokens of known formats keep only their prefix.
  @secret ~r/\b((?:sk|pk|rk)[-_](?:live|test|proj|ant|or)?[-_]?|phx_|phc_|xox[abeprs]-|xapp-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|npm_|hf_|AKIA|ASIA|AIza|ya29\.|eyJ)[A-Za-z0-9_\-\.]{8,}/i
  defp redact(text), do: Regex.replace(@secret, text, "\\1…")

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  # Headings and **bold** become Slack bold, list markers bullets.
  defp mrkdwn(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        heading = Regex.run(~r/^\s*\#{1,6}\s+(.+)$/u, line, capture: :all_but_first) ->
          "*" <> String.replace(hd(heading), "**", "") <> "*"

        bullet = Regex.run(~r/^(\s*)[-*+]\s+(.*)$/u, line, capture: :all_but_first) ->
          [indent, rest] = bullet
          indent <> "• " <> bold(rest)

        true ->
          bold(line)
      end
    end)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  # Slack bolds and sets code only between word boundaries; a zero-width
  # space makes one next to Chinese text.
  defp bold(line) do
    line
    |> then(&Regex.replace(~r/(?<!`)`([^`\n]+)`(?!`)/u, &1, "​`\\1`​"))
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/u, &1, "​*\\1*​"))
  end

  ## Helpers

  defp cap_bytes(text, max) when byte_size(text) <= max, do: text

  defp cap_bytes(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, n} ->
      if n + byte_size(g) > max,
        do: {:halt, {acc, n}},
        else: {:cont, {acc <> g, n + byte_size(g)}}
    end)
    |> elem(0)
  end

  defp local_iso(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> DateTime.to_iso8601(local)
      _ -> DateTime.to_iso8601(at)
    end
  end

  defp local_time(nil, _zone), do: nil

  defp local_time(at, zone) do
    local =
      case DateTime.shift_zone(at, zone) do
        {:ok, local} -> local
        _ -> at
      end

    Calendar.strftime(local, "%m-%d %H:%M")
  end

  defp unix(nil), do: 0
  defp unix(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
end
